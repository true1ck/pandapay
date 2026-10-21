import 'package:pandapay_domain/pandapay_domain.dart';

import 'user_cards_repository.dart';
import 'local/financial_store.dart' show familyNamesCardDisplayName;

/// Evidence line an SMS bill message contributes to one card's ledger.
/// Field-level, not message-level: a reminder can arrive with a subset
/// ("Minimum due ₹X · due 02 Nov") and combined evidence must still
/// describe the full bill.
class CardBillEvidence {
  final String? cardLast4;

  /// Issuer/vendor family of the sending bank, e.g. `MYTNEU` for the HDFC
  /// Tata Neu card whose bill SMS never quotes any card digits.
  final String? family;

  /// Generate/statement date ("statement generated on 18 Oct") when the
  /// message states one, else the SMS receive date as the cycle anchor.
  final DateTime statementDate;

  /// True when the message explicitly stated the generated/statement date.
  /// A received-date anchor is approximate and defers to explicit ones.
  final bool statementDateExplicit;
  final DateTime? dueDate;
  final Money? amountDue;
  final Money? minimumDue;
  final double confidence;

  const CardBillEvidence({
    required this.cardLast4,
    required this.statementDate,
    required this.statementDateExplicit,
    required this.dueDate,
    required this.amountDue,
    required this.minimumDue,
    required this.confidence,
    this.family,
  });
}

/// One statement cycle's bill state for a card.
class CardBill {
  /// Payment of the full outstanding balance often differs from the printed
  /// total by interest lines or round-figure habits; anything at or above
  /// the printed amount settles the bill.
  static const _minimumCreditPaise = 100;

  final DateTime statementDate;
  final DateTime? dueDate;
  final Money? amountDue;
  final Money? minimumDue;
  final Money paidToward;
  final DateTime? lastPaymentAt;
  final double confidence;

  /// True when any bill SMS in this cycle explicitly stated the generated /
  /// statement date. A received-date anchor is an approximation, and a due
  /// date collected from a mere reminder SMS must not claim a payments-due
  /// row on its own.
  final bool statementDateVerified;

  const CardBill({
    required this.statementDate,
    required this.dueDate,
    required this.amountDue,
    required this.minimumDue,
    required this.paidToward,
    required this.lastPaymentAt,
    required this.confidence,
    this.statementDateVerified = false,
  });

  Money? get outstanding {
    final due = amountDue;
    if (due == null) return null;
    final remaining = due - paidToward;
    return remaining.isNegative ? const Money.zero() : remaining;
  }

  bool get isPaid {
    final due = amountDue;
    return due != null &&
        due.paise > 0 &&
        paidToward.paise >= due.paise - _minimumCreditPaise;
  }

  bool get hasPayments => paidToward.paise > 0;

  /// A bill stays "current" until one full cycle past its due date so a
  /// freshly paid bill still shows "Paid" instead of vanishing when the
  /// issuer moves to the next cycle.
  bool isCurrentAsOf(DateTime now) {
    final due = _day(dueDate ?? statementDate);
    return now.isBefore(DateTime(due.year, due.month, due.day + 31));
  }
}

/// Per-card bill ledger: newest bill plus the previous cycle, which is where
/// payments made just before the current bill generated actually belong.
class CardBillLedger {
  final CardBill? current;
  final CardBill? previous;

  const CardBillLedger({this.current, this.previous});
}

/// Payment-shaped transaction detection: the server's canonical merchant
/// name ("Credit card bill payment"), issuer and payment-app shorthands
/// ("CC PMT", "Card bill pay"), and user-typed notes — whether the money
/// verb or the card word comes first ("Paid to Axis card ending 8080").
final RegExp _billPaymentVerb = RegExp(
  r'\b(?:payment|pymt|pmt|\s*pay|paid)\b',
  caseSensitive: false,
);
final RegExp _cardWord = RegExp(
  r'\b(?:credit|debit)?\s*card\b|\bcc\b',
  caseSensitive: false,
);

bool isCardBillPaymentTxn(TransactionEntry txn) {
  if (txn.status != 'active' || txn.entryKind != TxnEntryKind.transfer) {
    return false;
  }
  final merchant = txn.merchantName ?? '';
  final note = txn.note ?? '';
  final hasVerb =
      _billPaymentVerb.hasMatch(merchant) || _billPaymentVerb.hasMatch(note);
  final hasCard = _cardWord.hasMatch(merchant) || _cardWord.hasMatch(note);
  return hasVerb && hasCard;
}

