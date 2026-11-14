import '../../data/connectivity/server_backoff.dart';
import 'invalidation_coalescer.dart';
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../../app/providers.dart';
import '../../data/session_end_reason.dart';
import '../../data/api_exception.dart';
import '../../data/local/sync_queue.dart';
import '../../data/sync_api.dart';
import '../../data/sync_transaction_delta.dart';
import 'split_sync.dart';
import '../../data/local/financial_store.dart';
import '../../data/local/self_transfer_rules.dart';
import '../../data/commitments_repository.dart';
import '../../data/user_categories_repository.dart';
import '../../data/portable_backup/account_recovery_operation_gate.dart';
import 'dart:convert';

/// Plan Phase 4 — the client-side sync loop.
///
/// Push first, then pull, then acknowledge. That order is not arbitrary:
///
///   * Pushing first means the server has this device's edits before it
///     computes what to send back, so the pull reflects the merged state
///     rather than a state this device is about to contradict.
///   * Acknowledging only after applying means a dropped response costs a
///     repeated pull, never a skipped change. Advancing the cursor on receipt
///     would make a crash mid-apply permanently lose everything in that batch,
///     which is precisely the "silent data loss" 0005_sync.sql warns about.
///
/// The whole loop is best-effort and swallows network errors. A failed sync
/// leaves the local database exactly as it was, with the queue intact, and the
/// next trigger retries.
class SyncResult {
  final int pushed;
  final int pulled;
  final int conflicts;
  final bool ranToCompletion;

  const SyncResult({
    required this.pushed,
    required this.pulled,
    required this.conflicts,
    required this.ranToCompletion,
  });

  static const idle = SyncResult(
    pushed: 0,
    pulled: 0,
    conflicts: 0,
    ranToCompletion: true,
  );
}

class SyncEngine {
  final Ref _ref;
  bool _running = false;
  Timer? _continuation;
  bool _pullHasMore = false;
  bool _pushHasMore = false;

  /// Largest request body pushed in one go. The API rejects bodies over
  /// 1 MiB for the whole request (this client stays well under at 60 KiB), so one oversize change would otherwise
  /// block every change behind it for ever. Changes are never split, so a
  /// single change larger than this goes alone and is judged on its own.
  static const maxPushBytes = 60 * 1024;
  static const maxPushChanges = 200;

  /// Requests per sync. A bigger backlog continues in a follow-up sync, so a
  /// long queue cannot monopolise the isolate or the connection.
  static const maxPushPasses = 5;

  /// Extra requests a sync may spend on isolating one bad change inside a
  /// failed chunk (halving), so a server outage cannot turn into hundreds.
  static const maxIsolationRequests = 24;

  /// Safety valve (H1-2): a 500 aborts the sync without blaming any row, so a
  /// row that deterministically crashes the server would block the queue for
  /// ever. After this many 500 aborts in a row that all start with the same
  /// head row, that row alone is held back for [headRowBackoff].
  static const headRowAbortLimit = 8;
  static const headRowBackoff = Duration(hours: 1);
  int? _abortHead;
  int _abortCount = 0;

  bool _reregisteredDevice = false;
  int _isolationRequests = 0;

  SyncEngine(this._ref) {
    // The server asked every queue to wait (429/503 Retry-After); retry as
    // soon as that pause ends instead of waiting for another trigger.
    final resumeSub = ServerBackoff.process.resumed.listen(
      (_) => unawaited(sync()),
    );
    _ref.onDispose(() {
      resumeSub.cancel();
      _continuation?.cancel();
      _invalidations.dispose();
    });
  }

  /// A long import syncs once per batch. Refreshing every screen each time
  /// makes open pages flicker, so changes inside a few seconds are merged.
  late final InvalidationCoalescer _invalidations = InvalidationCoalescer(
    onFlush: _applyInvalidation,
  );

  static String get _platform {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'web';
  }

