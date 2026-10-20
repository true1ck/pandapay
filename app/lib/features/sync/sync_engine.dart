import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local/sync_queue.dart';
import '../../data/sync_api.dart';
import 'split_sync.dart';
import '../../data/local/financial_store.dart';
import '../../data/user_categories_repository.dart';
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

  SyncEngine(this._ref);

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
    if (_running) return SyncResult.idle;
    final api = _ref.read(syncApiProvider);
    if (api == null) return SyncResult.idle;

    _running = true;
    try {
      await (await _ref.read(
        splitRepositoryProvider.future,
      )).sync(reconnect: true);
      final queue = await _ref.read(syncQueueProvider.future);

      var deviceId = queue.deviceId;
      if (deviceId == null) {
        deviceId = await api.registerDevice(
          platform: _platform,
          appVersion: _ref.read(appVersionProvider).valueOrNull,
        );
        queue.deviceId = deviceId;
      }

      final pushed = await _push(api, queue, deviceId);
      final (pulled, conflicts) = await _pullAndApply(api, queue, deviceId);

      return SyncResult(
        pushed: pushed,
        pulled: pulled,
        conflicts: conflicts,
        ranToCompletion: true,
      );
    } catch (_) {
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
    }
  }

  Future<int> _push(SyncApi api, SyncQueue queue, String deviceId) async {
    final pending = queue.pending();
    if (pending.isEmpty) return 0;

    queue.claim(pending);
    try {
      final results = await api.push(deviceId: deviceId, changes: pending);
      final accepted = results
          .where((r) => r.applied)
          .map((r) => r.clientSeq)
          .toSet();
      final entities = pending
          .where((c) => accepted.contains(c.clientSeq))
          .map((c) => c.entity)
          .toSet();
      if (entities.isNotEmpty) await _materialize(api, entities, queue);
      var applied = 0;
      for (final result in results) {
        if (result.clientSeq == null) continue;
        if (result.applied) {
          final change = pending
              .where((c) => c.clientSeq == result.clientSeq)
              .first;
          if (change.entity == 'transactions' &&
              (change.op == 'delete' ||
                  change.payload['status'] == 'ignored')) {
            final cache = await _ref.read(responseCacheProvider.future);
            cache.financialStore.markInactive(queue.namespace, change.entityId);
          }
          queue.remove(result.clientSeq!);
          applied++;
        } else if (result.isPermanentFailure) {
          // Retain rejected work for review while allowing later edits through.
          queue.reject(
            result.clientSeq!,
            result.reason ?? 'Change needs attention',
          );
        } else {
          queue.recordFailure(result.clientSeq!, result.reason ?? 'unknown');
        }
      }
      return applied;
    } finally {
      queue.release(pending);
    }
  }

  Future<(int, int)> _pullAndApply(
    SyncApi api,
    SyncQueue queue,
    String deviceId,
  ) async {
    var totalPulled = 0;
    var totalConflicts = 0;
    var since = queue.lastServerSeq;
    final entities = <String>{};

    // Loops on `hasMore` so a device returning after a long absence catches up
    // fully instead of one page per trigger. Bounded so a pathological
    // backlog can't spin here forever holding the UI's refresh.
    for (var page = 0; page < 20; page++) {
      final batch = await api.pull(deviceId: deviceId, since: since);
      totalConflicts = batch.conflicts.length;

      if (batch.changes.isEmpty) break;

      // Gather the bounded backlog before fetching authoritative snapshots.
      // Fetching the entire transaction history once per page multiplies
      // startup I/O and UI-isolate work without adding any durable coverage.
      entities.addAll(batch.changes.map((c) => c['entity'] as String));
      since = batch.latestServerSeq;
      totalPulled += batch.changes.length;

      if (!batch.hasMore) break;
    }

    if (entities.isNotEmpty) {
      // Neither the persisted cursor nor the server acknowledgment advances
      // until every affected entity has been committed. Failure replays the
      // backlog safely on the next cycle.
      await _materialize(api, entities, queue);
      _invalidateFor(entities);
      queue.lastServerSeq = since;
      await api.ack(deviceId: deviceId, serverSeq: since);
    }

    _ref.read(unacknowledgedConflictsProvider.notifier).state = totalConflicts;
    return (totalPulled, totalConflicts);
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
      cache.financialStore.replaceCards(namespace, cards);
      cache.financialStore.replaceCards(namespace, archived, archived: true);
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
        categoriesRepository.upsertRemote(cache.financialStore.database, namespace, category);
      }
      if (_ref.read(cacheNamespaceProvider) != namespace) {
        throw StateError('Account changed during sync');
      }
    }
  }

  void _invalidateFor(Set<String> entities) {
    // A pull changes the server-side source of truth. The global display
    // refresh watcher then writes the new response snapshots locally, so a
    // later offline launch sees the same data that was just pulled.
    _ref.invalidate(homeDataRefreshProvider);
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
  ref.watch(splitSyncLifecycleProvider);
  ref.listen<String>(cacheNamespaceProvider, (previous, next) async {
    if (previous != next && next != 'signed-out') {
      await ref.read(syncEngineProvider).sync();
    }
    if (previous != 'signed-out' && next == 'signed-out') {
      // Sign-out: the queue and cursor belong to the account that just left.
      final db = await ref.read(appDatabaseProvider.future);
      SyncQueue(db, namespace: previous!).resetCursor();
    }
  });

  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) async {
    final cameOnline =
        previous?.valueOrNull == false && next.valueOrNull == true;
    if (cameOnline) {
      await ref.read(syncEngineProvider).sync();
    }
  });
});
