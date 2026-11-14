import 'package:pandapay_domain/pandapay_domain.dart' show Money;

/// One person in an expense: what they put in and what their share is.
class SharedPersonLine {
  const SharedPersonLine({
    required this.name,
    required this.isYou,
    required this.paidMinor,
    required this.shareMinor,
  });
  final String name;
  final bool isYou;
  final int paidMinor;
  final int shareMinor;

  /// Positive: they are owed this much. Negative: they owe this much.
  int get netMinor => paidMinor - shareMinor;
}

enum SharedYourPosition { owes, owed, even, notIn }

/// The plain-words reading of an expense: who paid, who owes, and what that
/// means for the person looking. Built from the accepted snapshot's payer
/// contributions and shares, never from anything the screen has to work out.
class SharedExpenseSummary {
  SharedExpenseSummary._({
    required this.people,
    required this.totalMinor,
    required this.position,
    required this.yourAmountMinor,
    required this.counterpartName,
    required this.splitEqually,
  });

  /// You first, then everyone else in name order.
  final List<SharedPersonLine> people;

  /// What was shared in total.
  final int totalMinor;
  final SharedYourPosition position;

  /// How much you owe or are owed (always positive); 0 when even or not in it.
  final int yourAmountMinor;

  /// The one person you owe or are owed by; null when there are several.
  final String? counterpartName;
  final bool splitEqually;

  static int _minor(Object? v) =>
      v is String ? (int.tryParse(v) ?? 0) : (v is int ? v : 0);

  /// [snapshot] is the accepted snapshot (`contributions` and `shares` lists of
  /// `{memberId, amountMinor}`), [names] maps member ids to display names and
  /// [ownMemberId] is the viewer.
  static SharedExpenseSummary? from(
    Map<Object?, Object?>? snapshot,
    Map<Object?, Object?> names,
    String? ownMemberId,
  ) {
    if (snapshot == null) return null;
    final contributions = snapshot['contributions'];
    final shares = snapshot['shares'];
    if (contributions is! List || shares is! List) return null;
    final paid = <String, int>{}, share = <String, int>{};
    for (final c in contributions) {
      if (c is Map && c['memberId'] is String) {
        paid[c['memberId'] as String] =
            (paid[c['memberId']] ?? 0) + _minor(c['amountMinor']);
      }
    }
    for (final s in shares) {
      if (s is Map && s['memberId'] is String) {
        share[s['memberId'] as String] =
            (share[s['memberId']] ?? 0) + _minor(s['amountMinor']);
      }
    }
    final ids = {...paid.keys, ...share.keys};
    String nameOf(String id) =>
        id == ownMemberId ? 'You' : (names[id] as String?) ?? 'Former member';
    final people =
        [
          for (final id in ids)
            if ((paid[id] ?? 0) != 0 || (share[id] ?? 0) != 0)
              SharedPersonLine(
                name: nameOf(id),
                isYou: id == ownMemberId,
                paidMinor: paid[id] ?? 0,
                shareMinor: share[id] ?? 0,
              ),
        ]..sort((a, b) {
          if (a.isYou != b.isYou) return a.isYou ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    final total = share.values.fold<int>(0, (s, v) => s + v);
    final shareValues = share.values.where((v) => v > 0).toList();
    final equal =
        shareValues.length > 1 &&
        shareValues.reduce((a, b) => a > b ? a : b) -
                shareValues.reduce((a, b) => a < b ? a : b) <=
            1;
    final you = people.where((p) => p.isYou).firstOrNull;
    final others = people.where((p) => !p.isYou).toList();
    SharedYourPosition position;
    var amount = 0;
    String? counterpart;
    if (you == null) {
      position = SharedYourPosition.notIn;
    } else if (you.netMinor < 0) {
      position = SharedYourPosition.owes;
      amount = -you.netMinor;
      final creditors = others.where((p) => p.netMinor > 0).toList();
      if (creditors.length == 1) counterpart = creditors.single.name;
    } else if (you.netMinor > 0) {
      position = SharedYourPosition.owed;
      amount = you.netMinor;
      final debtors = others.where((p) => p.netMinor < 0).toList();
      if (debtors.length == 1) counterpart = debtors.single.name;
    } else {
      position = SharedYourPosition.even;
    }
    return SharedExpenseSummary._(
      people: people,
      totalMinor: total,
      position: position,
      yourAmountMinor: amount,
      counterpartName: counterpart,
      splitEqually: equal,
    );
  }

  String _money(int minor) => Money.fromPaise(minor).format();

  /// "Ravi paid ₹1,000.00" or "2 people paid ₹1,000.00".
  String get paidSentence {
    final payers = people.where((p) => p.paidMinor > 0).toList();
    if (payers.isEmpty) return 'Nobody paid';
    if (payers.length == 1) {
      final p = payers.single;
      return '${p.isYou ? 'You' : p.name} paid ${_money(p.paidMinor)}';
    }
    return '${payers.length} people paid ${_money(payers.fold<int>(0, (s, p) => s + p.paidMinor))}';
  }

  /// "split equally" or "split unequally".
  String get splitWords => splitEqually ? 'split equally' : 'split unequally';

  /// What this means for you, in one sentence.
  String get yourSentence => switch (position) {
    SharedYourPosition.owes =>
      counterpartName == null
          ? 'You owe ${_money(yourAmountMinor)}'
          : 'You owe $counterpartName ${_money(yourAmountMinor)}',
    SharedYourPosition.owed =>
      counterpartName == null
          ? 'You get back ${_money(yourAmountMinor)}'
          : '$counterpartName owes you ${_money(yourAmountMinor)}',
    SharedYourPosition.even => 'You paid your own share',
    SharedYourPosition.notIn => "You're not part of this expense",
  };
}