  /// Runs one full cycle. Re-entrant calls are dropped rather than queued: two
  /// concurrent cycles would push the same queued changes twice, and while the
  /// server is idempotent enough to survive that, the duplicate conflict rows
  /// it would generate are user-visible noise.
  Future<SyncResult> sync() async {
    try {
      return await AccountRecoveryOperationGate.process.run(_sync);
    } on AccountRecoveryBusy {
      return SyncResult.idle;
    }
  }

  Future<SyncResult> _sync() async {
    if (_running) return SyncResult.idle;
    if (ServerBackoff.process.isPaused) return SyncResult.idle;
    final api = _ref.read(syncApiProvider);
    if (api == null) return SyncResult.idle;

    _running = true;
    _continuation?.cancel();
    _pullHasMore = false;
    _pushHasMore = false;
    _reregisteredDevice = false;
    _isolationRequests = 0;
    final namespace = _ref.read(cacheNamespaceProvider);
    final token = _ref.read(accessTokenProvider);
    try {
      final queue = await _ref.read(syncQueueProvider.future);

      var deviceId = queue.deviceId;
      if (deviceId == null) {
        deviceId = await api.registerDevice(
          platform: _platform,
          appVersion: _ref.read(appVersionProvider).valueOrNull,
        );
        queue.deviceId = deviceId;
      }

      int pushed;
      try {
        pushed = await _push(api, queue, deviceId);
      } finally {
        // Split documents and foreign-payment changes are independent of
        // field edits. Start their sync after the edit push, without waiting
        // for it: a hung or failing one must never hold up (or abort) the
        // push, the pull or the next sync cycle.
        _startSplitSync();
        _startForeignPaymentsSync();
      }
      // A re-registration during the push may have issued a new device id.
      deviceId = queue.deviceId ?? deviceId;
      if (ServerBackoff.process.isPaused) {
        return SyncResult(
          pushed: pushed,
          pulled: 0,
          conflicts: 0,
          ranToCompletion: false,
        );
      }
      final (pulled, conflicts) = await _pullAndApply(api, queue, deviceId);
      await _refreshSelfTransferRules(api, queue);
      await _ref.read(transactionTagsProvider)?.sync();

      return SyncResult(
        pushed: pushed,
        pulled: pulled,
        conflicts: conflicts,
        ranToCompletion: true,
      );
    } catch (_) {
      _pullHasMore = false;
      _pushHasMore = false;
      // Offline, or the server is unreachable. Everything the user did is
      // still in the local queue; the next trigger tries again.
      return const SyncResult(
        pushed: 0,
        pulled: 0,
        conflicts: 0,
        ranToCompletion: false,
      );
    } finally {
      _running = false;
      if (_pullHasMore || _pushHasMore) {
        // Yield after a bounded catch-up pass, then resume its durable cursor.
        _continuation = Timer(const Duration(milliseconds: 100), () {
          if (_ref.read(cacheNamespaceProvider) == namespace &&
              _ref.read(accessTokenProvider) == token &&
              _ref.read(isOnlineProvider).valueOrNull != false) {
            unawaited(sync());
          }
        });
      }
    }
  }

  void _startSplitSync() {
    unawaited(() async {
      try {
        await (await _ref.read(
          splitRepositoryProvider.future,
        )).sync(reconnect: true);
      } catch (_) {
        // Split documents stay durable and retry on the next trigger.
      }
    }());
  }

  /// Drains the foreign-payments outbox (it used to drain only when its
  /// screen read it or a change was made, so a reconnect never sent it).
  void _startForeignPaymentsSync() {
    unawaited(() async {
      try {
        final foreign = _ref.read(foreignPaymentsRepositoryProvider);
        // Only when something is queued: sync() also refreshes exchange rates,
        // which a sign-in or resume sync has no reason to do.
        if (await foreign.hasDueChanges()) await foreign.sync();
      } catch (_) {
        // Changes stay durable and retry on the next trigger.
      }
    }());
  }

