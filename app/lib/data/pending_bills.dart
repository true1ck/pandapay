import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'card_bill_ledger.dart';
import 'commitments_repository.dart';
import 'user_cards_repository.dart';

/// What a bill-shaped SMS observation looks like on the Bills page once the
/// logged transaction history has been searched for the payment.
enum SmsBillState { linked, pending, paymentNotDetected }

class SmsBillRow {
  /// Stable across restarts: derived from (identity, bill month, amount), so
  /// "mark as paid" / "not a bill" survive new reminder messages arriving.
  final String id;
  final String title;
  final CommitmentCategory category;
  final String? cardLast4;
  final String? accountLast4;
  final Money amountDue;
  final Money? minimumDue;
  final DateTime? dueDate;
  final DateTime receivedAt;
  final bool isAutopay;

  /// A logged attempt on the same card/biller failed inside the payment
  /// window. Never by itself says the bill is unpaid.
  final bool sawFailedAttempt;
  final SmsBillState state;
  final String? linkedTxnId;
  final DateTime? linkedTxnAt;
  final Money? linkedTxnAmount;

  /// The raw SMS this came from — device-local only (never uploaded).
  final String? sampleBody;

  const SmsBillRow({
    required this.id,
    required this.title,
    required this.category,
    this.cardLast4,
    this.accountLast4,
    required this.amountDue,
    required this.minimumDue,
    required this.dueDate,
    required this.receivedAt,
    required this.isAutopay,
    required this.sawFailedAttempt,
    required this.state,
    this.linkedTxnId,
    this.linkedTxnAt,
    this.linkedTxnAmount,
    this.sampleBody,
  });
}