/// Reduces bill evidence + payment transactions into per-card ledgers.
///
/// Attribution order (what the money depends on):
/// 1. Explicit identity: the payment carries the card's last4 directly, or
///    its text names an owned card's last4.
/// 2. Window inference: the payment falls in exactly one card's open bill
///    window. Two open windows and no signal → NOT attributed; a wrong
///    guess would mark a real bill as paid.
/// 3. Amount triangulation: all leftovers together match exactly one card's
///    single unpaid bill within rounding headroom.
Map<String, CardBillLedger> deriveCardBills({
  required List<UserCard> cards,
  required List<CardBillEvidence> evidence,
  required List<TransactionEntry> payments,
  required DateTime now,
}) {
  final ledgers = <String, CardBillLedger>{};
  for (final card in cards) {
    final own = evidence
        .where((e) => e.cardLast4 != null && e.cardLast4 == card.last4)
        .toList();
    if (own.isNotEmpty) {
      final cycles = _mergeCycles(own, now: now);
      if (cycles.isNotEmpty) {
        ledgers[card.id] = CardBillLedger(
          current: cycles.first,
          previous: cycles.length > 1 ? cycles[1] : null,
        );
      }
    }
  }

  // Some issuer bill SMS never quote card digits (e.g. YY-MYTNEU-S for the
  // HDFC Tata Neu card). They carry a sender family instead; attach when
  // that family names exactly one registered card via its display name.
  // Merge into the card's own last4 evidence rather than only filling
  // gaps: HDFC statements arrive without amount or due date, and without
  // merging the family-named bill (which carries both) the row would show
  // a statement with nothing owed.
  for (final card in cards) {
    final familyRows = evidence
        .where(
          (e) =>
              e.cardLast4 == null &&
              _familyNamesCard(e.family, card),
        )
        .toList();
    if (familyRows.isEmpty) continue;
    final others = cards
        .where((other) => other.id != card.id)
        .any((other) => _familyNamesCard(familyRows.first.family, other));
    if (others) continue;
    final own = evidence
        .where((e) => e.cardLast4 != null && e.cardLast4 == card.last4)
        .toList();
    final cycles = _mergeCycles([...own, ...familyRows], now: now);
    if (cycles.isEmpty) continue;
    ledgers[card.id] = CardBillLedger(
      current: cycles.first,
      previous: cycles.length > 1 ? cycles[1] : null,
    );
  }

  final attributed = <String, List<TransactionEntry>>{};
  final residual = <TransactionEntry>[];
  for (final txn in payments.where(isCardBillPaymentTxn)) {
    final card = _explicitCard(cards, txn);
    if (card != null) {
      attributed.putIfAbsent(card.id, () => []).add(txn);
      continue;
    }
    final byWindow = [
      for (final card in cards)
        if (ledgers[card.id] != null &&
            [ledgers[card.id]!.current, ledgers[card.id]!.previous]
                .whereType<CardBill>()
                .any((b) => _windowCovers(b, txn.occurredAt)))
          card,
    ];
    if (byWindow.length == 1) {
      attributed.putIfAbsent(byWindow.single.id, () => []).add(txn);
      continue;
    }
    residual.add(txn);
  }

  if (residual.isNotEmpty) {
    final byAmount = <UserCard, CardBill>{};
    final total = residual.fold(const Money.zero(), (sum, t) => sum + t.amount);
    for (final card in cards) {
      final candidates = [
        ledgers[card.id]?.current,
        ledgers[card.id]?.previous,
      ].whereType<CardBill>().where((b) => !b.isPaid).toList();
      if (candidates.length == 1 && _fits(candidates.single, total)) {
        byAmount[card] = candidates.single;
      }
    }
    if (byAmount.length == 1) {
      attributed
          .putIfAbsent(byAmount.keys.single.id, () => [])
          .addAll(residual);
    }
  }

  attributed.forEach((cardId, txns) {
    final ledger = ledgers[cardId];
    if (ledger == null) return;
    ledgers[cardId] = _attached(ledger, txns);
  });
  return ledgers;
}

UserCard? _explicitCard(List<UserCard> cards, TransactionEntry txn) {
  final last4 = txn.cardLast4;
  if (last4 != null) {
    return cards.firstWhereOrNull((c) => c.last4 == last4);
  }
  final text = '${txn.merchantName ?? ''} ${txn.note ?? ''}';
  final mentioned = RegExp(
    r'(?:ending|x{2,6}\*?|no\.?|number)\s*[:#. ]?\s?(\d{4})',
    caseSensitive: false,
  ).firstMatch(text)?.group(1);
  if (mentioned != null) {
    final hits = cards.where((c) => c.last4 == mentioned).toList();
    return hits.length == 1 ? hits.single : null;
  }
  if (txn.userCardId != null) {
    return cards.firstWhereOrNull((c) => c.id == txn.userCardId);
  }
  return null;
}

bool _windowCovers(CardBill bill, DateTime when) {
  final start = _day(bill.statementDate);
  final due = _day(bill.dueDate ?? bill.statementDate);
  return !when.isBefore(start) &&
      when.isBefore(DateTime(due.year, due.month, due.day + 31));
}

bool _fits(CardBill bill, Money amount) {
  final due = bill.amountDue;
  if (due == null) return false;
  final headroom = (due.paise * 0.02).ceil() + 100;
  return amount.paise >= due.paise - headroom &&
      amount.paise <= due.paise + headroom;
}

/// Could this amount be a meaningful payment toward [bill] — full amount,
/// or a partial chunk such as the minimum due?
bool _fitsOrPartial(CardBill bill, Money amount) {
  final due = bill.amountDue;
  if (due == null) return false;
  final headroom = (due.paise * 0.02).ceil() + 100;
  if (amount.paise > due.paise + headroom) return false;
  final floor = bill.minimumDue ?? Money.fromPaise(due.paise ~/ 10);
  final slack = (floor.paise * 0.05).ceil();
  return amount.paise >= floor.paise - slack;
}