  /// Pushes queued edits in byte-bounded chunks, at most [maxPushPasses]
  /// requests per sync.
  ///
  /// A change the server acked is marked applied straight away: it is never
  /// pushed again, whatever happens next (a failed refetch used to leave it
  /// queued and re-sent). It is only deleted once the fresh server copy has
  /// been stored, because until then it is what keeps showing the edit.
  Future<int> _push(SyncApi api, SyncQueue queue, String deviceId) async {
    var applied = 0;
    var passes = 0;
    final attempted = <int>{};
    while (passes < maxPushPasses) {
      if (ServerBackoff.process.isPaused) break; // the server asked us to wait
      final chunk = _nextChunk(queue, attempted);
      if (chunk.isEmpty) break;
      passes++;
      applied += await _pushChunk(api, queue, chunk, attempted);
    }
    _pushHasMore =
        passes == maxPushPasses && _nextChunk(queue, attempted).isNotEmpty;
    // Fetch the authoritative copy of everything the server applied, including
    // changes left over from an earlier sync (or app run) whose fetch failed.
    final entities = queue.appliedEntities();
    if (entities.isNotEmpty) {
      await _materialize(api, entities, queue);
      queue.purgeApplied(entities);
    }
    return applied;
  }

  /// The next run of queued changes, in queue order, that fits one request.
  /// Order matters (a later edit of a row must not overtake an earlier one),
  /// so the run ends at the first change that does not fit.
  List<SyncChange> _nextChunk(SyncQueue queue, Set<int> attempted) {
    final candidates = queue.pending(limit: maxPushChanges + attempted.length);
    final chunk = <SyncChange>[];
    var bytes = 64; // envelope: deviceId and braces
    for (final change in candidates) {
      if (attempted.contains(change.clientSeq)) continue;
      final size = utf8.encode(jsonEncode(change.toJson())).length + 1;
      if (chunk.isNotEmpty && bytes + size > maxPushBytes) break;
      chunk.add(change);
      bytes += size;
      if (chunk.length >= maxPushChanges) break;
    }
    return chunk;
  }

  Future<int> _pushChunk(
    SyncApi api,
    SyncQueue queue,
    List<SyncChange> chunk,
    Set<int> attempted,
  ) async {
    attempted.addAll(chunk.map((c) => c.clientSeq));
    queue.claim(chunk);
    try {
      List<SyncPushResult> results;
      try {
        results = await _pushOnce(api, queue, chunk);
      } on ApiException catch (error) {
        if (_chunkIsToBlame(error)) return await _isolate(api, queue, chunk, error, attempted);
        if (error.statusCode == 500) {
          final head = chunk.first.clientSeq;
          _abortCount = _abortHead == head ? _abortCount + 1 : 1;
          _abortHead = head;
          if (_abortCount >= headRowAbortLimit) {
            queue.defer(head, headRowBackoff, 'server error');
            _abortHead = null;
            _abortCount = 0;
          }
        }
        rethrow;
      }
      _abortHead = null;
      _abortCount = 0;
      return await _applyResults(queue, chunk, results);
    } finally {
      queue.release(chunk);
    }
  }

  /// One push request, with device recovery: when the server says (or, for an
  /// older server, every item answers) that this device is not registered, the
  /// device is registered again and the same request is retried once, before
  /// anything is rejected.
  Future<List<SyncPushResult>> _pushOnce(
    SyncApi api,
    SyncQueue queue,
    List<SyncChange> chunk,
  ) async {
    List<SyncPushResult> results;
    try {
      results = await api.push(deviceId: queue.deviceId!, changes: chunk);
    } on ApiException catch (error) {
      if (_isDeviceNotRegistered(error) && !_reregisteredDevice) {
        await _reregisterDevice(api, queue);
        return api.push(deviceId: queue.deviceId!, changes: chunk);
      }
      rethrow;
    }
    // An older server cannot say "unknown device"; it answers not_found or
    // rejected for every item. One item failing that way is a real rejection,
    // all of them failing that way is far more likely the device. A single
    // item proves nothing (H1-5), so it is not re-registered for.
    final everyItemRefused =
        results.length >= 2 &&
        results.every(
          (r) =>
              !r.applied && (r.reason == 'not_found' || r.reason == 'rejected'),
        );
    if (everyItemRefused && !_reregisteredDevice) {
      await _reregisterDevice(api, queue);
      return api.push(deviceId: queue.deviceId!, changes: chunk);
    }
    return results;
  }

