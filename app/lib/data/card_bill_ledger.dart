import 'package:pandapay_domain/pandapay_domain.dart';

import 'user_cards_repository.dart';
import 'local/financial_store.dart'
    show canonicalBankSender, familyNamesCardDisplayName;

/// Evidence line an SMS bill message contributes to one card's ledger.
/// Field-level, not message-level: a reminder can arrive with a subset
/// ("Minimum due ₹X · due 02 Nov") and combined evidence must still
/// describe the full bill.
class CardBillEvidence {
  final String? sourceId;
  final String? userCardId;
  final String? cardLast4;

  /// Parsed biller identity, kept separate from the transport sender family.
  /// Aggregators such as MYTNEU deliver both HDFC card bills and utilities,
  /// so sender family alone must never make a utility bill card evidence.
  final String? billerName;

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
  final bool isAutopay;

  const CardBillEvidence({
    this.sourceId,
    this.userCardId,
    required this.cardLast4,
    this.billerName,
    required this.statementDate,
    required this.statementDateExplicit,
    required this.dueDate,
    required this.amountDue,
    required this.minimumDue,
    required this.confidence,
    this.family,
    this.isAutopay = false,
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
  final bool isAutopay;
  final List<String> sourceIds;

  /// True when any bill SMS in this cycle explicitly stated the generated /
  /// statement date. A received-date anchor is an approximation, and a due
  /// date collected from a mere reminder SMS must not claim a payments-due
  /// row on its own.
  final bool statementDateVerified;

  /// The issuer explicitly stated this date (or the statement period end).
  /// A received-date anchor and a scheduled AutoPay date are not statement
  /// generation dates, even when they are enough to show a due bill.
  final bool statementDateExplicit;

  const CardBill({
    required this.statementDate,
    required this.dueDate,
    required this.amountDue,
    required this.minimumDue,
    required this.paidToward,
    required this.lastPaymentAt,
    required this.confidence,
    this.statementDateVerified = false,
    this.statementDateExplicit = false,
    this.isAutopay = false,
    this.sourceIds = const [],
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
        paidToward.paise > 0 &&
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
  /// All observed statement cycles, newest first. Older cycles are kept for
  /// the Due Date Calendar; the live due/payment calculation still uses only
  /// [current] and [previous].
  final List<CardBill> history;

  const CardBillLedger({this.current, this.previous, this.history = const []});
}

/// A captured card-bill SMS that needs a card choice, or one whose choice can
/// be edited. The original message remains the source of the suggested data.
class CardBillReviewItem {
  final String id;
  final String sender;
  final String? billerName;
  final String? body;
  final DateTime receivedAt;
  final DateTime? dueDate;
  final DateTime? statementDate;
  final Money? amountDue;
  final String? assignedCardId;

  const CardBillReviewItem({
    required this.id,
    required this.sender,
    required this.billerName,
    required this.body,
    required this.receivedAt,
    required this.dueDate,
    required this.statementDate,
    required this.amountDue,
    required this.assignedCardId,
  });
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
  List<TransactionEntry> transactions = const [],
  required DateTime now,
}) {
  final orphanAttributed = <String, List<CardBillEvidence>>{};
  final orphanRows = evidence
      .where((e) => e.cardLast4 == null && e.userCardId == null)
      .toList();

  for (final orphan in orphanRows) {
    if (_isNamedAggregatorNonCardBill(orphan)) continue;
    final candidates = _candidateCardsForEvidence(orphan, cards);
    if (candidates.isEmpty) continue;

    UserCard? target;
    if (candidates.length == 1) {
      target = candidates.single;
    } else {
      // Only a unique card-specific message in this cycle can attach a
      // suffix-less aggregator bill when several cards share the issuer.
      final cycleMatches = _explicitCardsForCycle(
        orphan,
        candidates,
        cards,
        evidence,
      );
      if (cycleMatches.length == 1) target = cycleMatches.single;
    }

    if (target != null) {
      orphanAttributed.putIfAbsent(target.id, () => []).add(orphan);
    }
  }

  final ledgers = <String, CardBillLedger>{};
  for (final card in cards) {
    final own = evidence
        .where(
          (e) =>
              e.userCardId == card.id ||
              (e.userCardId == null &&
                  e.cardLast4 != null &&
                  e.cardLast4 == card.last4 &&
                  cards.where((c) => c.last4 == e.cardLast4).length == 1),
        )
        .toList();
    final attachedOrphans = orphanAttributed[card.id] ?? const [];
    final combined = [...own, ...attachedOrphans];
    if (combined.isNotEmpty) {
      final cycles = _mergeCycles(combined, now: now);
      final history = _mergeCycles(
        combined,
        now: now,
        maxAge: null,
        maxCycles: null,
      );
      if (cycles.isNotEmpty || history.isNotEmpty) {
        ledgers[card.id] = CardBillLedger(
          current: cycles.firstOrNull,
          previous: cycles.length > 1 ? cycles[1] : null,
          history: history,
        );
      }
    }
  }

  final attributed = <String, List<TransactionEntry>>{};
  final residual = <TransactionEntry>[];
  final seenPayments = <String>{};
  for (final txn in payments.where(isCardBillPaymentTxn)) {
    if (!seenPayments.add(txn.id) ||
        txn.amount.paise <= 0 ||
        txn.occurredAt.isAfter(now)) {
      continue;
    }
    final card = _explicitCard(cards, txn);
    if (card != null) {
      attributed.putIfAbsent(card.id, () => []).add(txn);
      continue;
    }
    // An explicit but unknown/ambiguous card must never fall back to another
    // card merely because its bill window or amount happens to match.
    if (txn.cardLast4 != null ||
        txn.userCardId != null ||
        _mentionedLast4(txn) != null) {
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

/// Finds a unique suffix-identified bill from the same cycle as [orphan].
/// The suffix must identify exactly one saved card. Equal due dates are the
/// strongest cycle link; when either message lacks a due date, statement
/// anchors within seven days may link them. Ambiguous cycles remain unresolved.
List<UserCard> _explicitCardsForCycle(
  CardBillEvidence orphan,
  List<UserCard> candidates,
  List<UserCard> allCards,
  List<CardBillEvidence> evidence,
) {
  final owners = <String, UserCard>{};
  for (final row in evidence) {
    final last4 = row.cardLast4;
    if (last4 == null) continue;
    final matches = allCards.where((card) => card.last4 == last4).toList();
    if (matches.length != 1 ||
        !candidates.any((c) => c.id == matches.single.id)) {
      continue;
    }
    final sameDue =
        orphan.dueDate != null &&
        row.dueDate != null &&
        _day(orphan.dueDate!) == _day(row.dueDate!);
    final closeAnchors =
        (orphan.dueDate == null || row.dueDate == null) &&
        orphan.statementDateExplicit &&
        row.statementDateExplicit &&
        orphan.statementDate.difference(row.statementDate).abs() <=
            const Duration(days: 7);
    if (sameDue || closeAnchors) owners[matches.single.id] = matches.single;
  }
  return owners.values.toList(growable: false);
}

UserCard? _explicitCard(List<UserCard> cards, TransactionEntry txn) {
  final last4 = txn.cardLast4;
  if (last4 != null) {
    final hits = cards.where((c) => c.last4 == last4).toList();
    return hits.length == 1
        ? hits.single
        : hits.firstWhereOrNull((c) => c.id == txn.userCardId);
  }
  final mentioned = _mentionedLast4(txn);
  if (mentioned != null) {
    final hits = cards.where((c) => c.last4 == mentioned).toList();
    return hits.length == 1 ? hits.single : null;
  }
  if (txn.userCardId != null) {
    return cards.firstWhereOrNull((c) => c.id == txn.userCardId);
  }
  return null;
}

String? _mentionedLast4(TransactionEntry txn) => RegExp(
  r'(?:ending|x{2,6}\*?|no\.?|number)\s*[:#. ]?\s?(\d{4})',
  caseSensitive: false,
).firstMatch('${txn.merchantName ?? ''} ${txn.note ?? ''}')?.group(1);

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
    final lastAt = txns
        .map((t) => t.occurredAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    return CardBill(
      statementDate: bill.statementDate,
      dueDate: bill.dueDate,
      amountDue: bill.amountDue,
      minimumDue: bill.minimumDue,
      paidToward: bill.paidToward + paid,
      lastPaymentAt:
          bill.lastPaymentAt == null || lastAt.isAfter(bill.lastPaymentAt!)
          ? lastAt
          : bill.lastPaymentAt,
      confidence: bill.confidence,
      statementDateVerified: bill.statementDateVerified,
      statementDateExplicit: bill.statementDateExplicit,
      isAutopay: bill.isAutopay,
      sourceIds: bill.sourceIds,
    );
  }

  final ordered = [...txns]
    ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
  for (final txn in ordered) {
    final oldest = ledger.previous ?? ledger.current;
    if (oldest == null || txn.occurredAt.isBefore(_day(oldest.statementDate))) {
      continue;
    }
    final beforeCurrent =
        ledger.current != null &&
        txn.occurredAt.isBefore(ledger.current!.statementDate);
    final fitsPrevious =
        ledger.previous != null &&
        !ledger.previous!.isPaid &&
        _fitsOrPartial(ledger.previous!, txn.amount);
    final fitsCurrent =
        ledger.current != null &&
        !ledger.current!.isPaid &&
        _fitsOrPartial(ledger.current!, txn.amount);
    final preferPrevious =
        !fitsCurrent ||
        (ledger.previous != null &&
            ledger.current != null &&
            ledger.previous!.amountDue != null &&
            ledger.current!.amountDue != null &&
            ((txn.amount - ledger.previous!.amountDue!).paise).abs() <
                ((txn.amount - ledger.current!.amountDue!).paise).abs());
    if (beforeCurrent ||
        (fitsPrevious && (ledger.current == null || preferPrevious))) {
      if (ledger.previous != null) {
        ledger = CardBillLedger(
          current: ledger.current,
          previous: settle(ledger.previous!, [txn]),
          history: ledger.history,
        );
      }
    } else if (ledger.current != null) {
      ledger = CardBillLedger(
        current: settle(ledger.current!, [txn]),
        previous: ledger.previous,
          history: ledger.history,
      );
    }
  }
  return ledger;
}

List<CardBill> _mergeCycles(
  List<CardBillEvidence> rows, {
  required DateTime now,
  Duration? maxAge = const Duration(days: 95),
  int? maxCycles = 2,
}) {
  final ordered = [...rows]
    ..sort((a, b) => b.statementDate.compareTo(a.statementDate));
  ordered.retainWhere(
    (e) =>
        !e.statementDate.isAfter(now) &&
        (maxAge == null || _day(now).difference(e.statementDate) <= maxAge),
  );
  if (ordered.isEmpty) return const [];
  final cycles = <List<CardBillEvidence>>[
    [ordered.first],
  ];
  for (final row in ordered.skip(1)) {
    final matchingCycle = cycles.firstWhereOrNull(
      (cycle) => cycle.any(
        (r) =>
            (r.dueDate != null &&
                row.dueDate != null &&
                r.dueDate == row.dueDate) ||
            ((r.dueDate == null || row.dueDate == null) &&
                r.statementDate.difference(row.statementDate).abs() <=
                    const Duration(days: 7)),
      ),
    );
    if (matchingCycle != null) {
      matchingCycle.add(row);
    } else if (maxCycles == null || cycles.length < maxCycles) {
      cycles.add([row]);
    }
  }
  return cycles.map(_mergeOne).toList();
}

CardBill _mergeOne(List<CardBillEvidence> cycle) {
  final ordered = [...cycle]
    ..sort((a, b) => b.statementDate.compareTo(a.statementDate));
  final anchor = ordered
      .firstWhere((e) => e.statementDateExplicit, orElse: () => ordered.first)
      .statementDate;
  DateTime? due;
  for (final e in ordered) {
    if (e.dueDate != null && !e.dueDate!.isBefore(anchor)) {
      due = e.dueDate;
      break;
    }
  }
  due ??= ordered.firstWhereOrNull((e) => e.dueDate != null)?.dueDate;
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
  final confidence = cycle.fold<double>(
    0,
    (best, e) => best > e.confidence ? best : e.confidence,
  );
  return CardBill(
    statementDate: anchor,
    dueDate: due,
    amountDue: amount,
    minimumDue: minimum,
    paidToward: const Money.zero(),
    lastPaymentAt: null,
    confidence: confidence,
    isAutopay: cycle.any((e) => e.isAutopay),
    statementDateVerified: cycle.any(
      (e) => e.statementDateExplicit || e.isAutopay,
    ),
    statementDateExplicit: cycle.any((e) => e.statementDateExplicit),
    sourceIds: cycle.map((e) => e.sourceId).whereType<String>().toSet().toList(),
  );
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

bool _familyNamesCard(String? family, UserCard card) =>
    familyNamesCardDisplayName(
      family,
      '${card.nickname ?? ''} ${card.cardName}',
    );

bool _isNamedAggregatorNonCardBill(CardBillEvidence evidence) {
  final family = evidence.family;
  final billerName = evidence.billerName?.trim().toLowerCase();
  if (family == null || billerName == null || billerName.isEmpty) return false;
  final canonical = canonicalBankSender(family);
  final aggregator =
      canonical == 'mytneu' || canonical == 'tnbpay' || canonical == 'tatanu';
  return aggregator &&
      !billerName.contains('credit card') &&
      !billerName.contains('card bill');
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}

bool _isHdfcCard(UserCard card) {
  final name = [
    card.nickname,
    card.cardName,
  ].whereType<String>().join(' ').toLowerCase();
  return name.contains('hdfc') ||
      name.contains('moneyback') ||
      name.contains('millennia') ||
      name.contains('regalia') ||
      name.contains('infinia') ||
      name.contains('tata neu') ||
      name.contains('swiggy');
}

List<UserCard> _candidateCardsForEvidence(
  CardBillEvidence orphan,
  List<UserCard> cards,
) {
  final family = orphan.family;
  if (family == null || family.isEmpty) return const [];
  final canonical = canonicalBankSender(family);

  // 1. Aggregators / Co-brand sender families for HDFC Bank
  // MYTNEU/TNBPAy are sent by the Tata Neu app for ALL HDFC cards (including
  // MoneyBack+, Millennia, Regalia, etc.), not solely the co-branded card.
  final isHdfcFamily =
      canonical == 'hdfc' ||
      canonical == 'mytneu' ||
      canonical == 'tnbpay' ||
      canonical == 'tatanu';
  if (isHdfcFamily) {
    final hdfcCards = cards.where(_isHdfcCard).toList();
    if (hdfcCards.isNotEmpty) return hdfcCards;
  }

  // 2. Specific card name match via family token
  final named = cards.where((c) => _familyNamesCard(family, c)).toList();
  if (named.length == 1) return named;

  // 3. General bank code prefix/slug match against card name/nickname
  final bankMatched = cards.where((c) {
    final name = [
      c.nickname,
      c.cardName,
    ].whereType<String>().join(' ').toLowerCase();
    return name.contains(canonical);
  }).toList();
  if (bankMatched.isNotEmpty) return bankMatched;

  return named;
}

Money _calculateCandidateCycleSpend(
  UserCard card,
  DateTime statementDate,
  List<TransactionEntry> txns, {
  List<CardBillEvidence> evidence = const [],
}) {
  final start = statementDate.subtract(const Duration(days: 35));
  final end = statementDate;
  var total = const Money.zero();
  for (final t in txns) {
    if (t.status != 'active' || t.entryKind != TxnEntryKind.spend) continue;
    if (isCardBillPaymentTxn(t)) continue;
    final merch = (t.merchantName ?? '').toLowerCase();
    final note = (t.note ?? '').toLowerCase();
    if (merch.contains('bill payment') || note.contains('bill payment')) {
      continue;
    }
    if (merch.contains('autopay') || note.contains('autopay')) continue;
    // Exclude large single anomaly transactions occurring at statement night
    if (t.amount.paise > 5000000) continue;
    // Exclude debits matching a known autopay or bill evidence amount for this card
    final isKnownBill = evidence.any(
      (e) =>
          e.cardLast4 == card.last4 &&
          e.amountDue != null &&
          e.amountDue!.paise == t.amount.paise,
    );
    if (isKnownBill) continue;

    final match =
        (t.userCardId != null && t.userCardId == card.id) ||
        (t.cardLast4 != null && t.cardLast4 == card.last4);
    if (!match) continue;
    if (t.occurredAt.isBefore(start) ||
        t.occurredAt.isAfter(end.add(const Duration(hours: 12)))) {
      continue;
    }
    total += t.amount;
  }
  return total;
}

bool _hasHistoricalAttribution(
  UserCard candidate,
  String? orphanFamily,
  List<CardBillEvidence> evidence,
  List<TransactionEntry> txns, {
  String? orphanBillerName,
}) {
  if (orphanFamily == null || orphanFamily.isEmpty) return false;
  final canonical = canonicalBankSender(orphanFamily);
  final isAggregator =
      (canonical == 'mytneu' || canonical == 'tnbpay' || canonical == 'tatanu');

  // Aggregator sender history is meaningful only for an actual card bill.
  // The same MYTNEU/TNBPAY channels deliver utilities, so a named non-card
  // bill must never inherit a card association through any fallback below.
  if (isAggregator && orphanBillerName != null) {
    final biller = orphanBillerName.trim().toLowerCase();
    if (biller.isNotEmpty &&
        !biller.contains('credit card') &&
        !biller.contains('card bill')) {
      return false;
    }
  }

  // 1. Evidence check: does any orphan bill from this sender family share an amount with an explicit bill for this candidate?
  for (final orphan in evidence.where(
    (e) => e.cardLast4 == null && e.amountDue != null,
  )) {
    if (orphan.family == null) continue;
    final orphanFam = canonicalBankSender(orphan.family);
    final matchesFam =
        orphanFam == canonical ||
        (isAggregator &&
            (orphanFam == 'mytneu' ||
                orphanFam == 'tnbpay' ||
                orphanFam == 'tatanu'));
    if (!matchesFam) continue;

    for (final ex in evidence.where(
      (e) =>
          e.cardLast4 != null &&
          e.cardLast4 == candidate.last4 &&
          e.amountDue != null,
    )) {
      if (orphan.amountDue == ex.amountDue) {
        // For aggregator senders (MYTNEU/TNBPAY) that carry both credit-card
        // and utility bills, require the biller identity to be absent or to
        // indicate a credit-card bill. A Goa Electricity bill must not
        // inherit a historical link established by an HDFC CC bill.
        return true;
      }
    }
  }

  // 2. Direct evidence check (other bill / AutoPay alert evidence lines)
  for (final ev in evidence) {
    if (ev.cardLast4 != null && ev.cardLast4 == candidate.last4) {
      if (ev.family != null) {
        final evFam = canonicalBankSender(ev.family);
        if (evFam == canonical ||
            (isAggregator &&
                (evFam == 'mytneu' ||
                    evFam == 'tnbpay' ||
                    evFam == 'tatanu'))) {
          return true;
        }
      }
    }
  }

  // 2. Transactions / Payments check
  for (final t in txns) {
    final cardMatch =
        (t.userCardId != null && t.userCardId == candidate.id) ||
        (t.cardLast4 != null && t.cardLast4 == candidate.last4) ||
        (candidate.last4 != null &&
            ((t.merchantName ?? '').contains(candidate.last4!) ||
                (t.note ?? '').contains(candidate.last4!)));
    if (!cardMatch) continue;

    final merch = (t.merchantName ?? '').toLowerCase();
    final note = (t.note ?? '').toLowerCase();
    final isPaymentOrAutopay =
        isCardBillPaymentTxn(t) ||
        merch.contains('bill payment') ||
        note.contains('bill payment') ||
        merch.contains('autopay') ||
        note.contains('autopay');
    if (!isPaymentOrAutopay) continue;

    if (merch.contains(canonical) || note.contains(canonical)) {
      return true;
    }
    final rawFamily = orphanFamily.toLowerCase();
    if (merch.contains(rawFamily) || note.contains(rawFamily)) {
      return true;
    }
    final src = t.source.toLowerCase();
    if (src.contains(canonical)) {
      return true;
    }
    if (isAggregator) {
      if (merch.contains('tata neu') ||
          note.contains('tata neu') ||
          merch.contains('mytneu') ||
          note.contains('mytneu') ||
          merch.contains('tnbpay') ||
          note.contains('tnbpay') ||
          merch.contains('tatanu') ||
          note.contains('tatanu') ||
          src.contains('mytneu') ||
          src.contains('tnbpay') ||
          src.contains('tatanu')) {
        return true;
      }
    }
  }

  return false;
}
