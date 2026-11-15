import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/commitments_repository.dart';
import '../../data/past_bill_receipts.dart';

/// What a bill is, in one word, so a row says it without opening it:
/// an insurance premium is not a utility bill and not a card payment.
class BillKind {
  const BillKind(this.label, this.icon, this.bg, this.fg);

  final String label;
  final IconData icon;
  final Color bg;
  final Color fg;

  static const creditCard = BillKind(
    'CREDIT CARD',
    Icons.credit_card_rounded,
    Color(0xFFE8EAF6),
    Color(0xFF3949AB),
  );

  static const sip = BillKind(
    'SIP',
    Icons.trending_up_rounded,
    Color(0xFFE0F2F1),
    Color(0xFF00796B),
  );

  /// A repeating investment instalment reads SIP (its cadence says so);
  /// everything else by its category.
  static BillKind forCommitment(Commitment c) =>
      c.category == CommitmentCategory.investment &&
          c.cadence != CommitmentCadence.oneTime
      ? sip
      : ofCategory(c.category);

  static BillKind ofCategory(CommitmentCategory c) => BillKind(
    switch (c) {
      CommitmentCategory.utility => 'UTILITY',
      CommitmentCategory.telecom => 'TELECOM',
      CommitmentCategory.insurance => 'INSURANCE',
      CommitmentCategory.loanOrEmi => 'LOAN / EMI',
      CommitmentCategory.rent => 'RENT',
      CommitmentCategory.education => 'EDUCATION',
      CommitmentCategory.tax => 'TAX',
      CommitmentCategory.subscription => 'SUBSCRIPTION',
      CommitmentCategory.investment => 'INVESTMENT',
      CommitmentCategory.other => 'BILL',
    },
    c.icon,
    c.iconBg,
    c.iconColor,
  );

  /// The kind a saved past bill carries; a card bill without one is told by
  /// its card digits. Null for a plain receipt (nothing to tag).
  static BillKind? ofPast(PastBillReceipt item) {
    final name = item.categoryName;
    if (name == 'creditCard') return creditCard;
    if (name == 'sip') return sip;
    if (name != null) {
      for (final c in CommitmentCategory.values) {
        if (c.name == name) return ofCategory(c);
      }
    }
    if (item.kind == PastBillReceiptKind.bill && item.cardLast4 != null) {
      return creditCard;
    }
    return null;
  }
}

/// The small pill that sits beside a bill's name.
class BillKindBadge extends StatelessWidget {
  const BillKindBadge(this.kind, {super.key});

  final BillKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: kind.bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kind.icon, size: 11, color: kind.fg),
          const SizedBox(width: 3),
          Text(
            kind.label,
            style: BambooFonts.ui(
              9.5,
              weight: FontWeight.w700,
              color: kind.fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// "name  [BADGE]" on one line: the name shrinks, the badge never does.
class NameWithBadge extends StatelessWidget {
  const NameWithBadge({super.key, required this.name, required this.style, this.kind});

  final String name;
  final TextStyle style;
  final BillKind? kind;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            style: style,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
        if (kind != null) ...[
          const SizedBox(width: AppSpace.xs),
          BillKindBadge(kind!),
        ],
      ],
    );
  }
}

/// The state line of a past bill. An insurance bill is a premium, not a bill.
String pastBillStatusLabel(PastBillReceipt item) {
  final premium = item.categoryName == CommitmentCategory.insurance.name;
  final noun = premium ? 'premium' : 'bill';
  return switch (item.status) {
    PastBillReceiptStatus.paidLinked => 'Paid · Linked',
    PastBillReceiptStatus.paidUnlinked => 'Paid · Unlinked',
    PastBillReceiptStatus.historicalUnpaid =>
      'Past $noun · Payment not detected',
    PastBillReceiptStatus.needsConfirmation =>
      item.kind == PastBillReceiptKind.bill
          ? 'Past $noun · Needs confirmation'
          : 'Receipt · Needs confirmation',
    PastBillReceiptStatus.userSavedPurchase => 'Saved purchase',
  };
}