  bool _isDeviceNotRegistered(ApiException error) =>
      error.statusCode == 409 && error.errorCode == 'device_not_registered';

  Future<void> _reregisterDevice(SyncApi api, SyncQueue queue) async {
    _reregisteredDevice = true;
    queue.deviceId = await api.registerDevice(
      platform: _platform,
      appVersion: _ref.read(appVersionProvider).valueOrNull,
      deviceId: queue.deviceId,
    );
  }

  /// True when the server's answer is about the content of this request
  /// rather than about the server, the session or the network: a request that
  /// is too large (413) or invalid (400, 422). Everything else (401, 403, 408,
  /// 429, every 5xx, no status) aborts the sync and records nothing. A 500 is
  /// deliberately not here (H1-2): the server answers a bare internal_error for
  /// any unmapped database failure, an outage included, so halving the chunk
  /// would burn attempts on rows that did nothing wrong.
  bool _chunkIsToBlame(ApiException error) {
    final status = error.statusCode;
    return status == 413 || status == 400 || status == 422;
  }

  /// A request failed because of what it contained. Halve it until the bad
  /// change stands alone, so one poison change cannot block the rest.
  Future<int> _isolate(
    SyncApi api,
    SyncQueue queue,
    List<SyncChange> chunk,
    ApiException error,
    Set<int> attempted,
  ) async {
    if (chunk.length == 1) {
      final change = chunk.single;
      final message = error.statusCode == 413
          ? 'Change is too large to sync'
          : (error.userMessage);
      queue.reject(change.clientSeq, message);
      return 0;
    }
    if (_isolationRequests >= maxIsolationRequests) throw error;
    final middle = chunk.length ~/ 2;
    var applied = 0;
    for (final half in [chunk.sublist(0, middle), chunk.sublist(middle)]) {
      if (_isolationRequests >= maxIsolationRequests) throw error;
      _isolationRequests++;
      queue.claim(half);
      try {
        List<SyncPushResult> results;
        try {
          results = await _pushOnce(api, queue, half);
        } on ApiException catch (halfError) {
          if (!_chunkIsToBlame(halfError)) rethrow;
          applied += await _isolate(api, queue, half, halfError, attempted);
          continue;
        }
        applied += await _applyResults(queue, half, results);
      } finally {
        queue.release(half);
      }
    }
    return applied;
  }

  /// Records the server's verdict per change. Accepted rows leave the queue
  /// here, before their entities are fetched again.
  Future<int> _applyResults(
    SyncQueue queue,
    List<SyncChange> chunk,
    List<SyncPushResult> results,
  ) async {
    var applied = 0;
    for (final result in results) {
      if (result.clientSeq == null) continue;
      if (result.applied) {
        final change = chunk
            .where((c) => c.clientSeq == result.clientSeq)
            .firstOrNull;
        if (change == null) continue;
        if (change.entity == 'transactions' &&
            (change.op == 'delete' || change.payload['status'] == 'ignored')) {
          final cache = await _ref.read(responseCacheProvider.future);
          cache.financialStore.markInactive(queue.namespace, change.entityId);
        }
        if (result.ignoredFields.isNotEmpty) {
          // The server kept the rest but dropped these fields. Never silent:
          // keep the change for review with a plain reason.
          queue.reject(
            result.clientSeq!,
            "Some details weren't saved: ${result.ignoredFields.join(', ')}",
          );
          continue;
        }
        queue.markApplied(result.clientSeq!);
        applied++;
      } else if (result.isPermanentFailure) {
        // Retain rejected work for review while allowing later edits through.
        queue.reject(
          result.clientSeq!,
          result.reason == 'no_syncable_fields'
              ? 'PandaPay no longer accepts this kind of edit'
              : (result.reason ?? 'Change needs attention'),
        );
      } else if (result.isTransient) {
        // A database hiccup on the server: nothing to count, try next sync.
      } else {
        queue.recordFailure(result.clientSeq!, result.reason ?? 'unknown');
      }
    }
    return applied;
  }

