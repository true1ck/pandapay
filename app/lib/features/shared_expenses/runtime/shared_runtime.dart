import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/shared_expenses.dart';
import 'package:uuid/uuid.dart';
import '../../../data/connectivity/server_backoff.dart';
import '../../../data/local/response_cache.dart';
import '../data/shared_commands.dart';
import '../data/shared_directory.dart';
import '../data/shared_http_transport.dart';
import '../data/shared_invitations.dart';
import '../data/shared_phone_display.dart';
import '../data/shared_transport.dart';
import '../storage/shared_store.dart';
import '../sync/shared_sync.dart';
import '../ui/shared_presentation.dart';
import '../composer/shared_editor.dart';
import '../data/shared_pending_phones.dart';
import 'shared_expense_mapping.dart';
import 'shared_pair_index.dart';
import 'shared_local_reads.dart';

class SharedRuntimeUnavailable implements Exception {
  /// Why: `reads_off` (flag off on the server), `disabled` (off in this
  /// build), `account` (no signed-in account), `no_saved_copy`, or null.
  final String? reason;
  const SharedRuntimeUnavailable([this.reason]);
  @override
  String toString() => 'Shared expenses are not available for this account yet';
}

/// A short, non-sensitive code for a failure, shown on the error screen and
/// logged, so a screenshot from any device says what actually went wrong.
String sharedErrorCode(Object? error) {
  if (error is SharedTransportException) {
    return error.code ??
        (error.statusCode != null ? 'http_${error.statusCode}' : 'transport');
  }
  if (error is SharedRuntimeUnavailable) return error.reason ?? 'unavailable';
  if (error is ArgumentError) return 'bad_config';
  return error?.runtimeType.toString() ?? 'unknown';
}

/// What the person reads. Only a server-side "off" says "not enabled";
/// everything else is a load problem that a retry can fix.
String sharedUnavailableMessage(Object? error) =>
    (error is SharedRuntimeUnavailable &&
            const {
              'reads_off',
              'disabled',
              'account',
            }.contains(error.reason)) ||
        (error is SharedTransportException &&
            (error.code == 'feature_disabled' ||
                error.code == 'feature_unavailable'))
    ? 'Shared expenses are not available yet. Existing transactions and private splits are still available.'
    : 'Could not load your splits right now. Check your connection and try again. (${sharedErrorCode(error)})';

class SharedRoster {
  final String name, ownMemberId;
  final bool direct, canInvite;

  /// The owner's account was deleted; any active member may take over.
  final bool ownerGone;

  /// Sharing a join link for an existing unclaimed person only needs the
  /// owner role; adding another person to a two-person friend split does not.
  final bool canShareLink;
  final List<SharedEditorMember> members;
  SharedRoster({
    required this.name,
    required this.ownMemberId,
    required this.members,
    required this.direct,
    required this.canInvite,
    this.ownerGone = false,
    bool? canShareLink,
  }) : canShareLink = canShareLink ?? canInvite;
}

/// Account-generation owner. Source truth remains on the authenticated server;
/// SQLite commands survive disposal, and replaceable query caches only display
/// previously authorized snapshots. A command receipt is not a fresh balance.
class SharedExpensesRuntime extends ChangeNotifier {
  final SharedExpensesStore store;
  final SharedExpensesHttpTransport remote;
  final ResponseCache cache;
  final bool Function() isCurrent;
  late final SharedExpensesSync sync;

  /// Numbers typed for people not yet invited; on this phone only.
  late final pendingPhones = SharedPendingPhones(store.namespace);
  Map<String, Object?>? capabilities;
  bool _disposed = false, busy = false, offline = false, syncLag = true;
  Object? lastError;

  /// Bumped only when the server's data for this person really changed (a pull
  /// brought records or a revocation, or a write finished). Screens reload on
  /// this, not on every refresh, so an idle refresh no longer re-fetches pages.
  int dataVersion = 0;

  /// True while the page being built was filled from the saved copy.
  bool _servedStale = false;
  DateTime? _capabilitiesAt;
  static const _capabilitiesFresh = Duration(seconds: 60);
  String get _capabilitiesKey => '${store.namespace}:shared:capabilities';

  /// Runs [fetch] once for concurrent callers and reuses a result for a few
  /// seconds, so the invite inbox and the Account badge share one request.
  final _single = <String, ({DateTime at, Future<Object?> future})>{};
  Future<T> _shared<T>(String key, Future<T> Function() fetch) {
    final hit = _single[key];
    if (hit != null &&
        DateTime.now().difference(hit.at) < const Duration(seconds: 3)) {
      return hit.future as Future<T>;
    }
    final future = fetch();
    _single[key] = (at: DateTime.now(), future: future);
    // A failed fetch must not be reused. (The old catchError returned
    // `null as T`, which itself threw for a non-null T: an uncaught async
    // error on every failed invite-inbox or join-request fetch.)
    future.then<void>((_) {}, onError: (Object _) {
      if (_single[key]?.future == future) _single.remove(key);
    });
    return future;
  }

  /// Zone flag: answer from the saved copy only (no network). Used to paint
  /// the last known screen at once while the live load runs behind it.
  static const _cacheOnlyKey = #sharedCacheOnly;
  ///
  /// [allowLocal] also lets a section with no saved copy be built from this
  /// phone's stored Split records and waiting commands (the offline fallback
  /// after a live load failed); the first-paint call leaves it off.
  Future<R> runCacheOnly<R>(
    Future<R> Function() action, {
    bool allowLocal = false,
  }) => runZoned(action, zoneValues: {_cacheOnlyKey: allowLocal ? 'local' : true});
  static bool get _cacheOnly => Zone.current[_cacheOnlyKey] != null;

  /// What this phone has stored for a screen, in the server's JSON shape.
  late final SharedLocalReads _local = SharedLocalReads(store, accountId);
  int _accessGeneration = 0;
  final _queries = <String, Object>{};
  SharedExpensesRuntime({
    required this.store,
    required this.remote,
    required this.cache,
    required this.isCurrent,
  }) {
    sync = SharedExpensesSync(
      store: store,
      remote: remote,
      isCurrent: () => !_disposed && isCurrent(),
      now: () => DateTime.now().millisecondsSinceEpoch,
      leaseId: const Uuid().v4(),
    );
  }
  bool get readsEnabled => capabilities?['reads'] == true;
  bool get proposalsEnabled => capabilities?['proposals'] == true;
  bool get settlementsEnabled => capabilities?['settlements'] == true;
  bool get sourceFundingEnabled => capabilities?['sourceFunding'] == true;

  /// Saving a change on this phone (create a group, add a friend, rename,
  /// respond) only needs the feature not to be known-off. With no flags yet
  /// (never loaded, or a bad connection at launch) the change is queued and
  /// the server decides when it is sent; hiding the button would lose it.
  bool get canQueueProposals => capabilities == null || proposalsEnabled;
  bool get canQueueSettlements => capabilities == null || settlementsEnabled;

  /// Saved changes the server refused (see [SharedExpensesStore.attentionCount]).
  int get attentionCount => store.attentionCount;
  int get accessGeneration => _accessGeneration;
  String get accountId => store.namespace.substring(5);
  void _current() {
    if (_disposed || !isCurrent()) throw const SharedRuntimeUnavailable();
  }

  void _notify() {
    if (!_disposed && isCurrent()) notifyListeners();
  }

  /// Drops the saved query copies for this account but keeps the saved feature
  /// flags: they are not private data, and losing them would make the next
  /// offline launch treat the feature as unknown.
  Future<void> _clearSharedCache() async {
    await cache.clearPrefix('${store.namespace}:shared:');
    final flags = capabilities;
    if (flags != null) await _saveCapabilities(flags);
  }

