import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/shared_expenses.dart';
import 'package:uuid/uuid.dart';
import '../../../data/local/response_cache.dart';
import '../data/shared_commands.dart';
import '../data/shared_http_transport.dart';
import '../data/shared_transport.dart';
import '../storage/shared_store.dart';
import '../sync/shared_sync.dart';
import '../ui/shared_presentation.dart';
import '../composer/shared_editor.dart';
import 'shared_expense_mapping.dart';

class SharedRuntimeUnavailable implements Exception {
  const SharedRuntimeUnavailable();
  @override
  String toString() => 'Shared expenses are not available for this account yet';
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
    final before = await context(id);
    final roster = <SharedEditorMember>[];
    String? after, own;
    for (var page = 0; page < 2; page++) {
      final result = await members(id, after: after);
      for (final raw in result['items'] as List) {
        final row = raw as Map;
        if (!['active', 'invited'].contains(row['state'])) continue;
        if (row['profileId'] == accountId && row['state'] == 'active') {
          own = row['memberId'] as String;
        }
        roster.add(
          SharedEditorMember(
            row['memberId'] as String,
            row['profileId'] == accountId
                ? 'You'
                : row['displayName'] as String? ?? 'Member',
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
    return (
      name: current['name'] as String,
      ownMemberId: own,
      members: List<SharedEditorMember>.unmodifiable(roster),
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
    for (var page = 0; page < 2; page++) {
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
      title: details['name'] as String,
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
        items: [
          for (final raw in data['items'] as List)
            if (!store.isContextRevoked((raw as Map)['contextId'] as String))
              _contextRow(Map<String, Object?>.from(raw)),
        ],
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
              contextLabel: raw['contextName'] as String?,
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
      pendingChanges: store.pendingCount,
    );
  }

  static SharedContextRow _contextRow(Map<String, Object?> row) {
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
      title: row['name'] as String,
      balance: balance,
      state: invited
          ? SharedContextState.pendingInvite
          : !known
          ? SharedContextState.incomplete
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
