import 'package:pandapay_domain/shared_expenses.dart';
import '../ui/shared_presentation.dart';

/// A proposal can be shown, but never substituted for an accepted money row.
/// Historical shared totals remain explicitly labelled when no full bill exists.
SharedExpenseRow? mapSharedExpenseRecord(
  Map<String, Object?> record,
  String own,
) {
  final pending = record['pendingRevision'];
  final proposed = record['totalMinor'] == null;
  if (proposed && pending is! Map) return null;
  final value = proposed ? Map<String, Object?>.from(pending as Map) : record;
  if (value['void'] == true && !proposed && pending == null) return null;
  final sharedPaid = sharedMoneyFromMinor(value['yourPaidMinor']);
  final share = sharedMoneyFromMinor(value['yourShareMinor']);
  final bill = value['bill'] as Map?;
  final total = sharedMoneyFromMinor(
    bill?['totalMinor'] ?? value['totalMinor'],
  );
  final ownContributions = bill?['contributions'] as List?;
  final fullPaid = bill == null
      ? sharedPaid
      : sharedMoneyFromMinor(
          ownContributions
                  ?.cast<Map>()
                  .where((m) => m['memberId'] == own)
                  .firstOrNull?['amountMinor'] ??
              '0',
        );
  return SharedExpenseRow(
    id: record['expenseId'] as String,
    title: value['title'] as String,
    billTotal: total,
    yourPaid: fullPaid,
    yourShare: share,
    paidBy: fullPaid.paise == total.paise
        ? 'You'
        : !fullPaid.isZero
        ? 'You and others'
        : 'Other members',
    payerLabel: bill == null ? 'Shared amount paid by' : 'Paid by',
    totalLabel: bill == null ? 'Shared total' : 'Bill total',
    paidLabel: bill == null ? 'Your shared contribution' : 'You paid',
    occurredAtLabel: value['occurredOn'] as String?,
    proposed: proposed,
    reviewLabel: proposed
        ? 'Proposed · not included in balances or spending'
        : pending != null
        ? 'Proposed change · accepted amounts shown'
        : null,
    participation: fullPaid.isZero && share.isZero
        ? SharedParticipation.notIncluded
        : !fullPaid.isZero && share.isZero
        ? SharedParticipation.paidForOthers
        : SharedParticipation.included,
  );
}