/// Bill payments settle the newest bill that existed when they were made:
/// after the current bill generated → current; before it → the previous
/// cycle, which is what the user was paying. With no previous cycle captured
/// a pre-current payment is deliberately NOT counted against the current
/// bill — it would mark a real bill paid with last cycle's payment.
CardBillLedger _attached(CardBillLedger ledger, List<TransactionEntry> txns) {
  CardBill settle(CardBill bill, Iterable<TransactionEntry> txns) {
    final paid = txns.fold(const Money.zero(), (sum, t) => sum + t.amount);
    final lastAt = txns.map((t) => t.occurredAt).reduce(
          (a, b) => a.isAfter(b) ? a : b,
        );
    return CardBill(
      statementDate: bill.statementDate,
      dueDate: bill.dueDate,
      amountDue: bill.amountDue,
      minimumDue: bill.minimumDue,
      paidToward: bill.paidToward + paid,
      lastPaymentAt: bill.lastPaymentAt == null || lastAt.isAfter(bill.lastPaymentAt!)
          ? lastAt
          : bill.lastPaymentAt,
      confidence: bill.confidence,
    );
  }

  final currentPayments = <TransactionEntry>[];
  final previousPayments = <TransactionEntry>[];
  for (final txn in txns) {
    final beforeCurrent = ledger.current != null &&
        txn.occurredAt.isBefore(ledger.current!.statementDate);
    final fitsPrevious = ledger.previous != null &&
        !ledger.previous!.isPaid &&
        _fitsOrPartial(ledger.previous!, txn.amount);
    final fitsCurrent = ledger.current != null &&
        !ledger.current!.isPaid &&
        _fitsOrPartial(ledger.current!, txn.amount);
    final preferPrevious = !fitsCurrent ||
        (ledger.previous != null &&
            ledger.current != null &&
            ledger.previous!.amountDue != null &&
            ledger.current!.amountDue != null &&
            ((txn.amount - ledger.previous!.amountDue!).paise).abs() <
                ((txn.amount - ledger.current!.amountDue!).paise).abs());
    if (beforeCurrent || (fitsPrevious && (ledger.current == null || preferPrevious))) {
      previousPayments.add(txn);
    } else {
      currentPayments.add(txn);
    }
  }

  final current = ledger.current == null || currentPayments.isEmpty
      ? ledger.current
      : settle(ledger.current!, currentPayments);
  final previous = ledger.previous == null || previousPayments.isEmpty
      ? ledger.previous
      : settle(ledger.previous!, previousPayments);
  return CardBillLedger(current: current, previous: previous);
}

List<CardBill> _mergeCycles(List<CardBillEvidence> rows, {required DateTime now}) {
  final ordered = [...rows]
    ..sort((a, b) => b.statementDate.compareTo(a.statementDate));
  ordered.retainWhere(
    (e) => !e.statementDate.isAfter(now) && _day(now).difference(e.statementDate) <= const Duration(days: 95),
  );
  if (ordered.isEmpty) return const [];
  final cycles = <List<CardBillEvidence>>[[ordered.first]];
  for (final row in ordered.skip(1)) {
    final inCycle = cycles.last.any(
      (r) => r.statementDate.difference(row.statementDate).abs() <=
          const Duration(days: 7),
    );
    if (inCycle) {
      cycles.last.add(row);
    } else if (cycles.length == 1) {
      cycles.add([row]);
    }
  }
  return cycles.take(2).map(_mergeOne).toList();
}

CardBill _mergeOne(List<CardBillEvidence> cycle) {
  final ordered = [...cycle]
    ..sort((a, b) => b.statementDate.compareTo(a.statementDate));
  final anchor =
      ordered.firstWhere((e) => e.statementDateExplicit, orElse: () => ordered.first).statementDate;
  DateTime? due;
  for (final e in ordered) {
    if (e.dueDate != null && !e.dueDate!.isBefore(anchor)) {
      due = e.dueDate;
      break;
    }
  }
  Money? amount;
  for (final e in ordered) {
    if (e.amountDue != null &&
        (amount == null || e.amountDue!.paise > amount.paise)) {
      amount = e.amountDue;
    }
  }
  Money? minimum;
  for (final e in ordered) {
    minimum ??= e.minimumDue;
  }
  final confidence =
      cycle.fold<double>(0, (best, e) => best > e.confidence ? best : e.confidence);
  return CardBill(
    statementDate: anchor,
    dueDate: due,
    amountDue: amount,
    minimumDue: minimum,
    paidToward: const Money.zero(),
    lastPaymentAt: null,
    confidence: confidence,
    statementDateVerified: cycle.any((e) => e.statementDateExplicit),
  );
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

bool _familyNamesCard(String? family, UserCard card) =>
    familyNamesCardDisplayName(family, '${card.nickname ?? ''} ${card.cardName}');

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}

