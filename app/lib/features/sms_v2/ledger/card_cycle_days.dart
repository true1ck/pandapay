/// Learns a credit card's billing day and due day from its bill history.
///
/// A card repeats the same story every month: a bill is generated on one day,
/// reminders follow, and the money is due on another day. One month can be a
/// fluke (a late reminder, a weekend shift), so a day is trusted only when the
/// cycles agree, or when an issuer printed the statement date outright.
library;

import '../../../data/card_bill_ledger.dart';
import '../../../data/user_cards_repository.dart';

/// How many of the newest cycles are read.
const int kCycleDaysWindow = 6;

/// Days of slack when cycles are compared (a due date that slides over a
/// weekend, a reminder that arrives a day after the statement).
const int _slack = 1;

class LearnedCardDays {
  const LearnedCardDays({this.statementDay, this.dueDay});

  final int? statementDay;
  final int? dueDay;

  bool get isEmpty => statementDay == null && dueDay == null;
}

/// The most supported day of [days] (newest first): the day that most others
/// sit within [_slack] days of, needing at least [need] supporters. Ties go to
/// the day seen most often, then to the newest cycle. Null when no day has enough support.
int? _agreedDay(List<int> days, {required int need}) {
  int? best;
  var bestSupport = 0;
  var bestExact = 0;
  for (final d in days) {
    final support = days.where((x) => (x - d).abs() <= _slack).length;
    final exact = days.where((x) => x == d).length;
    if (support > bestSupport ||
        (support == bestSupport && exact > bestExact)) {
      best = d;
      bestSupport = support;
      bestExact = exact;
    }
  }
  return bestSupport >= need ? best : null;
}

/// The billing day and due day [history] (newest cycle first) agrees on.
///
/// * Billing day: printed statement dates count on their own; otherwise the
///   day each cycle's first message arrived must repeat in two cycles.
/// * Due day: must repeat in two cycles, or come from a cycle whose statement
///   date was printed (a lone reminder is not enough to claim a day).
LearnedCardDays learnCardDays(List<CardBill> history) {
  final cycles = history.take(kCycleDaysWindow).toList();
  if (cycles.isEmpty) return const LearnedCardDays();

  final printed = [
    for (final b in cycles)
      if (b.statementDateExplicit) b.statementDate.day,
  ];
  final statementDay = printed.isNotEmpty
      ? _agreedDay(printed, need: 1)
      : _agreedDay([for (final b in cycles) b.statementDate.day], need: 2);

  final dues = [
    for (final b in cycles)
      if (b.dueDate != null) b.dueDate!.day,
  ];
  var dueDay = _agreedDay(dues, need: 2);
  if (dueDay == null && dues.isNotEmpty) {
    final newest = cycles.firstWhere((b) => b.dueDate != null);
    if (newest.statementDateExplicit) dueDay = newest.dueDate!.day;
  }
  return LearnedCardDays(statementDay: statementDay, dueDay: dueDay);
}

/// Card-row edits that save what the ledgers learned. A day the person typed
/// is never touched; a day learned earlier from SMS follows newer evidence; a
/// day of unknown origin is left alone. Keys match the stored card row.
Map<String, Map<String, dynamic>> cardDayPatches(
  Iterable<UserCard> cards,
  Map<String, CardBillLedger> ledgers,
) {
  final out = <String, Map<String, dynamic>>{};
  for (final card in cards) {
    final ledger = ledgers[card.id];
    if (ledger == null || card.isArchived) continue;
    final learned = learnCardDays(ledger.history);
    final patch = <String, dynamic>{};
    bool mayWrite(int? current, String? source) =>
        source != 'user' && (current == null || source == 'sms');
    final s = learned.statementDay;
    if (s != null &&
        s != card.statementDay &&
        mayWrite(card.statementDay, card.statementDaySource)) {
      patch['statement_day'] = s;
      patch['statement_day_source'] = 'sms';
    }
    final d = learned.dueDay;
    if (d != null &&
        d != card.dueDay &&
        mayWrite(card.dueDay, card.dueDaySource)) {
      patch['due_day'] = d;
      patch['due_day_source'] = 'sms';
    }
    if (patch.isNotEmpty) out[card.id] = patch;
  }
  return out;
}