  /// Invalidate in-flight aggregates before any asynchronous purge. A late
  /// authorized-at-start response must never resurrect revoked private data.
  Future<void> revokeContext(String contextId) async {
    _current();
    _accessGeneration++;
    await store.recoveryGate.run(() async {
      await _clearSharedCache();
      _current();
      await store.revokeContext(contextId);
      dataVersion++;
      _notify();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// One quick capabilities read so screens can decide what is available
  /// without waiting for a full sync. Failures leave [capabilities] unset.
  Future<void> ensureCapabilities() async {
    _current();
    if (capabilities != null) return;
    try {
      final flags = await remote.fetchCapabilities();
      _current();
      capabilities = flags;
      _capabilitiesAt = DateTime.now();
      unawaited(_saveCapabilities(flags));
    } catch (error) {
      lastError = error;
      offline =
          error is SharedTransportException &&
          error.code == 'network_unavailable';
      // The feature gate is not a secret that changes by the minute: reuse
      // what this device last saw so a bad connection at launch does not
      // lock the person out of splits they already have.
      capabilities = await _savedCapabilities();
    }
  }

  /// The flags this device last saw, read locally (no network), so the screen
  /// can open at once; the live flags follow with the background refresh.
  Future<void> useSavedCapabilities() async {
    if (capabilities != null) return;
    final saved = await _savedCapabilities();
    _current();
    capabilities ??= saved;
  }

  Future<void> _saveCapabilities(Map<String, Object?> flags) async {
    try {
      await cache.put(_capabilitiesKey, jsonEncode(flags));
    } catch (_) {}
  }

  Future<Map<String, Object?>?> _savedCapabilities() async {
    try {
      final raw = await cache.get(_capabilitiesKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void>? _running;
  bool _again = false;
  int _failures = 0;
  DateTime? _retryAt;

  /// True while the server has been failing: the background timer waits
  /// (45 s, 90 s, ... up to 10 min) instead of hammering it. A person's own
  /// action (save, pull to retry, reconnect, app resume) is never held back.
  bool get backingOff => _retryAt != null && DateTime.now().isBefore(_retryAt!);

  /// Syncs the queue and pulls changes. A call that arrives while a sync is
  /// running (a person saving an expense just after opening the screen) is not
  /// dropped: the running sync is followed by one more, and the caller waits
  /// for both, so a queued write goes out now rather than at the next timer.
  Future<void> refresh({int maxPullPages = 2}) {
    _current();
    if (busy) {
      _again = true;
      return _running ?? Future<void>.value();
    }
    return _running = _refreshLoop(maxPullPages);
  }

  /// The network came back (or the app returned to the foreground): do not
  /// wait out a backoff earned while it was down. Due rows go now; the attempt
  /// cap still applies. Never throws, so a listener can fire and forget.
  Future<void> reconnect() async {
    try {
      _current();
      await store.resetBackoff();
      _retryAt = null;
      _failures = 0;
      await refresh();
    } catch (_) {
      // A disposed runtime or a busy recovery: the next resume tries again.
    }
  }

  Future<void> _refreshLoop(int maxPullPages) async {
    do {
      _again = false;
      await _refreshOnce(maxPullPages: maxPullPages);
    } while (_again && !_disposed && isCurrent());
  }

  Future<void> _refreshOnce({int maxPullPages = 2}) async {
    _current();
    if (busy) return;
    if (ServerBackoff.process.isPaused) return; // the next trigger retries
    if (maxPullPages < 1 || maxPullPages > 5) {
      throw ArgumentError.value(maxPullPages);
    }
    busy = true;
    lastError = null;
    _notify();
    try {
      await store.recoveryGate.run(() async {
        // Startup just fetched the flags; do not ask again within a minute.
        final at = _capabilitiesAt;
        if (capabilities == null ||
            at == null ||
            DateTime.now().difference(at) > _capabilitiesFresh) {
          final flags = await remote.fetchCapabilities();
          _current();
          capabilities = flags;
          _capabilitiesAt = DateTime.now();
          unawaited(_saveCapabilities(flags));
          _notify();
        }
        if (!readsEnabled) throw const SharedRuntimeUnavailable('reads_off');
        await store.resumeAuthentication();
        // Each queued kind remains capability checked by the authoritative SQL
        // command; a disabled flag cannot silently change a stored command.
        if (proposalsEnabled || settlementsEnabled) await sync.flush();
        final wasLagging = syncLag;
        for (var i = 0; i < maxPullPages; i++) {
          final before = store.cursor,
              page = await remote.pull(cursor: before, limit: 100);
          _current();
          if (page.records.isNotEmpty || page.revokedContextIds.isNotEmpty) {
            dataVersion++;
          }
          if (page.revokedContextIds.isNotEmpty) {
            // Remove stale query summaries before acknowledging access loss.
            _accessGeneration++;
            await _clearSharedCache();
            _current();
          }
          await store.applyPageOffThread(page, expectedCursor: before);
          syncLag = page.hasMore;
          if (!page.hasMore) break;
          // perf-ok: a real 60 ms gap (not Duration.zero) so frames paint
          // between 100-record SQLite writes that run on the UI isolate.
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        if (offline) dataVersion++; // back online: screens re-fetch
        // Caught up: screens built while catching up showed "Syncing your
        // latest changes"; without a reload that line stayed forever when the
        // pull brought nothing new.
        if (wasLagging && !syncLag) dataVersion++;
        offline = false;
        _failures = 0;
        _retryAt = null;
      });
    } catch (error) {
      lastError = error;
      _failures++;
      _retryAt = DateTime.now().add(
        Duration(seconds: (45 << (_failures - 1).clamp(0, 4)).clamp(45, 600)),
      );
      // Type and code only (never the message): a silent apply failure must
      // not look like "still loading".
      debugPrint(
        'shared refresh failed: ${error.runtimeType}'
        '${error is SharedTransportException ? ' ${error.code}' : ''}'
        '${error is SharedLocalException ? ' ${error.code}' : ''}',
      );
      offline =
          error is SharedTransportException &&
          error.code == 'network_unavailable';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _background = Future<void>.value();

  /// Completes when the background send started by the last [submit] is over.
  /// Screens never wait on it; tests do.
  Future<void> settled() => _background;

  Future<String> submit(
    String kind,
    Map<String, Object?> payload, {
    List<String> dependsOn = const [],
    Map<String, Object?>? provisional,
  }) async {
    _current();
    if (capabilities != null && !readsEnabled ||
        (kind.startsWith('settlement.')
            ? !canQueueSettlements
            : !canQueueProposals)) {
      throw const SharedRuntimeUnavailable();
    }
    final command = SharedCommand(
      operationId: const Uuid().v4(),
      kind: kind,
      payload: payload,
    );
    await store.enqueue(
      command,
      dependsOn: dependsOn,
      provisional: provisional,
    );
    _current();
    syncLag = true;
    _notify();
    // Local first: it is stored, so screens show it now. Sending is a
    // background refresh; the screen never waits on the network.
    dataVersion++;
    _notify();
    _background = refresh().then((_) {
      dataVersion++;
      _notify();
    }).catchError((Object _) {});
    return command.operationId;
  }

  Future<String> createDirectFriend(String name) async =>
      (await _enqueueFriend(name)).contextId;

  Future<({String contextId, String memberId})> _enqueueFriend(
    String name,
  ) async {
    _current();
    if (!canQueueProposals ||
        name.trim().isEmpty ||
        name.length > 120 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const SharedRuntimeUnavailable();
    }
    final id = const Uuid().v4(), memberId = const Uuid().v4();
    final context = SharedCommand(
      operationId: const Uuid().v4(),
      kind: 'context.create',
      payload: {'contextId': id, 'contextKind': 'direct', 'name': name.trim()},
    );
    final member = SharedCommand(
      operationId: const Uuid().v4(),
      kind: 'member.invite',
      payload: {
        'contextId': id,
        'memberId': memberId,
        'displayName': name.trim(),
      },
    );
    await store.enqueueFriendSetup(context, member);
    await refresh();
    // The server may refuse the name; nothing is shown for the refused
    // friend, so the person just picks another name.
    final refused =
        nameFailure(context.operationId) ?? nameFailure(member.operationId);
    if (refused != null) {
      // The screen tells the person now; it is not also a leftover "not synced".
      // Both ops may carry a refusal (the member's is a dependent when the
      // context was refused); the one that holds the name refusal is the one
      // the screen explained.
      for (final op in [context, member]) {
        if (store.operation(op.operationId)?.state ==
                SharedCommandState.rejected ||
            store.operation(op.operationId)?.state ==
                SharedCommandState.conflict) {
          await acknowledgeRefusal(op.operationId);
        }
      }
      throw refused;
    }
    return (contextId: id, memberId: memberId);
  }

  /// Checks one picked number. Online only; never queued. A failure means
  /// "could not check", which the UI treats as not found so adding still works.
  Future<SharedPhoneLookup> lookupPhone(String phone) async {
    _current();
    if (!proposalsEnabled) throw const SharedRuntimeUnavailable();
    final cleaned = sharedCleanPhone(phone);
    if (cleaned == null) return SharedPhoneLookup.none;
    final result = await remote.lookupPhone(cleaned);
    _current();
    return result;
  }

  /// Saves the friend on this phone first (so nothing is lost offline), then,
  /// when a number was given, creates a phone-bound invitation. A person who is
  /// already on PandaPay sees it in their in-app inbox; anyone else gets the
  /// returned link to share. A failed invite step never loses the friend.
  Future<SharedFriendAdded> addFriend({
    required String name,
    String? phone,
  }) async {
    final cleaned = phone == null || phone.trim().isEmpty
        ? null
        : sharedCleanPhone(phone);
    if (phone != null && phone.trim().isNotEmpty && cleaned == null) {
      throw const SharedTransportException(code: 'invalid_phone');
    }
    final ids = await _enqueueFriend(name);
    // Kept until the invite goes out, so offline or a failed call loses nothing.
    if (cleaned != null) await pendingPhones.remember(ids.memberId, cleaned);
    if (cleaned == null) {
      return SharedFriendAdded(
        contextId: ids.contextId,
        memberId: ids.memberId,
      );
    }
    try {
      final link = await inviteLink(
        contextId: ids.contextId,
        memberId: ids.memberId,
        phoneNumber: cleaned,
      );
      return SharedFriendAdded(
        contextId: ids.contextId,
        memberId: ids.memberId,
        link: link,
        phone: cleaned,
      );
    } catch (error) {
      return SharedFriendAdded(
        contextId: ids.contextId,
        memberId: ids.memberId,
        phone: cleaned,
        inviteIssue: sharedInviteIssueMessage(error),
      );
    }
  }

  /// An existing friend split with the same name, so a second one is not made
  /// by accident. Best effort: a failure just means no warning.
  Future<String?> sameNameFriend(String name) async {
    try {
      _current();
      final wanted = name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      final page = await remote.fetchContexts(
        kind: 'direct',
        search: name.trim(),
      );
      for (final raw in (page['items'] as List? ?? const [])) {
        final row = raw as Map;
        final candidate = (row['name'] as String? ?? '')
            .trim()
            .replaceAll(RegExp(r'\s+'), ' ')
            .toLowerCase();
        if (candidate == wanted) {
          return row['contextId'] as String?;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<SharedInboxInvite>> inviteInbox() async {
    _current();
    if (!proposalsEnabled) return const [];
    final items = await _shared('invite-inbox', remote.fetchInviteInbox);
    _current();
    return items;
  }

  /// Joins (accept) or declines an inbox invite. Accepting refreshes local data
  /// so the new split appears; it accepts no expense and posts no money.
  Future<String> respondToInboxInvite(
    SharedInboxInvite invite, {
    required bool accept,
  }) async {
    _current();
    if (!proposalsEnabled) throw const SharedRuntimeUnavailable();
    final status = await remote.respondToInboxInvite(
      invitationId: invite.invitationId,
      operationId: const Uuid().v4(),
      accept: accept,
    );
    _current();
    _single.clear();
    if (accept) await refresh();
    return status;
  }

  /// Owner removes someone who never joined and has no expense.
  Future<void> removeMember(String contextId, String memberId) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    await remote.removeMember(
      contextId: contextId,
      memberId: memberId,
      operationId: const Uuid().v4(),
    );
    _current();
    await refresh();
  }

  /// Owner hands the split to another active member, who then has owner rights.
  Future<void> transferOwner(String contextId, String memberId) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    await remote.transferOwner(
      contextId: contextId,
      memberId: memberId,
      operationId: const Uuid().v4(),
    );
    _current();
    await refresh();
  }

  /// When the owner's account is gone, an active member takes over.
  Future<void> takeOverOwnership(String contextId) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    await remote.takeOverOwnership(
      contextId: contextId,
      operationId: const Uuid().v4(),
    );
    _current();
    await refresh();
  }

  /// Leaves a split the person is settled in. The device forgets it at once.
  Future<void> leaveContext(String contextId) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    await remote.leaveContext(
      contextId: contextId,
      operationId: const Uuid().v4(),
    );
    _current();
    await revokeContext(contextId);
    await refresh();
  }

  Future<SharedGroupLinkStatus> groupLinkStatus(String contextId) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    final status = await remote.fetchGroupLinkStatus(contextId);
    _current();
    return status;
  }

  /// A new link each time: creating replaces the old one.
  Future<SharedInviteLink> createGroupLink(
    String contextId, {
    bool autoJoin = false,
  }) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    final link = await remote.createGroupLink(
      contextId: contextId,
      linkId: const Uuid().v4(),
      autoJoin: autoJoin,
    );
    _current();
    return link;
  }

  Future<void> revokeGroupLink(String contextId) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    await remote.revokeGroupLink(
      contextId: contextId,
      operationId: const Uuid().v4(),
    );
    _current();
  }

  /// Owner-only, one request at a time. The caller keeps the result in widget
  /// state and drops it after a minute; it is never cached or stored here.
  Future<SharedRevealedPhone> revealClaimantPhone(String invitationId) async {
    _current();
    if (!proposalsEnabled) throw const SharedRuntimeUnavailable();
    final result = await remote.revealClaimantPhone(
      invitationId: invitationId,
      operationId: const Uuid().v4(),
    );
    _current();
    return result;
  }

  /// Why a queued name command was refused, or null if it was not.
  SharedNameException? nameFailure(String operationId) {
    final op = store.operation(operationId);
    if (op == null ||
        (op.state != SharedCommandState.rejected &&
            op.state != SharedCommandState.conflict)) {
      return null;
    }
    return SharedNameException.fromStored(op.errorCode);
  }

  /// A refusal the screen has already explained (a taken name) is dealt with:
  /// forget the command so it does not also show up as "not synced".
  Future<void> acknowledgeRefusal(String operationId) async {
    try {
      await store.discard(operationId);
    } catch (_) {}
    _notify();
  }

  /// Needs-attention "Retry": back into the queue with a fresh budget, sent now.
  Future<void> retryRefused(String operationId) async {
    _current();
    if (await store.requeue(operationId)) {
      syncLag = true;
      _notify();
      await refresh();
      dataVersion++;
      _notify();
    }
  }

  /// Needs-attention "Discard": forget it (the server never accepted it).
  Future<void> discardRefused(String operationId) async {
    _current();
    if (await store.discard(operationId)) {
      dataVersion++;
      _notify();
    }
  }

  /// The last list fetched in this session, so the requests page can show
  /// something at once while it refreshes. In memory only.
  List<SharedJoinRequest>? cachedJoinRequests;

  Future<List<SharedJoinRequest>> joinRequests() async {
    _current();
    if (!proposalsEnabled) return const [];
    final items = await _shared('join-requests', remote.fetchJoinRequests);
    _current();
    cachedJoinRequests = items;
    return items;
  }

  /// Owner-only. Quietly empty when the list cannot be read, so the roster
  /// still works without invitation details.
  Future<Map<String, SharedOwnerInvitation>> ownerInvitations(
    String contextId,
  ) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) return const {};
    try {
      final items = await remote.fetchContextInvitations(contextId);
      _current();
      return SharedOwnerInvitation.latestByMember(items);
    } on SharedTransportException {
      return const {};
    }
  }

  /// Approve (joins them) or decline a link-join request. Never accepts an
  /// expense or posts money.
  Future<String> respondToJoinRequest(
    String invitationId, {
    required bool approve,
    String? operationId,
    bool refreshAfter = true,
  }) async {
    _current();
    if (!proposalsEnabled) throw const SharedRuntimeUnavailable();
    final status = await remote.respondToJoinRequest(
      invitationId: invitationId,
      // A caller that retries passes the same id so the server replays it.
      operationId: operationId ?? const Uuid().v4(),
      approve: approve,
    );
    _current();
    _single.clear();
    cachedJoinRequests = [
      for (final r in cachedJoinRequests ?? const <SharedJoinRequest>[])
        if (r.invitationId != invitationId) r,
    ];
    if (refreshAfter) await refresh();
    return status;
  }

  Future<({bool phoneVerified, bool discoverable})> discoverability() async {
    _current();
    return remote.fetchDiscoverable();
  }

  Future<bool> setDiscoverable(bool value) async {
    _current();
    final result = await remote.setDiscoverable(value);
    _current();
    return result;
  }

  Future<Map<String, Object?>> _query(
    String key,
    Future<Map<String, Object?>> Function() fetch, {
    String? contextId,
  }) => store.recoveryGate.run(
    () => _admittedQuery(key, fetch, contextId: contextId),
  );

  Future<Map<String, Object?>> _admittedQuery(
    String key,
    Future<Map<String, Object?>> Function() fetch, {
    String? contextId,
  }) async {
    _current();
    // Only a known "off" blocks reading. Unknown (no answer yet, e.g. a bad
    // connection at launch) must still reach the saved copy; the server
    // enforces the flag itself on every live read.
    if (capabilities != null && !readsEnabled) {
      throw const SharedRuntimeUnavailable('reads_off');
    }
    if (contextId != null && store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    final cacheKey = '${store.namespace}:shared:$key';
    if (_cacheOnly) {
      final saved = await cache.get(cacheKey);
      _current();
      if (saved == null) {
        final stored = Zone.current[_cacheOnlyKey] == 'local'
            ? _local.read(key)
            : null;
        if (stored != null) return stored;
        throw const SharedRuntimeUnavailable('no_saved_copy');
      }
      return Map<String, Object?>.from(jsonDecode(saved) as Map);
    }
    final accessGeneration = _accessGeneration, request = Object();
    _queries[cacheKey] = request;
    void authorized() {
      _current();
      if (accessGeneration != _accessGeneration ||
          contextId != null && store.isContextRevoked(contextId)) {
        throw const SharedRuntimeUnavailable();
      }
    }

    try {
      final data = await fetch();
      authorized();
      if (identical(_queries[cacheKey], request)) {
        await cache.put(cacheKey, jsonEncode(data));
      }
      return data;
    } on SharedTransportException catch (error) {
      if (error.statusCode == 403 || error.statusCode == 404) {
        if (contextId != null) {
          await cache.clearPrefix(
            '${store.namespace}:shared:context:$contextId:',
          );
        }
        rethrow;
      }
      // Anything that is not "you may not see this" (offline, timeout, 5xx,
      // a garbled reply, a busy server) is the server's problem, not a reason
      // to blank a screen the person has already seen.
      final denied =
          error.statusCode == 401 ||
          error.code == 'account_changed' ||
          error.code == 'feature_disabled' ||
          error.code == 'feature_unavailable' ||
          error.code == 'hub_unsupported';
      if (denied) rethrow;
      authorized();
      final saved = await cache.get(cacheKey);
      authorized();
      if (saved == null) {
        // Never opened online: build it from the pulled records and the
        // commands still waiting on this phone, if there are any.
        final stored = _local.read(key);
        if (stored == null) rethrow;
        _servedStale = true;
        offline = true;
        return stored;
      }
      _servedStale = true;
      offline = true;
      return Map<String, Object?>.from(jsonDecode(saved) as Map);
    } finally {
      if (identical(_queries[cacheKey], request)) _queries.remove(cacheKey);
    }
  }

  Future<Map<String, Object?>> contexts({String? after}) => _query(
    'contexts:${after ?? 'first'}',
    () => remote.fetchContexts(after: after, limit: 50),
  );

  Future<({String name, String ownMemberId, List<SharedEditorMember> members})>
  editorContext(String id) async {
    final roster = await contextRoster(id);
    return (
      name: roster.name,
      ownMemberId: roster.ownMemberId,
      members: List<SharedEditorMember>.unmodifiable(
        roster.members.where(
          (m) => m.state == 'active' || m.state == 'invited',
        ),
      ),
    );
  }

  /// Online-only: an invite link is a server-issued secret, never queued or
  /// stored locally. Requires the proposals capability, like member creation.
  Future<SharedInviteLink> inviteLink({
    required String contextId,
    required String memberId,
    String? phoneNumber,
  }) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    final number = phoneNumber ?? await pendingPhones.phoneFor(memberId);
    final link = await remote.createInvitation(
      invitationId: const Uuid().v4(),
      contextId: contextId,
      memberId: memberId,
      phoneNumber: number,
    );
    _current();
    await pendingPhones.forget(memberId);
    return link;
  }

  Future<SharedInvitePreview> previewInvite(String token) async {
    _current();
    if (!proposalsEnabled) throw const SharedRuntimeUnavailable();
    final preview = await remote.previewInvitation(token);
    _current();
    return preview;
  }

  /// Returns `joined` (phone-bound link) or `awaiting_owner` (the group owner
  /// must approve). Joining never accepts any expense or debt.
  Future<String> claimInvite(
    String token,
    String operationId, {
    bool? sharePhone,
  }) async {
    _current();
    if (!proposalsEnabled) throw const SharedRuntimeUnavailable();
    final status = await remote.claimInvitation(
      token: token,
      operationId: operationId,
      sharePhone: sharePhone,
    );
    _current();
    await refresh();
    return status;
  }

  final _renameOverlay = <String, String>{};

  /// Friend splits whose counterpart was just renamed here: contextId -> name.
  final _directTitles = <String, String>{};

  /// Renames still on their way to the server, newest typed name winning.
  Map<String, String> _pendingRenames(String contextId) {
    final out = <String, String>{};
    try {
      final page = store.readPendingOperations(
        contextId: contextId,
        limit: 100,
      );
      for (final op in page.items) {
        if (op.command.kind != 'member.rename' ||
            op.state == SharedCommandState.rejected ||
            op.state == SharedCommandState.conflict) {
          continue;
        }
        final payload = op.command.toJson()['payload'] as Map;
        out[payload['memberId'] as String] = payload['displayName'] as String;
      }
    } catch (_) {}
    out.addAll({
      for (final e in _renameOverlay.entries)
        if (e.key.startsWith('$contextId:'))
          e.key.substring(contextId.length + 1): e.value,
    });
    return out;
  }

  /// Sets the name other people see for a member. Saved on this phone first
  /// (works offline), shown immediately, and synced when online. Throws
  /// [FormatException] for an empty or over-long name.
  Future<String> renameMember({
    required String contextId,
    required String memberId,
    required String name,
    bool directCounterpart = false,
  }) async {
    _current();
    final clean = sharedCleanMemberName(name);
    if (clean == null || clean.length > sharedMemberNameMax) {
      throw const FormatException('Invalid member name');
    }
    if (!canQueueProposals || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    final command = SharedCommand(
      operationId: const Uuid().v4(),
      kind: 'member.rename',
      payload: {
        'contextId': contextId,
        'memberId': memberId,
        'displayName': clean,
      },
    );
    await store.enqueue(command);
    _current();
    _renameOverlay['$contextId:$memberId'] = clean;
    // In a friend split the other person's name IS the split's title.
    if (directCounterpart) _directTitles[contextId] = clean;
    syncLag = true;
    _notify();
    await refresh();
    final refused = nameFailure(command.operationId);
    if (refused != null) {
      // Roll the optimistic name back.
      _renameOverlay.remove('$contextId:$memberId');
      if (directCounterpart) _directTitles.remove(contextId);
      _notify();
      await acknowledgeRefusal(command.operationId);
      throw refused;
    }
    // Once the server has it, its roster is the truth again.
    if (store.operation(command.operationId)?.state ==
        SharedCommandState.committed) {
      _renameOverlay.remove('$contextId:$memberId');
      _directTitles.remove(contextId);
    }
    return command.operationId;
  }

  /// The roster is read in pages between two reads of the split's sequence
  /// number, and refused if a change landed in between. On an active split (or
  /// while this phone's own change is syncing) that happens for no reason the
  /// person can see, so read once more before giving up.
  /// The people in a split for a pop-up that is opening: this phone's copy at
  /// once (the last answer saved, else the stored members), with the live
  /// roster fetched behind it so the next open is current too. Writes still
  /// go through the queue and the server checks every one, so a slightly old
  /// roster can only change what is pre-selected, never what is saved.
  Future<SharedRoster> quickRoster(String id) async {
    try {
      final local = await runCacheOnly(() => contextRoster(id), allowLocal: true);
      unawaited(contextRoster(id).then<void>((_) {}, onError: (Object _) {}));
      return local;
    } catch (_) {
      return contextRoster(id);
    }
  }

  Future<SharedRoster> contextRoster(String id) async {
    try {
      return await _contextRosterOnce(id);
    } on SharedRuntimeUnavailable {
      _current();
      return _contextRosterOnce(id);
    }
  }

  Future<SharedRoster> _contextRosterOnce(String id) async {
    final before = await context(id);
    final pendingRenames = _pendingRenames(id);
    final roster = <SharedEditorMember>[];
    String? after, own;
    for (var page = 0; page < 4; page++) {
      final result = await members(id, after: after);
      for (final raw in result['items'] as List) {
        final row = raw as Map;
        // A declined join request stays on the server for history only.
        if (row['state'] == 'declined') continue;
        if (row['profileId'] == accountId && row['state'] == 'active') {
          own = row['memberId'] as String;
        }
        final memberId = row['memberId'] as String;
        // A rename waiting to sync shows straight away.
        final typed = pendingRenames[memberId] ?? row['displayName'] as String?;
        final suffix = row['phoneSuffix'];
        roster.add(
          SharedEditorMember(
            memberId,
            row['profileId'] == accountId
                ? 'You'
                : typed ??
                      (before['kind'] == 'direct' && row['role'] == 'owner'
                          ? before['name'] as String? ?? 'Member'
                          : 'Member'),
            state: row['state'] as String,
            role: row['role'] as String? ?? 'member',
            profileId: row['profileId'] as String?,
            phoneSuffix:
                suffix is String && RegExp(r'^[0-9]{4}$').hasMatch(suffix)
                ? suffix
                : null,
            rawName: typed,
          ),
        );
      }
      if (result['hasMore'] != true) {
        after = null;
        break;
      }
      final cursor = result['nextCursor'] as String?;
      if (cursor == null || cursor == after) {
        throw const SharedRuntimeUnavailable();
      }
      after = cursor;
    }
    final current = await context(id);
    if (after != null ||
        own == null ||
        current['state'] != 'active' ||
        before['committedSequence'] != current['committedSequence']) {
      throw const SharedRuntimeUnavailable();
    }
    _current();
    final ownMember = roster.firstWhere((m) => m.id == own);
    return SharedRoster(
      name: current['name'] as String,
      ownMemberId: own,
      members: List<SharedEditorMember>.unmodifiable(roster),
      direct: current['kind'] == 'direct',
      canInvite:
          canQueueProposals &&
          ownMember.role == 'owner' &&
          (current['kind'] != 'direct' || roster.length < 2),
      canShareLink: proposalsEnabled && ownMember.role == 'owner',
      ownerGone:
          proposalsEnabled &&
          !roster.any(
            (m) =>
                m.role == 'owner' && m.state == 'active' && m.profileId != null,
          ),
    );
  }

  Future<void> flushEditor() async {
    _current();
    syncLag = true;
    _notify();
    await refresh();
  }

  String expenseResponseId(
    String contextId,
    String expenseId,
    String revisionId,
  ) => const Uuid().v5(
    Namespace.url.value,
    'pandapay:expense-review:v1:$accountId:$contextId:$expenseId:$revisionId',
  );
  /// Removes an accepted expense by proposing a void revision over it. History
  /// is kept: the earlier revision stays, and the money is taken back out of
  /// the balances only when the server accepts the removal (at once when
  /// expenses post instantly, after everyone approves otherwise).
  Future<String> removeExpense({
    required String contextId,
    required String expenseId,
    required String headRevisionId,
    required String title,
    required String occurredOn,
  }) async {
    _current();
    if (!proposalsEnabled) throw const SharedRuntimeUnavailable();
    final command = SharedCommand(
      operationId: const Uuid().v4(),
      kind: 'expense.propose',
      payload: {
        'contextId': contextId,
        'expenseId': expenseId,
        'revisionId': const Uuid().v4(),
        'expectedHeadRevisionId': headRevisionId,
        'title': title,
        'occurredOn': occurredOn,
        'snapshot': null,
        'sources': <Object?>[],
        'void': true,
      },
    );
    await store.enqueue(command);
    await flushEditor();
    return command.operationId;
  }

  Future<String> respondToExpense(
    String contextId,
    String expenseId,
    String revisionId,
    String decision,
  ) async {
    _current();
    if (!canQueueProposals || !{'approve', 'reject'}.contains(decision)) {
      throw const SharedRuntimeUnavailable();
    }
    final command = SharedCommand(
      operationId: expenseResponseId(contextId, expenseId, revisionId),
      kind: 'expense.respond',
      payload: {
        'contextId': contextId,
        'expenseId': expenseId,
        'revisionId': revisionId,
        'decision': decision,
      },
    );
    await store.enqueue(command);
    await flushEditor();
    return command.operationId;
  }

  String settlementResponseId(String contextId, String settlementId) =>
      const Uuid().v5(
        Namespace.url.value,
        'pandapay:settlement-response:v1:$accountId:$contextId:$settlementId',
      );

  Future<String> respondToSettlement(
    String contextId,
    String settlementId,
    String decision,
  ) async {
    _current();
    if (!canQueueSettlements || !{'confirm', 'reject'}.contains(decision)) {
      throw const SharedRuntimeUnavailable();
    }
    final command = SharedCommand(
      operationId: settlementResponseId(contextId, settlementId),
      kind: 'settlement.respond',
      payload: {
        'contextId': contextId,
        'settlementId': settlementId,
        'decision': decision,
      },
    );
    await store.enqueue(command);
    await flushEditor();
    return command.operationId;
  }

  Future<String> reportSettlement({
    required String contextId,
    required String settlementId,
    required String payerMemberId,
    required String receiverMemberId,
    required String amountMinor,
    required String method,
    required String paidOn,
    String? reference,
  }) async {
    _current();
    if (!canQueueSettlements) {
      throw const SharedRuntimeUnavailable();
    }
    final command = SharedCommand(
      operationId: settlementReportId(contextId, settlementId),
      kind: 'settlement.report',
      payload: {
        'contextId': contextId,
        'settlementId': settlementId,
        'payerMemberId': payerMemberId,
        'receiverMemberId': receiverMemberId,
        'amountMinor': amountMinor,
        'currency': 'INR',
        'method': method,
        'paidOn': paidOn,
        if (reference != null && reference.isNotEmpty) 'reference': reference,
      },
    );
    await store.enqueue(command);
    await flushEditor();
    return command.operationId;
  }

  Future<Map<String, Object?>> settlements(String id, {String? after}) =>
      _query(
        'context:$id:settlements:${after ?? 'first'}',
        () => remote.fetchSettlements(id, after: after, limit: 50),
        contextId: id,
      );

  String settlementReportId(String contextId, String settlementId) =>
      const Uuid().v5(
        Namespace.url.value,
        'pandapay:settlement-report:v1:$accountId:$contextId:$settlementId',
      );

  String operationStatus(String id) {
    _current();
    final queued = store.operation(id), result = store.receipt(id)?.result;
    if (result is Map) {
      return switch (result['status']) {
        'renamed' => 'Name updated.',
        'confirmed' => 'Payment confirmed by receiver',
        'rejected' => 'Payment report rejected',
        'invited' => 'Person added. Tap Invite to send them a link.',
        'awaiting_receiver_confirmation' =>
          'Reported. Waiting for the receiver to confirm.',
        _ => 'Submitted. Refresh to see the latest.',
      };
    }
    return switch (queued?.state) {
      null => 'No saved submission · try again',
      SharedCommandState.conflict || SharedCommandState.rejected =>
        'Not accepted. Open the item to review it.',
      SharedCommandState.awaitingAuth =>
        'Saved on this device. Sign in to sync.',
      _ =>
        offline
            ? sharedSavedOfflineCopy
            : sharedSavedOfflineCopy,
    };
  }

  Future<Map<String, Object?>> context(String id) => _query(
    'context:$id:detail',
    () => remote.fetchContext(id),
    contextId: id,
  );
  Future<Map<String, Object?>> members(String id, {String? after}) => _query(
    'context:$id:members:${after ?? 'first'}',
    () => remote.fetchMembers(id, after: after, limit: 100),
    contextId: id,
  );
  Future<Map<String, Object?>> expenses(String id, {String? after}) => _query(
    'context:$id:expenses:${after ?? 'first'}',
    () => remote.fetchExpenses(id, after: after, limit: 50),
    contextId: id,
  );
  Future<Map<String, Object?>> balances(String id, {String? after}) => _query(
    'context:$id:balances:${after ?? 'first'}',
    () => remote.fetchBalances(id, after: after, limit: 100),
    contextId: id,
  );
  Future<Map<String, Object?>> totals(String id) =>
      _query('context:$id:totals', () => remote.fetchTotals(id), contextId: id);
  Future<Map<String, Object?>> revisions(
    String id,
    String expenseId, {
    String? after,
  }) => _query(
    'context:$id:revision:$expenseId:${after ?? 'first'}',
    () => remote.fetchExpenseRevisions(id, expenseId, after: after, limit: 50),
    contextId: id,
  );
  Future<Map<String, Object?>> expenseReviewPage(
    String contextId,
    String expenseId, {
    String? after,
  }) async {
    final before = await context(contextId);
    final names = <String, String>{};
    // A person with no name of their own is called by what the screen calls
    // them (a friend's page says "PandaPay friend"), not a bare "Member".
    final contextName = '${before['name'] ?? ''}'.trim();
    final unnamed = before['kind'] == 'direct'
        ? (contextName.isEmpty ? 'Your friend' : contextName)
        : 'Member';
    String? cursor;
    for (var page = 0; page < 4; page++) {
      final roster = await members(contextId, after: cursor);
      for (final raw in roster['items'] as List) {
        final member = raw as Map;
        names[member['memberId'] as String] = member['profileId'] == accountId
            ? 'You'
            : member['displayName'] as String? ?? unnamed;
      }
      if (roster['hasMore'] != true) {
        cursor = null;
        break;
      }
      final next = roster['nextCursor'] as String?;
      if (next == null || next == cursor) {
        throw const SharedRuntimeUnavailable();
      }
      cursor = next;
    }
    if (cursor != null) throw const SharedRuntimeUnavailable();
    final page = await revisions(contextId, expenseId, after: after);
    final current = await context(contextId);
    if (before['committedSequence'] != current['committedSequence']) {
      throw const SharedRuntimeUnavailable();
    }
    _current();
    return {...page, 'memberNames': Map<String, String>.unmodifiable(names)};
  }

  Future<Map<String, Object?>> expense(String id, String expenseId) => _query(
    'context:$id:expense:$expenseId',
    () => remote.fetchExpense(id, expenseId),
    contextId: id,
  );
  Future<Map<String, Object?>> activity(String id, {String? after}) => _query(
    'context:$id:activity:${after ?? 'first'}',
    () => remote.fetchActivity(id, after: after, limit: 50),
    contextId: id,
  );

  /// Whether the server has the one-request screen routes. Flips to false the
  /// first time it answers "no such route" (an older server) and stays so.
  bool _combinedScreens = true;

  /// The five sections of one split, as [context, members, expenses,
  /// balances, totals]. One request when the server supports it; otherwise (or
  /// when only an old per-section saved copy exists offline) the old five.
  Future<List<Map<String, Object?>>> _groupSections(
    String id,
    String? expenseAfter,
    String? balanceAfter,
  ) async {
    if (_combinedScreens) {
      try {
        final screen = await _query(
          'screen:$id:${expenseAfter ?? 'first'}:${balanceAfter ?? 'first'}',
          () => remote.fetchGroupScreen(
            id,
            expenseAfter: expenseAfter,
            balanceAfter: balanceAfter,
          ),
          contextId: id,
        );
        return [
          for (final key in const [
            'context',
            'members',
            'expenses',
            'balances',
            'totals',
          ])
            Map<String, Object?>.from(screen[key] as Map),
        ];
      } on SharedTransportException catch (error) {
        if (error.code == 'hub_unsupported') {
          _combinedScreens = false;
        } else if (_combinedDenied(error)) {
          rethrow;
        } else {
          try {
            final saved = await runCacheOnly(
              () => _groupSectionsLegacy(id),
              allowLocal: true,
            );
            _servedStale = true;
            return saved;
          } catch (_) {
            throw error;
          }
        }
      } on SharedRuntimeUnavailable {
        // Nothing saved under the new key yet: only the cache-only first
        // paint may fall back to the older saved sections.
        if (!_cacheOnly) rethrow;
      }
    }
    return _groupSectionsLegacy(id, expenseAfter, balanceAfter);
  }

  Future<List<Map<String, Object?>>> _groupSectionsLegacy(
    String id, [
    String? expenseAfter,
    String? balanceAfter,
  ]) => Future.wait([
    context(id),
    members(id),
    expenses(id, after: expenseAfter),
    balances(id, after: balanceAfter),
    totals(id),
  ]);

  Future<SharedGroupPresentation> loadGroup(
    String id, {
    String? expenseAfter,
    String? balanceAfter,
  }) async {
    _servedStale = false;
    final results = await _groupSections(id, expenseAfter, balanceAfter);
    _current();
    if (!_servedStale && !_cacheOnly) {
      _groupLive[id] = (at: DateTime.now(), version: dataVersion);
    }
    final details = results[0],
        roster = results[1],
        expensePage = results[2],
        balancePage = results[3],
        total = results[4];
    final own = total['memberId'] as String;
    final direct = details['kind'] == 'direct';
    final title = _directTitles[id] ?? details['name'] as String;
    final names = {
      for (final raw in roster['items'] as List)
        (raw as Map)['memberId']:
            raw['displayName'] ?? (direct ? title : 'Member'),
    };
    final expenseRows = <SharedExpenseRow>[];
    for (final raw in expensePage['items'] as List) {
      final row = Map<String, Object?>.from(raw as Map);
      final expense = mapSharedExpenseRecord(row, own);
      if (expense != null) expenseRows.add(expense);
    }
    final balanceRows = <SharedContextRow>[];
    for (final raw in balancePage['items'] as List) {
      final row = Map<String, Object?>.from(raw as Map),
          low = row['lowMemberId'],
          high = row['highMemberId'];
      if (low != own && high != own) continue;
      final amount =
          BigInt.parse(row['balanceMinor'] as String) *
          (low == own ? BigInt.one : -BigInt.one);
      final friend = (low == own ? high : low) as String;
      balanceRows.add(
        SharedContextRow(
          id: friend,
          title: names[friend] as String? ?? 'Member',
          balance: _summary(
            amount > BigInt.zero ? amount.toString() : '0',
            amount < BigInt.zero ? (-amount).toString() : '0',
          ),
        ),
      );
    }
    // Expenses saved on this phone and not yet confirmed lead the first page,
    // marked "Waiting to sync"; the server's copy replaces them by expense id.
    final shown = {for (final row in expenseRows) row.id};
    final waitingRows = <SharedExpenseRow>[
      if (expenseAfter == null)
        for (final op in _local.pending(contextId: id))
          if (op.command.kind == 'expense.propose')
            if (_waitingExpense(op, own) case final row?)
              if (shown.add(row.id)) row,
    ];
    expenseRows.insertAll(0, waitingRows);
    // What you and the others owe each other here, from the balances just
    // loaded (the page had no balance of its own, so its top line was empty).
    var owedHere = 0, owingHere = 0;
    for (final row in balanceRows) {
      owedHere += row.balance.owedToYou.paise;
      owingHere += row.balance.youOwe.paise;
    }
    final pageSummary = SharedBalanceSummary(
      owedToYou: Money.fromPaise(owedHere),
      youOwe: Money.fromPaise(owingHere),
      netBalance: Money.fromPaise(owedHere - owingHere),
      incomplete: balancePage['hasMore'] == true,
    );
    var breakdown = const <SharedBreakdownLine>[];
    if (direct) {
      try {
        breakdown = SharedPairIndex.read(store, accountId).linesFor(
          id,
          balanceRows.firstOrNull?.balance.netBalance.paise ?? 0,
        );
      } catch (_) {}
    }
    return SharedGroupPresentation(
      id: id,
      direct: direct,
      title: title,
      summary: pageSummary,
      breakdown: breakdown,
      expenses: SharedPage(
        items: expenseRows,
        hasMore: expensePage['hasMore'] == true,
        hasPrevious: expenseAfter != null,
        nextLabel: 'Next page',
        nextCursor: expensePage['nextCursor'] as String?,
        incomplete:
            syncLag ||
            expenseRows.length - waitingRows.length !=
                (expensePage['items'] as List).length,
      ),
      balances: SharedPage(
        items: balanceRows,
        hasMore: balancePage['hasMore'] == true,
        hasPrevious: balanceAfter != null,
        nextLabel: 'Next page',
        nextCursor: balancePage['nextCursor'] as String?,
        incomplete: syncLag || balancePage['hasMore'] == true,
      ),
      totals: SharedExpenseTotals(
        totalLabel: 'Shared expense total',
        paidLabel: 'Your shared contributions',
        billTotal: sharedMoneyFromMinor(total['sharedTotalMinor']),
        yourPaid: sharedMoneyFromMinor(total['yourPaidMinor']),
        yourShare: sharedMoneyFromMinor(total['yourShareMinor']),
        periodLabel: 'All reviewed expenses',
      ),
      offline: offline = _servedStale,
    );
  }

  /// A queued expense as a row marked "Waiting to sync". Its numbers come
  /// from the command itself (the bill, contributions and shares it carries).
  SharedExpenseRow? _waitingExpense(SharedQueuedCommand op, String own) {
    final p = op.command.toJson()['payload'] as Map;
    final snapshot = (p['snapshot'] as Map?) ?? const {};
    String sum(Object? rows) {
      var total = BigInt.zero;
      if (rows is List) {
        for (final r in rows) {
          if (r is Map && r['memberId'] == own) {
            total += BigInt.tryParse('${r['amountMinor']}') ?? BigInt.zero;
          }
        }
      }
      return total.toString();
    }

    final row = mapSharedExpenseRecord({
      'expenseId': p['expenseId'],
      'totalMinor': null,
      'pendingRevision': {
        'title': p['title'],
        'occurredOn': p['occurredOn'],
        'totalMinor': snapshot['totalMinor'],
        'bill': p['bill'],
        'void': p['void'] == true,
        'yourPaidMinor': sum(snapshot['contributions']),
        'yourShareMinor': sum(snapshot['shares']),
      },
    }, own);
    if (row == null) return null;
    return SharedExpenseRow(
      id: row.id,
      title: row.title,
      billTotal: row.billTotal,
      yourPaid: row.yourPaid,
      yourShare: row.yourShare,
      paidBy: row.paidBy,
      payerLabel: row.payerLabel,
      totalLabel: row.totalLabel,
      paidLabel: row.paidLabel,
      occurredAtLabel: row.occurredAtLabel,
      proposed: true,
      reviewLabel: 'Waiting to sync',
      participation: row.participation,
    );
  }

  /// Everything needed to open the expense editor on a split, read only from
  /// this phone (no network, no saved-copy lookup): the group's name, the
  /// viewer's member id and the people who can be added to an expense. A group
  /// created offline answers with just its owner (and any friend added
  /// offline); the owner's id is a stand-in the store swaps for the server's
  /// when the group's create commits. Null when this phone knows nothing about
  /// [contextId] (use [editorContext] online for that).
  ({String name, String ownMemberId, List<SharedEditorMember> members})?
  offlineEditorContext(String contextId) {
    _current();
    if (!sharedUuid(contextId) || store.isContextRevoked(contextId)) return null;
    final details = _local.detail(contextId);
    final own = _local.ownMemberId(contextId);
    if (details == null || own == null || details['state'] != 'active') {
      return null;
    }
    final names = _pendingRenames(contextId);
    return (
      name: _directTitles[contextId] ?? details['name'] as String,
      ownMemberId: own,
      members: List<SharedEditorMember>.unmodifiable([
        for (final row in _local.memberRows(contextId))
          if (row['state'] == 'active' || row['state'] == 'invited')
            SharedEditorMember(
              row['memberId'] as String,
              row['profileId'] == accountId
                  ? 'You'
                  : names[row['memberId']] ??
                        row['displayName'] as String? ??
                        'Member',
              state: row['state'] as String,
              role: row['role'] as String? ?? 'member',
              profileId: row['profileId'] as String?,
              rawName: names[row['memberId']] ?? row['displayName'] as String?,
            ),
      ]),
    );
  }

  /// Errors that must still surface: access was refused or the account moved.
  static bool _isDenied(Object e) {
    // "Nothing saved for this extra section" is not a refusal: the screen
    // marks the section incomplete and still shows the rest.
    if (e is SharedRuntimeUnavailable && e.reason == 'no_saved_copy') {
      return false;
    }
    return e is! SharedTransportException ||
        e.statusCode == 401 ||
        e.statusCode == 403 ||
        e.statusCode == 404 ||
        e.code == 'account_changed';
  }

  bool _combinedHub = true;

  /// Reopening Splits within this window of a live load, with nothing changed
  /// since, paints the saved copy and asks the server nothing.
  static const _liveFresh = Duration(seconds: 20);
  DateTime? _hubLiveAt;
  int _hubLiveVersion = -1;
  final _groupLive = <String, ({DateTime at, int version})>{};
  bool hubFresh() =>
      _hubLiveAt != null &&
      _hubLiveVersion == dataVersion &&
      DateTime.now().difference(_hubLiveAt!) < _liveFresh;
  bool groupFresh(String id) {
    final live = _groupLive[id];
    return live != null &&
        live.version == dataVersion &&
        DateTime.now().difference(live.at) < _liveFresh;
  }

  /// Refusals that a per-section retry would not change: not allowed, account
  /// moved, feature off.
  static bool _combinedDenied(SharedTransportException e) =>
      e.statusCode == 401 ||
      e.statusCode == 403 ||
      e.statusCode == 404 && e.code != 'invalid_response' ||
      e.code == 'account_changed' ||
      e.code == 'feature_disabled' ||
      e.code == 'feature_unavailable';

  /// [friends, groups, overview, activity] for the hub: one request when the
  /// server supports it, else the four old ones. The totals strip and the
  /// activity tab are extras on the old path; on the one-request path the
  /// server answers for the whole screen.
  Future<
    ({
      List<Map<String, Object?>> results,
      bool summaryKnown,
      bool activityKnown,
    })
  >
  _hubSections(
    Map<SharedHubTab, String?> after,
    Map<SharedHubTab, String> searches,
  ) async {
    if (_combinedHub) {
      try {
        String enc(SharedHubTab tab) =>
            Uri.encodeComponent(searches[tab] ?? '');
        String cur(SharedHubTab tab) => after[tab] ?? 'first';
        final hub = await _query(
          'hub:${enc(SharedHubTab.friends)}:${cur(SharedHubTab.friends)}|'
          '${enc(SharedHubTab.groups)}:${cur(SharedHubTab.groups)}|'
          '${enc(SharedHubTab.activity)}:${cur(SharedHubTab.activity)}',
          () => remote.fetchHub(
            friendsAfter: after[SharedHubTab.friends],
            groupsAfter: after[SharedHubTab.groups],
            activityAfter: after[SharedHubTab.activity],
            friendsSearch: searches[SharedHubTab.friends],
            groupsSearch: searches[SharedHubTab.groups],
            activitySearch: searches[SharedHubTab.activity],
          ),
        );
        return (
          results: [
            for (final key in const [
              'friends',
              'groups',
              'overview',
              'activity',
            ])
              Map<String, Object?>.from(hub[key] as Map),
          ],
          summaryKnown: true,
          activityKnown: true,
        );
      } on SharedTransportException catch (error) {
        if (error.code == 'hub_unsupported') {
          _combinedHub = false;
        } else if (_combinedDenied(error)) {
          rethrow;
        } else {
          // The server is failing or unreachable: do not send it four more
          // requests. Use an older per-section saved copy if there is one,
          // otherwise report the failure.
          try {
            final saved = await runCacheOnly(
              () => _hubSectionsLegacy(after, searches),
              allowLocal: true,
            );
            _servedStale = true;
            return saved;
          } catch (_) {
            throw error;
          }
        }
      } on SharedRuntimeUnavailable {
        if (!_cacheOnly) rethrow;
      }
    }
    return _hubSectionsLegacy(after, searches);
  }

  Future<
    ({
      List<Map<String, Object?>> results,
      bool summaryKnown,
      bool activityKnown,
    })
  >
  _hubSectionsLegacy(
    Map<SharedHubTab, String?> after,
    Map<SharedHubTab, String> searches,
  ) async {
    var summaryKnown = true, activityKnown = true;
    Future<Map<String, Object?>> contextsFor(
      SharedHubTab tab,
      String kind,
    ) => _query(
      'contexts:$kind:${Uri.encodeComponent(searches[tab] ?? '')}:${after[tab] ?? 'first'}',
      () => remote.fetchContexts(
        kind: kind,
        search: searches[tab],
        after: after[tab],
        limit: 50,
      ),
    );
    final results = await Future.wait([
      contextsFor(SharedHubTab.friends, 'direct'),
      contextsFor(SharedHubTab.groups, 'group'),
      // The totals strip and the activity tab are extras: if one of them
      // cannot load, the friends and groups still show (marked incomplete).
      _query('overview', remote.fetchOverview).catchError((Object e) {
        if (_isDenied(e)) throw e;
        summaryKnown = false;
        return <String, Object?>{};
      }),
      _query(
        'personal-activity:${Uri.encodeComponent(searches[SharedHubTab.activity] ?? '')}:${after[SharedHubTab.activity] ?? 'first'}',
        () => remote.fetchPersonalActivity(
          after: after[SharedHubTab.activity],
          search: searches[SharedHubTab.activity],
        ),
      ).catchError((Object e) {
        if (_isDenied(e)) throw e;
        activityKnown = false;
        return <String, Object?>{'items': <Object?>[], 'hasMore': false};
      }),
    ]);
    return (
      results: results,
      summaryKnown: summaryKnown,
      activityKnown: activityKnown,
    );
  }

  Future<SharedHubPresentation> loadHub({
    Map<SharedHubTab, String?> after = const {},
    Map<SharedHubTab, String> searches = const {},
  }) async {
    _servedStale = false;
    final sections = await _hubSections(after, searches);
    final results = sections.results;
    final summaryKnown = sections.summaryKnown,
        activityKnown = sections.activityKnown;
    _current();
    if (!_servedStale && !_cacheOnly) {
      _hubLiveAt = DateTime.now();
      _hubLiveVersion = dataVersion;
    }
    // Commands still on this phone: groups and friends the server has not
    // confirmed yet, and a "Waiting to sync" line per change. Matched by the
    // context id, so the server's copy replaces them the moment it arrives.
    final waiting = _local.pending();
    final onPage = {
      for (final data in [results[0], results[1]])
        for (final raw in data['items'] as List) (raw as Map)['contextId'],
    };
    final waitingNames = <Object?, String>{
      for (final op in waiting)
        if (op.command.kind == 'context.create')
          op.command.contextId:
              (op.command.toJson()['payload'] as Map)['name'] as String,
    };
    // What each friend and you owe each other in every group, from this
    // phone's copy, so a friend shows one total and a line per group.
    SharedPairIndex? pairs;
    try {
      pairs = SharedPairIndex.read(store, accountId);
    } catch (_) {}
    SharedContextRow withGroups(SharedContextRow row) {
      final lines =
          pairs?.linesFor(row.id, row.balance.netBalance.paise) ?? const [];
      if (lines.isEmpty) return row;
      final total = sharedSummaryOfLines(lines, row.balance);
      return SharedContextRow(
        id: row.id,
        title: row.title,
        subtitle: row.subtitle,
        balance: total,
        breakdown: lines,
        state:
            total.owedToYou.isZero && total.youOwe.isZero
                ? row.state
                : SharedContextState.active,
      );
    }

    SharedPage<SharedContextRow> contextPage(
      Map<String, Object?> data,
      SharedHubTab tab,
    ) {
      final first = after[tab] == null && (searches[tab] ?? '').isEmpty;
      final kind = tab == SharedHubTab.friends ? 'direct' : 'group';
      return SharedPage(
        items: [
          if (first)
            for (final op in waiting)
              if (op.command.kind == 'context.create' &&
                  (op.command.toJson()['payload'] as Map)['contextKind'] ==
                      kind &&
                  !onPage.contains(op.command.contextId))
                _contextRow({
                  ...(Map<String, Object?>.from(
                    op.command.toJson()['payload'] as Map,
                  )),
                  'contextId': op.command.contextId,
                  'waiting': true,
                }),
          for (final row in contextRows(data['items'] as List))
            tab == SharedHubTab.friends ? withGroups(row) : row,
        ],
        hasMore: data['hasMore'] == true,
        incomplete: syncLag,
        hasPrevious: after[tab] != null,
        nextLabel: 'Next page',
        nextCursor: data['nextCursor'] as String?,
      );
    }

    final activityPage = results[3];
    final activityLookups = <String, _ActivityLookup>{};
    return SharedHubPresentation(
      summary: summaryKnown
          ? _summary(results[2]['owedMinor'], results[2]['owingMinor'])
          : const SharedBalanceSummary(
              owedToYou: Money.zero(),
              youOwe: Money.zero(),
              netBalance: Money.zero(),
              incomplete: true,
            ),
      friends: contextPage(results[0], SharedHubTab.friends),
      groups: contextPage(results[1], SharedHubTab.groups),
      activity: SharedPage(
        items: [
          if (after[SharedHubTab.activity] == null &&
              (searches[SharedHubTab.activity] ?? '').isEmpty)
            for (final op in waiting.take(20))
              if (_waitingCopy(op.command.kind) case final copy?)
                SharedActivityRow(
                  id: op.command.contextId,
                  description: 'Waiting to sync · $copy',
                  contextLabel:
                      _directTitles[op.command.contextId] ??
                      waitingNames[op.command.contextId] ??
                      _nameOnPage(results, op.command.contextId),
                  occurredAtLabel: 'Just now',
                ),
          for (final raw in activityPage['items'] as List)
            _activityRow(raw as Map, activityLookups),
        ],
        hasMore: activityPage['hasMore'] == true,
        incomplete: syncLag || !activityKnown,
        hasPrevious: after[SharedHubTab.activity] != null,
        nextLabel: 'Next page',
        nextCursor: activityPage['nextCursor'] as String?,
      ),
      offline: offline = _servedStale,
      pendingChanges: store.waitingCount,
    );
  }

  /// Rows for a list of context records, with a just-typed friend name shown
  /// at once and a number ending under rows that would look identical.
  @visibleForTesting
  List<SharedContextRow> contextRows(List<Object?> items) {
    final rows = [
      for (final raw in items)
        if (!store.isContextRevoked((raw as Map)['contextId'] as String))
          _contextRow(Map<String, Object?>.from(raw)),
    ];
    final hints = sharedSameNameHints([
      for (final raw in items)
        if (!store.isContextRevoked((raw as Map)['contextId'] as String))
          (
            id: raw['contextId'] as String,
            label: _directTitles[raw['contextId']] ?? raw['name'] as String,
            suffix: _suffixOf(
              raw['counterpartPhoneSuffix'] ?? raw['phoneSuffix'],
            ),
          ),
    ]);
    return [
      for (final r in rows)
        hints[r.id] == null || r.subtitle != null
            ? r
            : SharedContextRow(
                id: r.id,
                title: r.title,
                balance: r.balance,
                state: r.state,
                subtitle: hints[r.id],
                breakdown: r.breakdown,
              ),
    ];
  }

  static String? _suffixOf(Object? v) =>
      v is String && RegExp(r'^[0-9]{4}$').hasMatch(v) ? v : null;

  SharedContextRow _contextRow(Map<String, Object?> row) {
    final invited = row['membershipState'] == 'invited';
    final waiting = row['waiting'] == true;
    final known =
        waiting || row['owedMinor'] is String && row['owingMinor'] is String;
    final balance = waiting
        ? _summary('0', '0')
        : known
        ? _summary(row['owedMinor'], row['owingMinor'])
        : const SharedBalanceSummary(
            owedToYou: Money.zero(),
            youOwe: Money.zero(),
            netBalance: Money.zero(),
            incomplete: true,
          );
    return SharedContextRow(
      id: row['contextId'] as String,
      title: _directTitles[row['contextId']] ?? row['name'] as String,
      balance: balance,
      subtitle: waiting ? 'Waiting to sync' : null,
      state: waiting
          ? SharedContextState.active
          : invited
          ? SharedContextState.pendingInvite
          : !known
          ? SharedContextState.incomplete
          : row['hasUnacceptedExpenses'] == true
          ? SharedContextState.pendingReview
          : row['expenseCount'] == '0'
          ? SharedContextState.noExpenses
          : balance.owedToYou.isZero && balance.youOwe.isZero
          ? SharedContextState.settled
          : SharedContextState.active,
    );
  }

  static String? _nameOnPage(
    List<Map<String, Object?>> results,
    String contextId,
  ) {
    for (final data in [results[0], results[1]]) {
      for (final raw in data['items'] as List) {
        if ((raw as Map)['contextId'] == contextId) return raw['name'] as String?;
      }
    }
    return null;
  }

  /// What a command still waiting to be sent is called on the activity tab.
  static String? _waitingCopy(String kind) => switch (kind) {
    'context.create' => 'Group created',
    'member.invite' => 'Member added',
    'expense.propose' => 'Expense submitted for review',
    'settlement.report' => 'Payment reported',
    'settlement.respond' => 'Payment response',
    'expense.respond' => 'Expense review',
    _ => null,
  };

  /// One Activity row in words a person reads at a glance: who did what to
  /// which expense, and what it meant for them ("Sujay added “ZOMATO”",
  /// "You lent ₹2,000.00"). The server's event says only what kind of thing
  /// happened and to which expense or payment; the names, titles and amounts
  /// come from this phone's copy of the split. An amount is shown only when it
  /// belongs to that very event (the expense's accepted version is the one the
  /// event is about, or the payment's own amount), never today's figure on an
  /// old event.
  @visibleForTesting
  SharedActivityRow describeActivity(Map<Object?, Object?> raw) =>
      _activityRow(raw, {});

  SharedActivityRow _activityRow(
    Map<Object?, Object?> raw,
    Map<String, _ActivityLookup> cache,
  ) {
    final contextId = raw['contextId'] as String;
    final contextLabel =
        _directTitles[contextId] ?? raw['contextName'] as String?;
    final createdAt = raw['createdAt'] as String;
    final kind = raw['kind'];
    final payload = raw['payload'] is Map ? raw['payload'] as Map : const {};
    SharedActivityRow plain([String? text]) => SharedActivityRow(
      id: contextId,
      description: text ?? _activityCopy(kind),
      contextLabel: contextLabel,
      occurredAtLabel: createdAt,
    );
    _ActivityLookup? look;
    try {
      look = cache[contextId] ??= _ActivityLookup.read(
        store,
        _local,
        contextId,
        accountId,
      );
    } catch (_) {
      return plain();
    }
    final actor = raw['actorProfileId'] == accountId
        ? 'You'
        : look.nameOfProfile(raw['actorProfileId']) ?? 'Someone';
    String member(Object? id) => look!.nameOfMember(id) ?? 'Someone';
    switch (kind) {
      case 'expense.proposed' || 'expense.accepted' || 'expense.responded':
        final head = look.expenses[payload['expenseId']];
        final title = head?.title;
        if (title == null) return plain();
        final current =
            head!.acceptedRevisionId != null &&
            head.acceptedRevisionId == payload['revisionId'];
        final text = switch (kind) {
          'expense.responded' => '$actor reviewed “$title”',
          _ when current && head.isVoid => '$actor removed “$title”',
          'expense.proposed' => '$actor added “$title” · waiting for approval',
          _ => '$actor added “$title”',
        };
        if (!current || head.isVoid || kind == 'expense.responded') {
          return plain(text);
        }
        final net = head.yourPaidMinor - head.yourShareMinor;
        return SharedActivityRow(
          id: contextId,
          description: text,
          contextLabel: contextLabel,
          occurredAtLabel: createdAt,
          impactLabel: head.yourPaidMinor == 0 && head.yourShareMinor == 0
              ? 'Not involved'
              : net < 0
              ? 'You borrowed'
              : net > 0
              ? 'You lent'
              : 'You paid your share',
          impactAmount: net == 0 ? null : Money.fromPaise(net.abs()),
        );
      case 'settlement.reported' ||
          'settlement.confirmed' ||
          'settlement.rejected':
        final payer = member(payload['payerMemberId']);
        final receiver = member(payload['receiverMemberId']);
        final amount = int.tryParse('${payload['amountMinor']}');
        final paid = payer == 'You'
            ? 'You paid $receiver'
            : receiver == 'You'
            ? '$payer paid you'
            : '$payer paid $receiver';
        final money = amount == null
            ? ''
            : ' ${Money.fromPaise(amount).format()}';
        return plain(switch (kind) {
          'settlement.reported' => '$paid$money · waiting for confirmation',
          'settlement.confirmed' => '$paid$money · confirmed',
          _ => '$paid$money · not confirmed',
        });
      case 'member.invited':
        return plain('${member(payload['memberId'])} was invited');
      case 'membership.claimed':
        return plain('${member(payload['memberId'])} joined');
      case 'membership.requested':
        return plain('${member(payload['memberId'])} asked to join');
      case 'membership.left':
        return plain('${member(payload['memberId'])} left');
      case 'member.removed':
        return plain('${member(payload['memberId'])} was removed');
      case 'context.created':
        return plain(
          look.direct ? '$actor started splitting' : '$actor created the group',
        );
    }
    return plain();
  }

  static String _activityCopy(Object? kind) => switch (kind) {
    'context.created' => 'Group created',
    'membership.invited' => 'Member invited',
    'membership.responded' => 'Membership updated',
    'member.renamed' => 'Name changed',
    'expense.proposed' => 'Expense submitted for review',
    'expense.responded' => 'Expense review updated',
    'settlement.reported' => 'Payment reported · awaiting confirmation',
    'settlement.confirmed' => 'Payment confirmed',
    'settlement.rejected' => 'Payment report rejected',
    _ => 'Shared expense updated',
  };
  static SharedBalanceSummary _summary(Object? owed, Object? owing) {
    final a = sharedMoneyFromMinor(owed), b = sharedMoneyFromMinor(owing);
    return SharedBalanceSummary(
      owedToYou: a,
      youOwe: b,
      netBalance: Money.fromPaise(a.paise - b.paise),
    );
  }
}

/// What one context's Activity rows need from this phone's copy: member names
/// and each expense's accepted version, read once per context per page.
class _ActivityLookup {
  _ActivityLookup._(this.direct, this._names, this._profiles, this.expenses);
  final bool direct;
  final Map<String, String> _names;
  final Map<String, String> _profiles;
  final Map<Object?, _ActivityExpense> expenses;

  String? nameOfMember(Object? id) => _names[id];
  String? nameOfProfile(Object? id) => _profiles[id];

  static _ActivityLookup read(
    SharedExpensesStore store,
    SharedLocalReads reads,
    String contextId,
    String accountId,
  ) {
    final members = reads.memberRows(contextId);
    final names = <String, String>{}, profiles = <String, String>{};
    String? own;
    for (final m in members) {
      final id = m['memberId'], profile = m['profileId'];
      if (id is! String) continue;
      final mine = profile == accountId;
      if (mine) own = id;
      final name = mine
          ? 'You'
          : ('${m['displayName'] ?? ''}'.trim().isEmpty
                ? 'Someone'
                : '${m['displayName']}'.trim());
      names[id] = name;
      if (profile is String) profiles[profile] = name;
    }
    final expenses = <Object?, _ActivityExpense>{};
    for (final row in store
        .readPage(entity: 'expenses', contextId: contextId, limit: 100)
        .items) {
      final p = row.payload;
      if (p is! Map || p['recordType'] != 'head') continue;
      final accepted = p['accepted'];
      if (accepted is! Map) continue;
      final snapshot = accepted['snapshot'];
      int sum(Object? list) {
        var total = 0;
        if (list is List) {
          for (final x in list) {
            if (x is Map && x['memberId'] == own) {
              total += int.tryParse('${x['amountMinor']}') ?? 0;
            }
          }
        }
        return total;
      }

      expenses[p['expenseId']] = _ActivityExpense(
        title: '${accepted['title'] ?? 'an expense'}',
        acceptedRevisionId: accepted['revisionId'] as String?,
        isVoid: accepted['void'] == true,
        yourPaidMinor: snapshot is Map ? sum(snapshot['contributions']) : 0,
        yourShareMinor: snapshot is Map ? sum(snapshot['shares']) : 0,
      );
    }
    final context = store
        .readContexts(limit: 100)
        .items
        .where((c) => c.id == contextId)
        .firstOrNull;
    final kind = context?.payload is Map ? (context!.payload as Map)['kind'] : null;
    return _ActivityLookup._(kind == 'direct', names, profiles, expenses);
  }
}

class _ActivityExpense {
  const _ActivityExpense({
    required this.title,
    required this.acceptedRevisionId,
    required this.isVoid,
    required this.yourPaidMinor,
    required this.yourShareMinor,
  });
  final String title;
  final String? acceptedRevisionId;
  final bool isVoid;
  final int yourPaidMinor;
  final int yourShareMinor;
}

