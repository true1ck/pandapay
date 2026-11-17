import 'package:pandapay_domain/pandapay_domain.dart' show Money;

import '../storage/shared_store.dart';
import '../ui/shared_presentation.dart';
import 'shared_local_reads.dart';
import 'shared_pending_balances.dart';

/// Rows for people who are in your groups but not in your friends list start
/// with this, then the id of one of their groups, then their key. Opening one
/// opens that group.
const sharedGroupPersonPrefix = 'person:';

/// The group a [sharedGroupPersonPrefix] row opens, or null for any other id.
String? sharedGroupOfPersonRow(String id) {
  if (!id.startsWith(sharedGroupPersonPrefix)) return null;
  final parts = id.substring(sharedGroupPersonPrefix.length).split(':');
  return parts.first.isEmpty ? null : parts.first;
}

/// Someone who is in one of your groups but is not one of your friends: added
/// to a group by name (or joined through its link), never added as a friend.
class SharedGroupPerson {
  const SharedGroupPerson({
    required this.key,
    required this.name,
    required this.groups,
  });

  /// The person, as the index tells people apart.
  final String key;
  final String name;

  /// The groups they are in, as (context id, group name).
  final List<(String, String)> groups;
}

const _gone = {'left', 'erased', 'removed', 'declined'};

/// A name for comparing: case, spacing and stray punctuation ignored.
String _norm(Object? raw) =>
    '${raw ?? ''}'.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

class _Ctx {
  _Ctx(this.id, this.name, this.direct, this.members, this.own);
  final String id;
  final String name;
  final bool direct;
  final List<Map<String, Object?>> members;
  final String own;
}

/// What you and each person owe each other in every friend and group context,
/// read from this phone's own copy of Splits (the pair balances it already
/// keeps for every context). Lets a friend be shown the Splitwise way: one
/// total, then a line per group and one for expenses outside any group.
///
/// Bounded like the screens: the first 100 contexts and the first 100 pair
/// balances in each.
///
/// Who is who. People are matched across contexts by their account. Someone
/// added to a group by typing a name has no account in that group yet, so that
/// name stands for the friend of the same name (when exactly one friend has
/// it): "Sujay" typed into a group is your friend Sujay. Two people with the
/// same name and no account in different groups are taken as one person too,
/// since the app already asks for names to be unique.
///
/// Waiting expenses (saved here, not yet confirmed) are counted straight away
/// through [pending], so a balance moves when the expense is saved.
class SharedPairIndex {
  SharedPairIndex._(
    this._stored,
    this._pending,
    this._friendOf,
    this._names,
    this.groupPeople,
    this._overview,
  );

  /// person key -> context id -> amount in minor units (positive = they owe
  /// you), as stored on this phone.
  final Map<String, Map<String, int>> _stored;

  /// The same, for what waiting expenses will add.
  final Map<String, Map<String, int>> _pending;

  /// friend context id -> person key.
  final Map<String, String> _friendOf;

  /// context id -> (name, is a friend context).
  final Map<String, (String, bool)> _names;

  /// People in your groups who are not your friends, in the order their first
  /// group is listed.
  final List<SharedGroupPerson> groupPeople;

  final ({int owed, int owing}) _overview;

