/// Learns a credit card's billing day and due day from its bill history.
///
/// A card repeats the same story every month: a bill is generated on one day,
/// reminders follow, and the money is due on another day. One month can be a
/// fluke (a late reminder, a weekend shift), so a day is trusted only when the
/// cycles agree, or when an issuer printed the statement date outright.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

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

/// What the bill history of each card agrees on, by card id. A bill message
/// that was read as evidence for two cards (the same source on both) proves
/// nothing about either, so those bills are left out of the reading.
Map<String, LearnedCardDays> learnedDaysByCard(
  Map<String, CardBillLedger> ledgers,
) {
  final owners = <String, Set<String>>{};
  ledgers.forEach((cardId, ledger) {
    for (final b in ledger.history) {
      for (final key in b.sourceIds) {
        owners.putIfAbsent(key, () => {}).add(cardId);
      }
    }
  });
  bool shared(CardBill b) =>
      b.sourceIds.any((key) => (owners[key]?.length ?? 0) > 1);
  final out = <String, LearnedCardDays>{};
  ledgers.forEach((cardId, ledger) {
    final learned = learnCardDays([
      for (final b in ledger.history)
        if (!shared(b)) b,
    ]);
    if (!learned.isEmpty) out[cardId] = learned;
  });
  return out;
}

/// The cards as the app should show them: each day comes from the person
/// first, then from the card's own bill history, and from a day stored on the
/// card by an older version only when it is not suspect.
///
/// A day typed by the person is never touched. A day an older version read from
/// SMS is dropped when another active card holds the same billing and due day:
/// one bank sender (a card app, an issuer-wide reminder) used to teach every
/// card of that bank the same dates, and one message cannot be two cards' own
/// cycle. The card row itself is not changed, so a refresh from the server
/// cannot bring the wrong days back, and a day the card's own bills teach is
/// kept even when another card happens to share it.
List<UserCard> cardsWithTrustedDays(
  List<UserCard> cards,
  Map<String, LearnedCardDays> learned,
) {
  String key(UserCard c) => '${c.statementDay}|${c.dueDay}';
  final active = cards.where((c) => !c.isArchived).toList();
  final holders = <String, int>{};
  for (final c in active) {
    if (c.statementDay == null && c.dueDay == null) continue;
    holders[key(c)] = (holders[key(c)] ?? 0) + 1;
  }
  return [
    for (final c in cards)
      () {
        if (c.isArchived) return c;
        final mine = learned[c.id];
        final suspect = (holders[key(c)] ?? 0) > 1;
        int? pick(int? stored, String? source, int? own) {
          if (source == 'user') return stored;
          if (own != null) return own;
          return suspect ? null : stored;
        }

        final s = pick(
          c.statementDay,
          c.statementDaySource,
          mine?.statementDay,
        );
        final d = pick(c.dueDay, c.dueDaySource, mine?.dueDay);
        if (s == c.statementDay && d == c.dueDay) return c;
        return UserCard.fromJson({
          ...c.toJson(),
          'statement_day': s,
          'due_day': d,
        });
      }(),
  ];
}

/// The days each card's own bills taught, kept apart from the card row (which
/// the server owns and rewrites on every refresh). Saved in the same small
/// table SMS v2 keeps its other state in.
class LearnedCardDaysStore {
  LearnedCardDaysStore(this._db, {required this.namespace});

  final Database _db;
  final String namespace;
  static const _prefix = 'card-days:';

  Map<String, LearnedCardDays> all() {
    try {
      final rows = _db.select(
        'SELECT key, value FROM v2_sync_state WHERE namespace=? AND key LIKE ?',
        [namespace, '$_prefix%'],
      );
      final out = <String, LearnedCardDays>{};
      for (final r in rows) {
        try {
          final j = jsonDecode(r['value'] as String) as Map<String, dynamic>;
          out[(r['key'] as String).substring(_prefix.length)] = LearnedCardDays(
            statementDay: (j['s'] as num?)?.toInt(),
            dueDay: (j['d'] as num?)?.toInt(),
          );
        } on Object {
          continue; // one damaged row never hides the others
        }
      }
      return out;
    } on Object {
      return const {}; // the table does not exist before the first capture
    }
  }

  /// Saves [days] for each card, drops cards that no longer teach anything, and
  /// says whether anything changed.
  bool replace(Map<String, LearnedCardDays> days) {
    final before = all();
    var changed = false;
    for (final e in days.entries) {
      final old = before[e.key];
      if (old?.statementDay == e.value.statementDay &&
          old?.dueDay == e.value.dueDay) {
        continue;
      }
      _db.execute(
        'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?) '
        'ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value',
        [
          namespace,
          '$_prefix${e.key}',
          jsonEncode({'s': e.value.statementDay, 'd': e.value.dueDay}),
        ],
      );
      changed = true;
    }
    for (final id in before.keys) {
      if (days.containsKey(id)) continue;
      _db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [
        namespace,
        '$_prefix$id',
      ]);
      changed = true;
    }
    return changed;
  }
}
