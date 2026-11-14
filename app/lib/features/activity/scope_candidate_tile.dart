import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../data/merchant_identity.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import 'transaction_avatar.dart';
import 'transaction_badge.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
];

/// Which card or account a payment came from, in words a person recognises.
String? scopeCandidateAccount(TransactionEntry e) {
  if (e.cardDisplayName != null) return e.cardDisplayName;
  if (e.instrument == TxnInstrument.creditCard) {
    return e.cardLast4 == null
        ? 'Credit card · unmatched'
        : 'Credit card ending ${e.cardLast4}';
  }
  if (e.instrument == TxnInstrument.upiBank) {
    final last4 = e.accountLast4 ?? e.cardLast4;
    return last4 == null
        ? 'Bank account · unmatched'
        : 'Bank account ending $last4';
  }
  return null;
}

/// One payment in a "also apply to these" list, drawn like a row of Activity:
/// the same logo or avatar, name, amount and card, so each can be told apart
/// before it is ticked. The tick sits on the avatar's corner, as in Activity's
/// select mode, and the row's border shows what is chosen.
class ScopeCandidateTile extends StatelessWidget {
  const ScopeCandidateTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final TransactionEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isIncome =
        entry.entryKind == TxnEntryKind.income ||
        entry.entryKind == TxnEntryKind.investmentReturn;
    final isMoneyOut =
        entry.entryKind == TxnEntryKind.spend ||
        entry.entryKind == TxnEntryKind.investment;
    final name =
        MerchantIdentity.transferPayee(
          MerchantIdentity.displayName(
                entry.merchantName,
                incoming: isIncome,
              ) ??
              '',
        ) ??
        MerchantIdentity.displayName(entry.merchantName, incoming: isIncome) ??
        entry.entryKind.label;
    final when = (entry.source == 'sms' || entry.source == 'sms_bulk')
        ? (entry.smsReceivedAt ?? entry.occurredAt)
        : entry.occurredAt;
    final local = when.toLocal();
    final clock = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final badge = txnBadgeKind(entry);
    final parts = <String>[
      '${local.day} ${_months[local.month - 1]} ${local.year} · $clock',
      ?scopeCandidateAccount(entry),
      if (entry.categoryName != null) entry.categoryLabel,
    ];
    return Semantics(
      checked: selected,
      button: true,
      label: '$name, ${entry.amount.format()}, ${parts.join(', ')}',
      excludeSemantics: true,
      onTap: onTap,
      child: Pressable(
        onTap: onTap,
        child: Container(
          key: ValueKey('scope-row-${entry.id}'),
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(
            color: selected
                ? BambooInk.lime.withValues(alpha: 0.14)
                : BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? BambooInk.ink900 : BambooInk.hairlineOnPaper,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  transactionLeading(entry),
                  Positioned(
                    left: -5,
                    top: -5,
                    child: Container(
                      key: ValueKey('scope-check-${entry.id}'),
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: selected ? BambooInk.lime : BambooInk.paper,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? BambooInk.ink900 : BambooInk.ink300,
                          width: 1.5,
                        ),
                      ),
                      child: selected
                          ? const Icon(
                              Icons.check_rounded,
                              size: 13,
                              color: BambooInk.ink900,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.heading(
                              14.5,
                              color: BambooInk.ink900,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: AppSpace.xs),
                          TransactionBadgePill(kind: badge),
                        ] else if (bankPaymentLabel(entry) case final m?) ...[
                          const SizedBox(width: AppSpace.xs),
                          TransactionBadgePill.plain(m),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      parts.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              MoneyText(
                entry.amount,
                prefix: isIncome
                    ? '+'
                    : isMoneyOut
                    ? '−'
                    : null,
                confidence: Confidence.estimated,
                showConfidenceIcon: false,
                style: BambooFonts.money(
                  15,
                  color: isIncome
                      ? BambooInk.jade
                      : isMoneyOut
                      ? BambooInk.clay
                      : BambooInk.ink900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
