import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/shared_expenses.dart';
import '../data/shared_commands.dart' show sharedUuid;
import 'shared_amount_input.dart';

enum SharedSplitMode { equal, exact, percentage, shares }

enum SharedEntryKind {
  unlinkedCash,
  someoneElsePaid,
  newOwnPayment,
  existingOwnPayment,
}

enum SharedDraftBlocker {
  sourceFundingUnavailable,
  sourceAdmissionPending,
  unconfirmedValuation,
}

class SharedPayerInput {
  final String fullText, sharedText;
  const SharedPayerInput({required this.fullText, required this.sharedText});
}

/// Calculation output for existing Quick Add/detail editors. It is a preview,
/// never a bank transaction, a consent decision or source-funding authorization.
class SharedDraftPreview {
  final Money billTotal,
      sharedTotal,
      yourFullPaid,
      yourSharedPaid,
      yourResidual,
      yourShare,
      yourPersonalCost,
      yourBalance;
  final Map<String, Money> shares;
  final Map<String, Object?> financialSnapshot;
  final Map<String, Object?> billMetadata;
  SharedDraftPreview({
    required this.billTotal,
    required this.sharedTotal,
    required this.yourFullPaid,
    required this.yourSharedPaid,
    required this.yourResidual,
    required this.yourShare,
    required this.yourPersonalCost,
    required this.yourBalance,
    required Map<String, Money> shares,
    required Map<String, Object?> financialSnapshot,
    required Map<String, Object?> billMetadata,
  }) : shares = Map.unmodifiable(shares),
       financialSnapshot = Map.unmodifiable(financialSnapshot),
       billMetadata = Map.unmodifiable(billMetadata);
}

class SharedDraftEvaluation {
  final Map<String, String> errors;
  final Set<SharedDraftBlocker> blockers;
  final SharedDraftPreview? preview;
  SharedDraftEvaluation(
    Map<String, String> errors,
    Set<SharedDraftBlocker> blockers,
    this.preview,
  ) : errors = Map.unmodifiable(errors),
      blockers = Set.unmodifiable(blockers);
  bool get isValid => errors.isEmpty && preview != null;

  /// Local form gate only. Server source admission and whole-revision consent
  /// still apply; this class deliberately exposes no posting/save operation.
  bool get canPropose => isValid && blockers.isEmpty;
}

class SharedExpenseDraft {
  final String ownMemberId, ownAccountId, billText, sharedText;

  /// Stable persisted membership order, never the current display sort order.
  final List<String> memberOrder, participants;
  final Map<String, SharedPayerInput> payers;
  final SharedSplitMode mode;
  final Map<String, String> splitInputs;
  final SharedEntryKind entryKind;
  final SharedExpenseSourceReference? source;
  final Money? lockedOwnPaid;
  final bool confirmedValuation;
  SharedExpenseDraft({
    required this.ownMemberId,
    required this.ownAccountId,
    required List<String> memberOrder,
    required this.billText,
    required this.sharedText,
    required Map<String, SharedPayerInput> payers,
    required List<String> participants,
    this.mode = SharedSplitMode.equal,
    Map<String, String> splitInputs = const {},
    this.entryKind = SharedEntryKind.unlinkedCash,
    this.source,
    this.lockedOwnPaid,
    this.confirmedValuation = true,
  }) : memberOrder = List.unmodifiable(memberOrder),
       payers = Map.unmodifiable(payers),
       participants = List.unmodifiable(participants),
       splitInputs = Map.unmodifiable(splitInputs);

