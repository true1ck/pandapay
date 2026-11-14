import 'package:pandapay_domain/pandapay_domain.dart' show Money;

import '../storage/shared_store.dart';
import '../ui/shared_presentation.dart';
import 'shared_local_reads.dart';

/// What you and each person owe each other in every friend and group context,
/// read from this phone's own copy of Splits (the pair balances it already
/// keeps for every context). Lets a friend be shown the Splitwise way: one
/// total, then a line per group and one for expenses outside any group.
///
/// Bounded like the screens: the first 100 contexts and the first 100 pair
/// balances in each. People are matched across contexts by their account, so
/// someone invited but not yet joined only shows in the context they are in.
class SharedPairIndex {
  SharedPairIndex._(this._byPerson, this._friendOf, this._names);

  /// person key (account id, or `ctx:<id>` for an unjoined friend) ->
  /// (context id, amount in minor units; positive = they owe you).
  final Map<String, List<(String, int)>> _byPerson;

  /// friend context id -> person key.
  final Map<String, String> _friendOf;

  /// context id -> (name, is a friend context).
  final Map<String, (String, bool)> _names;

  static SharedPairIndex read(SharedExpensesStore store, String accountId) {
    final reads = SharedLocalReads(store, accountId);
    final byPerson = <String, List<(String, int)>>{};
    final friendOf = <String, String>{};
    final names = <String, (String, bool)>{};
    for (final context in store.readContexts(limit: 100).items) {
      final payload = context.payload;
      if (payload is! Map || payload['state'] == 'archived') continue;
      final id = context.id;
      final direct = payload['kind'] == 'direct';
      names[id] = ('${payload['name'] ?? ''}'.trim(), direct);
      final members = reads.memberRows(id);
      final own = members
          .where((m) => m['profileId'] == accountId && m['state'] == 'active')
          .map((m) => m['memberId'])
          .firstOrNull;
      if (own == null) continue;
      String personOf(Object? memberId) {
        final profile = members
            .where((m) => m['memberId'] == memberId)
            .map((m) => m['profileId'])
            .firstOrNull;
        return profile is String ? profile : 'ctx:$id';
      }

      if (direct) {
        final other = members
            .where((m) => m['memberId'] != own && m['state'] != 'removed')
            .map((m) => m['memberId'])
            .firstOrNull;
        if (other != null) friendOf[id] = personOf(other);
      }
      for (final row
          in store
              .readPage(entity: 'balances', contextId: id, limit: 100)
              .items) {
        final b = row.payload;
        if (b is! Map) continue;
        final low = b['lowMemberId'], high = b['highMemberId'];
        if (low != own && high != own) continue;
        final raw = int.tryParse('${b['balanceMinor']}') ?? 0;
        final amount = low == own ? raw : -raw;
        if (amount == 0) continue;
        (byPerson[personOf(low == own ? high : low)] ??= []).add((id, amount));
      }
    }
    return SharedPairIndex._(byPerson, friendOf, names);
  }

  /// The lines for the friend of [friendContextId]: one per group you share
  /// with a balance, and one for expenses outside groups worth [directNet]
  /// (the friend context's own balance, from the same source as the screen).
  /// Empty when there is nothing outside the friend context itself, since a
  /// single line would only repeat the total.
  List<SharedBreakdownLine> linesFor(String friendContextId, int directNet) {
    final person = _friendOf[friendContextId];
    if (person == null) return const [];
    final groups = [
      for (final (contextId, amount)
          in _byPerson[person] ?? const <(String, int)>[])
        if (contextId != friendContextId && _names[contextId]?.$2 == false)
          SharedBreakdownLine(
            contextId: contextId,
            groupName: _names[contextId]!.$1.isEmpty
                ? 'a group'
                : _names[contextId]!.$1,
            amount: Money.fromPaise(amount.abs()),
            owedToYou: amount > 0,
          ),
    ];
    if (groups.isEmpty) return const [];
    return [
      if (directNet != 0)
        SharedBreakdownLine(
          contextId: friendContextId,
          amount: Money.fromPaise(directNet.abs()),
          owedToYou: directNet > 0,
        ),
      ...groups,
    ];
  }
}

/// A friend's balance when [lines] cover more than one place: the total of the
/// lines, with both directions kept.
SharedBalanceSummary sharedSummaryOfLines(
  List<SharedBreakdownLine> lines,
  SharedBalanceSummary fallback,
) {
  if (lines.isEmpty) return fallback;
  var owed = 0, owing = 0;
  for (final line in lines) {
    if (line.owedToYou) {
      owed += line.amount.paise;
    } else {
      owing += line.amount.paise;
    }
  }
  return SharedBalanceSummary(
    owedToYou: Money.fromPaise(owed),
    youOwe: Money.fromPaise(owing),
    netBalance: Money.fromPaise(owed - owing),
    confidence: fallback.confidence,
    incomplete: fallback.incomplete,
  );
}
