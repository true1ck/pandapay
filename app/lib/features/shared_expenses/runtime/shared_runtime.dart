import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/shared_expenses.dart';
import 'package:uuid/uuid.dart';
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

class SharedRuntimeUnavailable implements Exception {
  const SharedRuntimeUnavailable();
  @override
  String toString() => 'Shared expenses are not available for this account yet';
}

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
  int get accessGeneration => _accessGeneration;
  String get accountId => store.namespace.substring(5);
  void _current() {
    if (_disposed || !isCurrent()) throw const SharedRuntimeUnavailable();
  }

  void _notify() {
    if (!_disposed && isCurrent()) notifyListeners();
  }

  /// Invalidate in-flight aggregates before any asynchronous purge. A late
  /// authorized-at-start response must never resurrect revoked private data.
  Future<void> revokeContext(String contextId) async {
    _current();
    _accessGeneration++;
    await store.recoveryGate.run(() async {
      await cache.clearPrefix('${store.namespace}:shared:');
      _current();
      await store.revokeContext(contextId);
      _notify();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> refresh({int maxPullPages = 2}) async {
    _current();
    if (busy) return;
    if (maxPullPages < 1 || maxPullPages > 5) {
      throw ArgumentError.value(maxPullPages);
    }
    busy = true;
    lastError = null;
    _notify();
    try {
      await store.recoveryGate.run(() async {
        final flags = await remote.fetchCapabilities();
        _current();
        capabilities = flags;
        if (!readsEnabled) throw const SharedRuntimeUnavailable();
        await store.resumeAuthentication();
        // Each queued kind remains capability checked by the authoritative SQL
        // command; a disabled flag cannot silently change a stored command.
        if (proposalsEnabled || settlementsEnabled) await sync.flush();
        for (var i = 0; i < maxPullPages; i++) {
          final before = store.cursor,
              page = await remote.pull(cursor: before, limit: 100);
          _current();
          if (page.revokedContextIds.isNotEmpty) {
            // Remove stale query summaries before acknowledging access loss.
            _accessGeneration++;
            await cache.clearPrefix('${store.namespace}:shared:');
            _current();
          }
          await store.applyPage(page, expectedCursor: before);
          syncLag = page.hasMore;
          if (!page.hasMore) break;
        }
        offline = false;
      });
    } catch (error) {
      lastError = error;
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

  Future<String> submit(
    String kind,
    Map<String, Object?> payload, {
    List<String> dependsOn = const [],
    Map<String, Object?>? provisional,
  }) async {
    _current();
    if (!readsEnabled ||
        (kind.startsWith('settlement.')
            ? !settlementsEnabled
            : !proposalsEnabled)) {
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
    await refresh();
    return command.operationId;
  }

  Future<String> createDirectFriend(String name) async =>
      (await _enqueueFriend(name)).contextId;

  Future<({String contextId, String memberId})> _enqueueFriend(
    String name,
  ) async {
    _current();
    if (!proposalsEnabled ||
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
    if (refused != null) throw refused;
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
      final wanted = name.trim().toLowerCase();
      final page = await remote.fetchContexts(
        kind: 'direct',
        search: name.trim(),
      );
      for (final raw in (page['items'] as List? ?? const [])) {
        final row = raw as Map;
        if ((row['name'] as String? ?? '').trim().toLowerCase() == wanted) {
          return row['contextId'] as String?;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<SharedInboxInvite>> inviteInbox() async {
    _current();
    if (!proposalsEnabled) return const [];
    final items = await remote.fetchInviteInbox();
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
  Future<SharedInviteLink> createGroupLink(String contextId) async {
    _current();
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    final link = await remote.createGroupLink(
      contextId: contextId,
      linkId: const Uuid().v4(),
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

  Future<List<SharedJoinRequest>> joinRequests() async {
    _current();
    if (!proposalsEnabled) return const [];
    final items = await remote.fetchJoinRequests();
    _current();
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
  }) async {
    _current();
    if (!proposalsEnabled) throw const SharedRuntimeUnavailable();
    final status = await remote.respondToJoinRequest(
      invitationId: invitationId,
      operationId: const Uuid().v4(),
      approve: approve,
    );
    _current();
    await refresh();
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
    if (!readsEnabled) throw const SharedRuntimeUnavailable();
    if (contextId != null && store.isContextRevoked(contextId)) {
      throw const SharedRuntimeUnavailable();
    }
    final cacheKey = '${store.namespace}:shared:$key';
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
      if (error.code != 'network_unavailable' &&
          error.statusCode != 408 &&
          error.statusCode != 429) {
        rethrow;
      }
      authorized();
      final saved = await cache.get(cacheKey);
      authorized();
      if (saved == null) rethrow;
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
    if (!proposalsEnabled || store.isContextRevoked(contextId)) {
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

  Future<SharedRoster> contextRoster(String id) async {
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
          proposalsEnabled &&
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
  Future<String> respondToExpense(
    String contextId,
    String expenseId,
    String revisionId,
    String decision,
  ) async {
    _current();
    if (!proposalsEnabled || !{'approve', 'reject'}.contains(decision)) {
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
    if (!settlementsEnabled || !{'confirm', 'reject'}.contains(decision)) {
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
    if (!settlementsEnabled) {
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
      _ => 'Saved on this device · waiting to sync',
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
    String? cursor;
    for (var page = 0; page < 4; page++) {
      final roster = await members(contextId, after: cursor);
      for (final raw in roster['items'] as List) {
        final member = raw as Map;
        names[member['memberId'] as String] = member['profileId'] == accountId
            ? 'You'
            : member['displayName'] as String? ?? 'Member';
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

  Future<SharedGroupPresentation> loadGroup(
    String id, {
    String? expenseAfter,
    String? balanceAfter,
  }) async {
    offline = false;
    final results = await Future.wait([
      context(id),
      members(id),
      expenses(id, after: expenseAfter),
      balances(id, after: balanceAfter),
      totals(id),
    ]);
    _current();
    final details = results[0],
        roster = results[1],
        expensePage = results[2],
        balancePage = results[3],
        total = results[4];
    final own = total['memberId'] as String;
    final names = {
      for (final raw in roster['items'] as List)
        (raw as Map)['memberId']: raw['displayName'] ?? 'Member',
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
    return SharedGroupPresentation(
      id: id,
      direct: details['kind'] == 'direct',
      title: _directTitles[id] ?? details['name'] as String,
      expenses: SharedPage(
        items: expenseRows,
        hasMore: expensePage['hasMore'] == true,
        hasPrevious: expenseAfter != null,
        nextLabel: 'Next page',
        nextCursor: expensePage['nextCursor'] as String?,
        incomplete:
            syncLag ||
            expenseRows.length != (expensePage['items'] as List).length,
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
      offline: offline,
    );
  }

  Future<SharedHubPresentation> loadHub({
    Map<SharedHubTab, String?> after = const {},
    Map<SharedHubTab, String> searches = const {},
  }) async {
    offline = false;
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
      _query('overview', remote.fetchOverview),
      _query(
        'personal-activity:${Uri.encodeComponent(searches[SharedHubTab.activity] ?? '')}:${after[SharedHubTab.activity] ?? 'first'}',
        () => remote.fetchPersonalActivity(
          after: after[SharedHubTab.activity],
          search: searches[SharedHubTab.activity],
        ),
      ),
    ]);
    _current();
    SharedPage<SharedContextRow> contextPage(
      Map<String, Object?> data,
      SharedHubTab tab,
    ) {
      return SharedPage(
        items: contextRows(data['items'] as List),
        hasMore: data['hasMore'] == true,
        incomplete: syncLag,
        hasPrevious: after[tab] != null,
        nextLabel: 'Next page',
        nextCursor: data['nextCursor'] as String?,
      );
    }

    final activityPage = results[3];
    return SharedHubPresentation(
      summary: _summary(results[2]['owedMinor'], results[2]['owingMinor']),
      friends: contextPage(results[0], SharedHubTab.friends),
      groups: contextPage(results[1], SharedHubTab.groups),
      activity: SharedPage(
        items: [
          for (final raw in activityPage['items'] as List)
            SharedActivityRow(
              id: (raw as Map)['contextId'] as String,
              description: _activityCopy(raw['kind']),
              contextLabel:
                  _directTitles[raw['contextId']] ??
                  raw['contextName'] as String?,
              occurredAtLabel: raw['createdAt'] as String,
            ),
        ],
        hasMore: activityPage['hasMore'] == true,
        incomplete: syncLag,
        hasPrevious: after[SharedHubTab.activity] != null,
        nextLabel: 'Next page',
        nextCursor: activityPage['nextCursor'] as String?,
      ),
      offline: offline,
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
              ),
    ];
  }

  static String? _suffixOf(Object? v) =>
      v is String && RegExp(r'^[0-9]{4}$').hasMatch(v) ? v : null;

  SharedContextRow _contextRow(Map<String, Object?> row) {
    final invited = row['membershipState'] == 'invited';
    final known = row['owedMinor'] is String && row['owingMinor'] is String;
    final balance = known
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
      state: invited
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

  static String _activityCopy(Object? kind) => switch (kind) {
    'context.created' => 'Group created',
    'membership.invited' => 'Member invited',
    'membership.responded' => 'Membership updated',
    'member.renamed' => 'Name changed',
    'expense.proposed' => 'Expense submitted for review',
    'expense.responded' => 'Expense review updated',
    'settlement.reported' => 'Payment reported Â· awaiting confirmation',
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