  Future<(int, int)> _pullAndApply(
    SyncApi api,
    SyncQueue queue,
    String initialDeviceId,
  ) async {
    var deviceId = initialDeviceId;
    var totalPulled = 0;
    var totalConflicts = 0;
    var since = queue.lastServerSeq;
    final entities = <String>{};
    final transactionChanges = <Map<String, dynamic>>[];
    final commitmentChanges = <Map<String, dynamic>>[];
    final namespace = queue.namespace;
    final sessionToken = _ref.read(accessTokenProvider);
    bool isCurrent() =>
        _ref.read(cacheNamespaceProvider) == namespace &&
        _ref.read(accessTokenProvider) == sessionToken;

    // Bound both request count and rows fetched in one pass. A successful
    // pass schedules a continuation after yielding when the backlog remains.
    for (var page = 0; page < 4; page++) {
      if (!isCurrent()) throw StateError('Account changed during sync');
      SyncPullBatch batch;
      try {
        batch = await api.pull(deviceId: deviceId, since: since, limit: 25);
      } on ApiException catch (error) {
        if (!_isDeviceNotRegistered(error) || _reregisteredDevice) rethrow;
        await _reregisterDevice(api, queue);
        deviceId = queue.deviceId!;
        batch = await api.pull(deviceId: deviceId, since: since, limit: 25);
      }
      if (!isCurrent()) throw StateError('Account changed during sync');
      totalConflicts += batch.conflicts.length;

      if (batch.changes.isEmpty) {
        _pullHasMore = false;
        break;
      }
      if (batch.changes.length > 25) {
        throw const FormatException('Invalid sync pull progress');
      }
      if (batch.latestServerSeq <= since) {
        // The server is behind this device's cursor (a restored database, a
        // reset change log). Throwing here would fail every sync for ever;
        // start again from the beginning instead. Nothing from this pass has
        // been committed or acknowledged. Reset only once: if the server is
        // still behind from zero, it really is inconsistent, so fail loudly
        // rather than loop.
        if (since == 0) {
          throw const FormatException('Invalid sync pull progress');
        }
        queue.lastServerSeq = 0;
        _pullHasMore = true;
        return (0, 0);
      }

      // Gather the bounded backlog before fetching authoritative snapshots.
      // Fetching the entire transaction history once per page multiplies
      // startup I/O and UI-isolate work without adding any durable coverage.
      entities.addAll(batch.changes.map((c) => c['entity'] as String));
      transactionChanges.addAll(
        batch.changes.where((c) => c['entity'] == 'transactions'),
      );
      commitmentChanges.addAll(
        batch.changes.where((c) => c['entity'] == commitmentSyncEntity),
      );
      since = batch.latestServerSeq;
      totalPulled += batch.changes.length;
      _pullHasMore = batch.hasMore;

      if (!batch.hasMore) break;
    }

    if (entities.isNotEmpty) {
      // Neither the persisted cursor nor the server acknowledgment advances
      // until every affected entity has been committed. Failure replays the
      // backlog safely on the next cycle.
      final repository = _ref.read(userCardsRepositoryProvider);
      if (repository == null) throw StateError('Sign in to sync');
      final delta = await fetchSyncTransactionDelta(
        transactionChanges,
        fetch: repository.fetchTransaction,
        isCurrent: isCurrent,
      );
      // Other entity snapshots retain their existing authoritative path.
      await _materialize(api, entities.difference({'transactions'}), queue);
      if (!isCurrent()) throw StateError('Account changed during sync');
      // Bills arrive complete in the change itself, so there is nothing to
      // fetch. Applied before the cursor moves, like every other entity.
      if (commitmentChanges.isNotEmpty) {
        await _ref
            .read(commitmentsRepositoryProvider)
            .applyRemote(commitmentChanges);
        if (!isCurrent()) throw StateError('Account changed during sync');
      }
      final cache = await _ref.read(responseCacheProvider.future);
      if (!isCurrent()) throw StateError('Account changed during sync');
      cache.financialStore.commitTransactionDelta(
        namespace,
        delta.rows,
        delta.deletedIds,
        serverSeq: since,
      );
      _invalidateFor(entities);
      await api.ack(deviceId: deviceId, serverSeq: since);
    }

    _ref.read(unacknowledgedConflictsProvider.notifier).state = totalConflicts;
    return (totalPulled, totalConflicts);
  }