/// Matches the identity scheme `commitmentsProvider.identityFor` derives
/// (category | slug(title) | last4) so the two lists never show the same
/// bill twice. Must stay in sync with that provider.
String smsBillSlug(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

String smsBillIdentity(String categoryName, String title, String? last4) {
  final suffix =
      RegExp(r'(\d{4})$').firstMatch(last4 ?? '')?.group(1) ?? (last4 ?? '');
  return [categoryName, smsBillSlug(title), suffix].join('|');
}

/// Same scheme, rebuilt from an existing commitment (identifier is
/// '••••1234' both for manual rows and derived ones).
String smsBillIdentityForCommitment(Commitment commitment) => smsBillIdentity(
  commitment.category.name,
  commitment.title,
  commitment.identifier,
);

/// Pure derivation: sms_observations rows (event bill/autopay) matched
/// against the logged transaction history. No I/O, no clock reads.
List<SmsBillRow> deriveSmsBillRows({
  required List<Map<String, dynamic>> observations,
  required List<TransactionEntry> transactions,
  Map<String, String> cardsLast4ById = const {},
  Set<String> takenIdentities = const {},
  DateTime? now,
  int lookbackDays = 90,
  int graceDays = 5,
  int settleWindowDays = 10,
}) {
  final at = now ?? DateTime.now();
  final today = DateTime(at.year, at.month, at.day);
  final cutoff = today.subtract(Duration(days: lookbackDays - 1));

  DateTime? iso(dynamic value) =>
      value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
  Money? money(dynamic paise) =>
      paise is int && paise > 0 ? Money.fromPaise(paise) : null;

  final raws = <_Raw>[];
  for (final obs in observations) {
    final event = obs['event_type'] as String?;
    if (event != 'bill' && event != 'autopay') continue;
    final received = iso(obs['received_at']);
    if (received == null || received.isBefore(cutoff)) continue;
    final biller = ((obs['biller_name'] as String?) ?? '').trim();
    final last4 = obs['card_last4'] as String?;
    final accountLast4 = obs['account_last4'] as String?;
    // Parser-emitted "biller" names are sometimes sentence fragments
    // ("your card", "payment of"); same rejection as the
    // commitmentsProvider title path.
    var title =
        RegExp(
          r'^(?:your|our|a\b|an\b|the\b|this\b|card\b|'
          r'credit\b|debit\b|payment\b|bill\b|account\b|e-?mandate\b|'
          r'nach\b|si\b|standing\b|instruction\b)',
        ).hasMatch(biller.toLowerCase())
        ? ''
        : biller;
    if (title.length <= 2 && (last4 != null || accountLast4 != null)) {
      final sender = (obs['sender_bank'] as String?)?.trim() ?? '';
      if (sender.length > 2) title = sender;
    }
    if (title.length <= 2) continue;
    final amountDue = money(obs['amount_due_paise']);
    final minimumDue = money(obs['minimum_due_paise']);
    if (amountDue == null && minimumDue == null) {
      continue;
    }
    final category = CommitmentCategory.fromText(
      '$title ${obs['sender_bank'] ?? ''}',
    );
    final anchor = amountDue ?? minimumDue!;
    final dueDate = iso(obs['due_date']);
    final monthKey = DateTime(
      (dueDate ?? received).year,
      (dueDate ?? received).month,
    );
    raws.add(
      _Raw(
        identity: smsBillIdentity(category.name, title, accountLast4 ?? last4),
        title: title,
        category: category,
        amountDue: amountDue,
        minimumDue: minimumDue,
        dueDate: dueDate,
        received: received,
        last4: last4,
        accountLast4: accountLast4,
        sampleBody: obs['sample_body'] as String?,
        isAutopay: obs['is_autopay'] == true || event == 'autopay',
        anchor: anchor,
        monthKey: monthKey,
        tokens: _tokensOf(title),
      ),
    );
  }
  raws.sort((a, b) => b.received.compareTo(a.received));

  // One row per (identity, month, amount): the statement notice and the due
  // reminder for one bill collapse to the newest message.
  final kept = <String, _Raw>{};
  for (final raw in raws) {
    kept.putIfAbsent(raw.dedupKey, () => raw);
  }

  final failures = observations
      .where((o) => o['event_type'] == 'failed')
      .map(
        (o) => (
          received: iso(o['received_at']),
          last4: o['card_last4'] as String?,
          biller: ((o['biller_name'] as String?) ?? '').trim().toLowerCase(),
        ),
      )
      .where((f) => f.received != null)
      .toList();

  final rows = <SmsBillRow>[];
  for (final raw in kept.values) {
    // Manual or already-derived rows keep living in the commitments
    // sections. Only payment problems stay visible here.
    final taken = takenIdentities.contains(raw.identity);
    if (taken) continue;
    final anchorDate = raw.dueDate ?? raw.received;
    final windowFrom = anchorDate.subtract(
      Duration(days: raw.last4 == null ? 3 : 30),
    );
    final windowTo = anchorDate.add(
      Duration(days: raw.dueDate == null ? 60 : settleWindowDays),
    );
    final isCardBill = raw.last4 != null;

    TransactionEntry? best;
    Money? bestAmount;
    // ponytail: Fallback equality on biller tokens is loose; tighten to
    // exact-match only when false links show up in practice.
    for (final txn in transactions) {
      if (txn.status != 'active') continue;
      final cardBillPayment = isCardBillPaymentTxn(txn);
      if (txn.entryKind != TxnEntryKind.spend && !cardBillPayment) continue;
      if (txn.occurredAt.isBefore(windowFrom) ||
          txn.occurredAt.isAfter(windowTo)) {
        continue;
      }
      if (!_amountCovers(raw, txn.amount)) continue;
      final txnLast4 = txn.cardLast4 ?? cardsLast4ById[txn.userCardId];
      final merchant = (txn.merchantName ?? '').toLowerCase();
      final matchesCard = isCardBill && cardBillPayment && txnLast4 == raw.last4;
      final matchesBiller = raw.last4 == null &&
          (tokensOverlap(raw.tokens, merchant) ||
              (raw.accountLast4 != null &&
                  txn.accountLast4 == raw.accountLast4));
      if (!matchesCard && !matchesBiller) continue;
      if (best != null && !txn.occurredAt.isAfter(best.occurredAt)) {
        continue;
      }
      best = txn;
      bestAmount = txn.amount;
    }

    final sawFailed = failures.any((f) {
      if (f.received!.isBefore(windowFrom)) return false;
      if (f.received!.isAfter(windowTo)) return false;
      if (raw.last4 != null && f.last4 == raw.last4) return true;
      if (raw.tokens.isNotEmpty && tokensOverlap(raw.tokens, f.biller)) {
        return true;
      }
      return false;
    });

    final dueDate = raw.dueDate;
    final overdue =
        dueDate != null &&
        today.isAfter(dueDate.add(Duration(days: graceDays)));
    final state = best != null
        ? SmsBillState.linked
        : overdue
        ? SmsBillState.paymentNotDetected
        : SmsBillState.pending;
    final idSeed = jsonEncode([raw.identity, raw.dedupKey]);
    final id =
        'sms-bill-${sha256.convert(utf8.encode(idSeed)).toString().substring(0, 16)}';
    rows.add(
      SmsBillRow(
        id: id,
        title: raw.title,
        category: raw.category,
        cardLast4: raw.last4,
        accountLast4: raw.accountLast4,
        amountDue: raw.anchor,
        minimumDue: raw.minimumDue,
        dueDate: raw.dueDate,
        receivedAt: raw.received,
        isAutopay: raw.isAutopay,
        sawFailedAttempt: sawFailed,
        state: state,
        linkedTxnId: best?.id,
        linkedTxnAt: best?.occurredAt,
        linkedTxnAmount: bestAmount,
        sampleBody: raw.sampleBody,
      ),
    );
  }

  rows.sort((a, b) {
    final aDue = a.dueDate ?? a.receivedAt;
    final bDue = b.dueDate ?? b.receivedAt;
    return aDue.compareTo(bDue);
  });
  return rows;
}

bool _amountCovers(_Raw raw, Money amount) {
  final anchor = raw.anchor.paise;
  if (raw.last4 != null) {
    // Card-bill payments land at-or-above the issued amount; 2% tolerance
    // mirrors the ledger match rule.
    return amount.paise >= anchor - (anchor * 0.02).round();
  }
  // Utility/scheduled bill: paid amount equals the reminder amount (±₹1).
  return (amount.paise - anchor).abs() <= 100;
}

bool tokensOverlap(List<String> tokens, String merchant) {
  if (merchant.isEmpty || tokens.isEmpty) return false;
  return tokens.any(merchant.contains);
}

List<String> _tokensOf(String title) {
  final cleaned = smsBillSlug(title).replaceAll('-', ' ');
  return cleaned
      .split(RegExp(r'\s+'))
      .where((t) => t.length >= 4 && !_digitsOnly(t))
      .toList();
}

bool _digitsOnly(String token) =>
    token.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

class _Raw {
  final String identity;
  final String title;
  final CommitmentCategory category;
  final Money? amountDue;
  final Money? minimumDue;
  final Money anchor;
  final DateTime? dueDate;
  final DateTime received;
  final String? last4;
  final String? accountLast4;
  final bool isAutopay;
  final String? sampleBody;
  final DateTime monthKey;
  final List<String> tokens;

  _Raw({
    required this.identity,
    required this.title,
    required this.category,
    required this.amountDue,
    required this.minimumDue,
    required this.anchor,
    required this.dueDate,
    required this.received,
    required this.last4,
    required this.accountLast4,
    required this.isAutopay,
    required this.sampleBody,
    required this.monthKey,
    required this.tokens,
  });

  String get dedupKey =>
      '$identity|${monthKey.toIso8601String()}|${anchor.paise}';
}