  SharedDraftEvaluation evaluate({bool sourceFundingEnabled = false}) {
    final errors = <String, String>{}, blockers = <SharedDraftBlocker>{};
    final order = memberOrder.toSet();
    if (memberOrder.isEmpty ||
        memberOrder.length > 200 ||
        order.length != memberOrder.length ||
        !memberOrder.every(sharedUuid) ||
        !order.contains(ownMemberId) ||
        !sharedUuid(ownAccountId)) {
      errors['members'] = 'Refresh the people in this split before continuing.';
    }
    if (participants.isEmpty ||
        participants.length > 50 ||
        participants.toSet().length != participants.length ||
        !participants.every(order.contains)) {
      errors['participants'] =
          'Choose between 1 and 50 current members, once each.';
    }
    if (payers.isEmpty ||
        payers.length > 8 ||
        !payers.keys.every(order.contains)) {
      errors['payers'] = 'Choose between 1 and 8 current payers.';
    }
    int? amount(String text, String field, {bool positive = false}) {
      final input = SharedDecimalInput.parse(text, allowZero: !positive);
      if (!input.isValid) {
        errors[field] =
            'Enter ${positive ? 'a positive' : 'an'} amount with at most two decimal places.';
      }
      return input.units;
    }

    final bill = amount(billText, 'bill', positive: true),
        shared = amount(sharedText, 'shared', positive: true);
    if (bill != null && shared != null && shared > bill) {
      errors['shared'] = 'Shared amount exceeds the bill total.';
    }
    final fullPaid = <String, int>{}, sharedPaid = <String, int>{};
    for (final entry in payers.entries) {
      final full = amount(
            entry.value.fullText,
            'paid:${entry.key}',
            positive: true,
          ),
          part = amount(entry.value.sharedText, 'sharedPaid:${entry.key}');
      if (full != null) fullPaid[entry.key] = full;
      if (part != null) sharedPaid[entry.key] = part;
      if (full != null && part != null && part > full) {
        errors['sharedPaid:${entry.key}'] =
            'Shared contribution exceeds this person\'s payment.';
      }
    }
    if (fullPaid.length == payers.length &&
        bill != null &&
        fullPaid.values.fold<int>(0, (a, b) => a + b) != bill) {
      errors['paidTotal'] = 'Payments must add up to the bill total.';
    }
    if (sharedPaid.length == payers.length &&
        shared != null &&
        sharedPaid.values.fold<int>(0, (a, b) => a + b) != shared) {
      errors['sharedPaidTotal'] =
          'Shared contributions must add up to the shared amount.';
    }
    final ownFull = fullPaid[ownMemberId] ?? 0,
        ownShared = sharedPaid[ownMemberId] ?? 0;
    if (entryKind == SharedEntryKind.someoneElsePaid && ownFull != 0) {
      errors['payerIntent'] =
          'Choose who paid. Your payment must be zero when someone else paid.';
    }
    final linked =
        source != null ||
        entryKind == SharedEntryKind.existingOwnPayment ||
        entryKind == SharedEntryKind.newOwnPayment;
    if (linked) {
      if (!sourceFundingEnabled) {
        blockers.add(SharedDraftBlocker.sourceFundingUnavailable);
      }
      final ref = source?.toJson();
      if (ref == null ||
          ref['canonicalTransactionId'] == null ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(ref['sourceVersion'] ?? '') ||
          lockedOwnPaid == null) {
        blockers.add(SharedDraftBlocker.sourceAdmissionPending);
      }
      if (source != null && source!.ownerAccountId != ownAccountId) {
        errors['source'] = 'Choose your own payment.';
      }
      if (lockedOwnPaid != null &&
          (lockedOwnPaid!.paise != ownFull || ownFull <= 0)) {
        errors['sourceAmount'] =
            'Your contribution must match the current linked payment.';
      }
    }
    if (!confirmedValuation) {
      blockers.add(SharedDraftBlocker.unconfirmedValuation);
    }
    final allocationInputs = <Map<String, String>>[];
    for (final id in memberOrder.where(participants.contains)) {
      final row = <String, String>{'memberId': id};
      if (mode == SharedSplitMode.exact) {
        final parsed = amount(splitInputs[id] ?? '', 'split:$id');
        if (parsed != null) row['amountMinor'] = '$parsed';
      } else if (mode != SharedSplitMode.equal) {
        final parsed = SharedDecimalInput.parse(
          splitInputs[id] ?? '',
          precision: mode == SharedSplitMode.percentage ? 2 : 0,
          maxUnits: mode == SharedSplitMode.percentage ? 10000 : 1000000,
        );
        if (!parsed.isValid) {
          errors['split:$id'] = mode == SharedSplitMode.percentage
              ? 'Enter a percentage from 0 to 100.'
              : 'Enter whole shares from 0 to 1000000.';
        } else {
          row['weight'] = '${parsed.units}';
        }
      }
      allocationInputs.add(row);
    }
    if (errors.isNotEmpty) return SharedDraftEvaluation(errors, blockers, null);
    final selected = participants.toSet(),
        involved = {
          ...selected,
          ...sharedPaid.entries.where((e) => e.value > 0).map((e) => e.key),
        };
    try {
      final allocation = allocateSharedExpense({
        'currency': 'INR',
        'totalMinor': '$shared',
        'mode': mode.name,
        'participants': allocationInputs,
        'tieOrder': memberOrder.where(selected.contains).toList(),
      });
      final shares = {
        for (final row in allocation['allocations'] as List)
          (row as Map)['memberId'] as String: sharedMoneyFromMinor(
            row['amountMinor'],
          ),
      };
      final snapshot = <String, Object?>{
        'currency': 'INR',
        'totalMinor': '$shared',
        'contributions': List.unmodifiable([
          for (final id in memberOrder)
            if ((sharedPaid[id] ?? 0) > 0)
              Map<String, String>.unmodifiable({
                'memberId': id,
                'amountMinor': '${sharedPaid[id]}',
              }),
        ]),
        'shares': List.unmodifiable([
          for (final row in allocation['allocations'] as List)
            Map<String, String>.unmodifiable(
              (row as Map).cast<String, String>(),
            ),
        ]),
        'memberOrder': List.unmodifiable(memberOrder.where(involved.contains)),
      };
      projectSharedExpense(snapshot);
      final share = shares[ownMemberId] ?? const Money.zero();
      final cost = sharedPersonalCost({
        'sourceAmountMinor': '$ownFull',
        'linkedAmountMinor': '$ownShared',
        'shareMinor': '${share.paise}',
      });
      return SharedDraftEvaluation(
        errors,
        blockers,
        SharedDraftPreview(
          billTotal: Money.fromPaise(bill!),
          sharedTotal: Money.fromPaise(shared!),
          yourFullPaid: Money.fromPaise(ownFull),
          yourSharedPaid: Money.fromPaise(ownShared),
          yourResidual: sharedMoneyFromMinor(cost['residualMinor']),
          yourShare: share,
          yourPersonalCost: sharedMoneyFromMinor(cost['costMinor']),
          yourBalance: Money.fromPaise(ownShared - share.paise),
          shares: shares,
          financialSnapshot: snapshot,
          billMetadata: {
            'currency': 'INR',
            'totalMinor': '$bill',
            'contributions': List.unmodifiable([
              for (final id in memberOrder)
                if ((fullPaid[id] ?? 0) > 0)
                  Map<String, String>.unmodifiable({
                    'memberId': id,
                    'amountMinor': '${fullPaid[id]}',
                  }),
            ]),
            'allocation': Map<String, Object?>.unmodifiable({
              'mode': mode.name,
              'participants': List.unmodifiable([
                for (final input in allocationInputs)
                  Map<String, String>.unmodifiable(input),
              ]),
              'tieOrder': List.unmodifiable(
                memberOrder.where(selected.contains),
              ),
            }),
          },
        ),
      );
    } on SharedExpenseException {
      errors['splitTotal'] = mode == SharedSplitMode.exact
          ? 'Shares must add up to the shared amount.'
          : mode == SharedSplitMode.percentage
          ? 'Percentages must add up to 100%.'
          : 'Enter at least one positive share.';
      return SharedDraftEvaluation(errors, blockers, null);
    }
  }
}