  Future<void> _refreshSelfTransferRules(SyncApi api, SyncQueue queue) async {
    final remote = await api.fetchSelfTransferRules();
    if (remote == null) return;
    final cache = await _ref.read(responseCacheProvider.future);
    SelfTransferRules(
      cache.financialStore.database,
      namespace: queue.namespace,
    ).replaceRemote(remote);
  }

  Future<void> _materialize(
    SyncApi api,
    Set<String> entities,
    SyncQueue queue,
  ) async {
    final namespace = _ref.read(cacheNamespaceProvider);
    if (namespace != queue.namespace) {
      throw StateError('Account changed during sync');
    }
    final cache = await _ref.read(responseCacheProvider.future);
    final repository = _ref.read(userCardsRepositoryProvider);
    if (repository == null) throw StateError('Sign in to sync');
    // Materialize authoritative records before advancing the cursor. If a
    // fetch or local commit fails, this batch is safely replayed next time.
    if (entities.contains('transactions')) {
      final rows = await repository.fetchTransactions();
      if (_ref.read(cacheNamespaceProvider) != namespace) {
        throw StateError('Account changed during sync');
      }
      cache.financialStore.saveTransactions(
        namespace,
        rows,
        completeQuery: const TransactionQuery(),
      );
    }
    if (entities.contains('user_cards')) {
      final cards = await repository.fetchUserCards();
      final archived = await repository.fetchUserCards(includeArchived: true);
      if (_ref.read(cacheNamespaceProvider) != namespace) {
        throw StateError('Account changed during sync');
      }
      // Publishing these snapshots also materializes their card scopes in
      // ResponseCache.put. A direct replace here repeats the same SQL work.
      await cache.put(
        '$namespace:user_cards',
        jsonEncode({'userCards': cards.map((c) => c.toJson()).toList()}),
      );
      await cache.put(
        '$namespace:user_cards_with_archived',
        jsonEncode({'userCards': archived.map((c) => c.toJson()).toList()}),
      );
    }
    if (entities.contains('card_overrides')) {
      final overrides = await _ref
          .read(cardOverridesRepositoryProvider)!
          .fetchOverrides();
      if (_ref.read(cacheNamespaceProvider) != namespace) {
        throw StateError('Account changed during sync');
      }
      await cache.put(
        '$namespace:card_overrides',
        jsonEncode({'overrides': overrides.map((o) => o.toJson()).toList()}),
      );
    }
    if (entities.contains('user_categories')) {
      final categories = await api.fetchUserCategories();
      final categoriesRepository = const UserCategoriesRepository();
      for (final category in categories) {
        categoriesRepository.upsertRemote(
          cache.financialStore.database,
          namespace,
          category,
        );
      }
      if (_ref.read(cacheNamespaceProvider) != namespace) {
        throw StateError('Account changed during sync');
      }
    }
  }

  void _invalidateFor(Set<String> entities) => _invalidations.add(entities);

  void _applyInvalidation(Set<String> entities) {
    // _materialize has already committed the changed entities and their
    // offline snapshots. Invalidating the broad Home refresh here would
    // immediately fetch the complete transaction history a second time and
    // restart unrelated Home requests. Publish only affected projections.
    if (entities.contains('transactions')) {
      _ref.invalidate(transactionsProvider);
      _ref.invalidate(utilizationTransactionsProvider);
      _ref.invalidate(homeSummaryProvider);
    }
    if (entities.contains('user_cards')) {
      _ref.invalidate(userCardsProvider);
      _ref.invalidate(myCardsProvider);
    }
    if (entities.contains('card_overrides')) {
      _ref.invalidate(cardOverridesProvider);
    }
    if (entities.contains('user_categories')) {
      _ref.invalidate(categoriesProvider);
    }
    if (entities.contains(commitmentSyncEntity)) {
      _ref.invalidate(commitmentsProvider);
    }
    // The ranking depends on all three, so it is refreshed whenever any of
    // them moved rather than being enumerated per entity.
    _ref.invalidate(rankedRecommendationsProvider);
  }
}