  static SharedPairIndex read(
    SharedExpensesStore store,
    String accountId, {
    SharedPendingBalances? pending,
  }) {
    final reads = SharedLocalReads(store, accountId);
    final overlay = pending ?? SharedPendingBalances.read(store, accountId);
    final contexts = <_Ctx>[];
    final names = <String, (String, bool)>{};
    for (final context in store.readContexts(limit: 100).items) {
      final payload = context.payload;
      if (payload['state'] == 'archived') continue;
      final id = context.id;
      final direct = payload['kind'] == 'direct';
      final name = '${payload['name'] ?? ''}'.trim();
      names[id] = (name, direct);
      final members = reads.memberRows(id);
      final own = members
          .where((m) => m['profileId'] == accountId && m['state'] == 'active')
          .map((m) => m['memberId'])
          .firstOrNull;
      if (own is! String) continue;
      contexts.add(_Ctx(id, name, direct, members, own));
    }

    // Your friends: who each friend context is with, and by which names.
    final friendOf = <String, String>{};
    final friendsByName = <String, Set<String>>{};
    for (final c in contexts.where((c) => c.direct)) {
      final other = c.members
          .where((m) => m['memberId'] != c.own && m['state'] != 'removed')
          .firstOrNull;
      if (other == null) continue;
      final profile = other['profileId'];
      final key = profile is String ? profile : 'ctx:${c.id}';
      friendOf[c.id] = key;
      final label = _norm(other['displayName'] ?? c.name);
      if (label.isNotEmpty) (friendsByName[label] ??= {}).add(key);
    }

    String personOf(_Ctx c, Object? memberId) {
      final m = c.members.where((m) => m['memberId'] == memberId).firstOrNull;
      final profile = m?['profileId'];
      if (profile is String) return profile;
      final label = _norm(m?['displayName']);
      if (label.isNotEmpty) {
        final hit = friendsByName[label];
        if (hit != null && hit.length == 1) return hit.first;
        if (!c.direct) return 'name:$label';
      }
      return c.direct ? 'ctx:${c.id}' : 'ctx:${c.id}:$memberId';
    }

    final stored = <String, Map<String, int>>{};
    final byMember = <String, Map<String, int>>{};
    for (final c in contexts) {
      for (final row
          in store
              .readPage(entity: 'balances', contextId: c.id, limit: 100)
              .items) {
        final b = row.payload;
        final low = b['lowMemberId'], high = b['highMemberId'];
        if (low != c.own && high != c.own) continue;
        final raw = int.tryParse('${b['balanceMinor']}') ?? 0;
        final amount = low == c.own ? raw : -raw;
        if (amount == 0) continue;
        final other = low == c.own ? high : low;
        (byMember[c.id] ??= {})['$other'] = amount;
        final person = stored[personOf(c, other)] ??= {};
        person.update(c.id, (v) => v + amount, ifAbsent: () => amount);
      }
    }

    final waiting = <String, Map<String, int>>{};
    var owedShift = 0, owingShift = 0;
    for (final c in contexts) {
      for (final entry in overlay.inContext(c.id).entries) {
        final person = waiting[personOf(c, entry.key)] ??= {};
        person.update(
          c.id,
          (v) => v + entry.value,
          ifAbsent: () => entry.value,
        );
        final before = byMember[c.id]?[entry.key] ?? 0;
        final after = before + entry.value;
        owedShift += (after > 0 ? after : 0) - (before > 0 ? before : 0);
        owingShift += (after < 0 ? -after : 0) - (before < 0 ? -before : 0);
      }
    }

    // People in your groups who are not your friends.
    final friendKeys = friendOf.values.toSet();
    final people = <String, SharedGroupPerson>{};
    for (final c in contexts.where((c) => !c.direct)) {
      for (final m in c.members) {
        if (m['memberId'] == c.own || _gone.contains(m['state'])) continue;
        final name = '${m['displayName'] ?? ''}'.trim();
        if (name.isEmpty) continue; // nobody to call them by
        final key = personOf(c, m['memberId']);
        if (friendKeys.contains(key)) continue;
        final known = people[key];
        final group = (c.id, c.name.isEmpty ? 'a group' : c.name);
        if (known == null) {
          people[key] = SharedGroupPerson(
            key: key,
            name: name,
            groups: [group],
          );
        } else if (!known.groups.any((g) => g.$1 == c.id)) {
          known.groups.add(group);
        }
      }
    }

    return SharedPairIndex._(
      stored,
      waiting,
      friendOf,
      names,
      people.values.toList(),
      (owed: owedShift, owing: owingShift),
    );
  }

  /// What this phone has stored for the friend context [friendContextId] itself
  /// (positive = they owe you), or null when it holds no balance there.
  int? storedDirect(String friendContextId) {
    final person = _friendOf[friendContextId];
    return person == null ? null : _stored[person]?[friendContextId];
  }

  /// How much more (or less) you are owed in the friend context
  /// [friendContextId] once the waiting expenses are counted; 0 when none.
  int pendingDirect(String friendContextId) {
    final person = _friendOf[friendContextId];
    return person == null ? 0 : _pending[person]?[friendContextId] ?? 0;
  }

  /// What the waiting expenses add to the "you are owed" and "you owe" totals
  /// over everything, so the top line moves too.
  ({int owed, int owing}) get overviewShift => _overview;

  Iterable<SharedBreakdownLine> _groupLines(
    String person,
    String? except,
  ) sync* {
    final contexts = {...?_stored[person]?.keys, ...?_pending[person]?.keys};
    for (final contextId in contexts) {
      if (contextId == except || _names[contextId]?.$2 != false) continue;
      final amount =
          (_stored[person]?[contextId] ?? 0) +
          (_pending[person]?[contextId] ?? 0);
      if (amount == 0) continue;
      final name = _names[contextId]!.$1;
      yield SharedBreakdownLine(
        contextId: contextId,
        groupName: name.isEmpty ? 'a group' : name,
        amount: Money.fromPaise(amount.abs()),
        owedToYou: amount > 0,
      );
    }
  }

  /// The lines for the friend of [friendContextId]: one per group you share
  /// with a balance, and one for expenses outside groups worth [directNet]
  /// (the friend context's own balance, from the same source as the screen,
  /// with [pendingDirect] already counted).
  /// Empty when there is nothing outside the friend context itself, since a
  /// single line would only repeat the total.
  List<SharedBreakdownLine> linesFor(String friendContextId, int directNet) {
    final person = _friendOf[friendContextId];
    if (person == null) return const [];
    final groups = _groupLines(person, friendContextId).toList();
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

  /// The groups where [person] and you owe each other something.
  List<SharedBreakdownLine> linesForPerson(SharedGroupPerson person) =>
      _groupLines(person.key, null).toList();
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
