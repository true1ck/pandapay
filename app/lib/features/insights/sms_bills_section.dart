import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/commitments_repository.dart';
import '../../data/pending_bills.dart';

class SmsBillsSection extends ConsumerWidget {
  const SmsBillsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bills = ref.watch(smsBillRowsProvider);
    return bills.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (rows) {
        if (rows.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bills from messages',
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Payment status is matched against transactions in PandaPay.',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
              const SizedBox(height: AppSpace.md),
              for (final bill in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _BillRow(
                    bill: bill,
                    onTap: () => _showBill(context, ref, bill),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _BillRow extends StatelessWidget {
  const _BillRow({required this.bill, required this.onTap});
  final SmsBillRow bill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (bill.state) {
      SmsBillState.linked => ('Payment found', BambooInk.jade),
      SmsBillState.pending => ('Upcoming', BambooInk.ink500),
      SmsBillState.paymentNotDetected => (
        'Payment not detected',
        BambooChartColors.coral,
      ),
    };
    final detail = [
      if (bill.dueDate != null)
        'Due ${DateFormat('d MMM').format(bill.dueDate!)}',
      if (bill.isMinimumOnly) 'Minimum due only',
      if (bill.cardLast4 != null) 'Card ••${bill.cardLast4}',
      if (bill.accountLast4 != null) 'Account ••${bill.accountLast4}',
      if (bill.isAutopay) 'AutoPay',
    ].join(' · ');
    return Material(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            children: [
              const Icon(Icons.receipt_long_rounded, color: BambooInk.ink500),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bill.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        14,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        detail,
                        style: BambooFonts.ui(11, color: BambooInk.ink500),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      bill.sawFailedAttempt && bill.state != SmsBillState.linked
                          ? 'Payment attempt failed'
                          : label,
                      style: BambooFonts.ui(
                        11,
                        weight: FontWeight.w600,
                        color:
                            bill.sawFailedAttempt &&
                                bill.state != SmsBillState.linked
                            ? BambooChartColors.coral
                            : color,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                bill.amountDue.format(hidePaise: true),
                style: BambooFonts.ui(
                  14,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showBill(BuildContext context, WidgetRef ref, SmsBillRow bill) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: BambooInk.paper,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              bill.title,
              style: BambooFonts.heading(20, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              '${bill.isMinimumOnly ? 'Minimum due' : 'Amount'} ${bill.amountDue.format(hidePaise: true)}',
              style: BambooFonts.ui(15, color: BambooInk.ink900),
            ),
            if (bill.dueDate != null)
              Text(
                'Due ${DateFormat('d MMM yyyy').format(bill.dueDate!)}',
                style: BambooFonts.ui(13, color: BambooInk.ink500),
              ),
            if (bill.linkedTxnAt != null)
              Text(
                'Matched payment ${DateFormat('d MMM yyyy').format(bill.linkedTxnAt!)}',
                style: BambooFonts.ui(13, color: BambooInk.jade),
              ),
            if (bill.sampleBody?.isNotEmpty == true) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                'Original message',
                style: BambooFonts.ui(
                  12,
                  weight: FontWeight.w600,
                  color: BambooInk.ink500,
                ),
              ),
              const SizedBox(height: AppSpace.xs),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: BambooInk.glassFillOnPaper,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                child: Text(
                  bill.sampleBody!,
                  style: BambooFonts.ui(12, color: BambooInk.ink700),
                ),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            if (bill.state != SmsBillState.linked)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final commitment = Commitment(
                      id: bill.id,
                      title: bill.title,
                      category: bill.category,
                      amount: bill.amountDue,
                      dueOn: bill.dueDate ?? bill.receivedAt,
                      identifier: (bill.accountLast4 ?? bill.cardLast4) == null
                          ? null
                          : '••••${bill.accountLast4 ?? bill.cardLast4}',
                      cadence: CommitmentCadence.oneTime,
                      status: CommitmentStatus.due,
                      source: CommitmentSource.sms,
                      isUserConfirmed: true,
                    );
                    await ref
                        .read(commitmentsRepositoryProvider)
                        .markAsPaid(
                          bill.id,
                          paidOn: DateTime.now(),
                          linkedTxnId: bill.linkedTxnId,
                          detectedCommitment: commitment,
                        );
                    ref.invalidate(commitmentsProvider);
                    ref.invalidate(smsBillRowsProvider);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Mark as paid'),
                ),
              ),
            TextButton.icon(
              onPressed: () async {
                await ref
                    .read(commitmentsRepositoryProvider)
                    .save(
                      Commitment(
                        id: bill.id,
                        title: bill.title,
                        category: bill.category,
                        amount: bill.amountDue,
                        dueOn: bill.dueDate ?? bill.receivedAt,
                        identifier:
                            (bill.accountLast4 ?? bill.cardLast4) == null
                            ? null
                            : '••••${bill.accountLast4 ?? bill.cardLast4}',
                        cadence: CommitmentCadence.oneTime,
                        status: CommitmentStatus.dismissed,
                        source: CommitmentSource.sms,
                      ),
                    );
                ref.invalidate(commitmentsProvider);
                ref.invalidate(smsBillRowsProvider);
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.visibility_off_outlined),
              label: const Text('Not a bill'),
            ),
          ],
        ),
      ),
    ),
  );
}