final syncEngineProvider = Provider<SyncEngine>(SyncEngine.new);

/// How many automatically-resolved conflicts the user hasn't seen yet. Drives
/// the badge on Sync & Backup — a conflict that resolved silently and was
/// never surfaced is the failure mode this whole subsystem exists to avoid.
final unacknowledgedConflictsProvider = StateProvider<int>((ref) => 0);

/// Drives the loop. Watched from `_AppShell` (router.dart) alongside the other
/// lifecycle providers.
///
/// Triggers on sign-in and on regaining connectivity — the two moments when
/// there is either something new to fetch or a queue that can finally drain.
/// Deliberately not on a timer: a periodic poll costs battery on a device
/// where nothing changed, and the two events below already cover every case
/// that matters for a single-user-multi-device product. A push notification
/// would be the right addition when one device needs to learn about another's
/// change immediately, which no screen currently requires.
final syncLifecycleProvider = Provider<void>((ref) {
  ref.watch(transactionTagsProvider);
  ref.watch(splitSyncLifecycleProvider);
  final startup = ref.read(startupWorkSchedulerProvider);
  ref.listen<String>(cacheNamespaceProvider, (previous, next) async {
    if (previous != next && next != 'signed-out') {
      // Token restoration changes the account namespace while Home is still
      // handing off from the splash.  Starting the full split sync in the
      // same frame competes with the first local paint (and its synchronous
      // sqlite materialization).  Keep sign-in/resume/reconnect semantics,
      // but give the authenticated shell a short scheduling window first.
      startup.enqueue('account-sync', () async {
        if (ref.read(cacheNamespaceProvider) == next) {
          await ref.read(syncEngineProvider).sync();
        }
      });
    }
    if (previous == 'signed-out' && next != 'signed-out') {
      // A session started again; the cache lifecycle forgets it too.
      ref.read(sessionEndReasonProvider).clear();
    }
    if (previous != 'signed-out' &&
        next == 'signed-out' &&
        // WP-C3 (L-01): after a session the server rejected, the same person
        // signs in again and resumes. Keep the device id and cursor with the
        // queued edits (they are keyed by namespace and survive), so the
        // device is not registered afresh and the history is not pulled again.
        // An explicit sign-out wipes the file, so this reset only matters there.
        ref.read(sessionEndReasonProvider).mayWipeAccountData) {
      // Sign-out: the queue and cursor belong to the account that just left.
      // H1-7: sign-out closes the database and then invalidates the provider;
      // awaiting `.future` here could reopen (and recreate) the file that is
      // being deleted. Use only a database that is still alive.
      if (!ref.exists(appDatabaseProvider)) return;
      final db = ref.read(appDatabaseProvider).valueOrNull;
      if (db == null) return;
      try {
        SyncQueue(db, namespace: previous!).resetCursor();
      } catch (_) {
        // Already closed: the file is deleted by the sign-out anyway.
      }
    }
  });

  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) async {
    final cameOnline =
        previous?.valueOrNull == false && next.valueOrNull == true;
    if (cameOnline) {
      // Backoffs were about problems that may have passed; do not wait them
      // out a second time after being offline.
      ref.read(transactionTagsProvider)?.resetBackoff();
      try {
        (await ref.read(syncQueueProvider.future)).resetBackoff();
      } catch (_) {
        // The sync below still runs; the backoff just expires on its own.
      }
      try {
        await ref.read(foreignPaymentsRepositoryProvider).resetBackoff();
      } catch (_) {
        // Entries keep their backoff; the sync below still runs.
      }
      await ref.read(syncEngineProvider).sync();
    }
  });

  // Interface state can stay "online" while the API itself is unavailable.
  // Retry durable edits when the user returns to the app as well as on a
  // connectivity transition.
  final lifecycle = AppLifecycleListener(
    onResume: () => unawaited(ref.read(syncEngineProvider).sync()),
  );
  ref.onDispose(lifecycle.dispose);
});
