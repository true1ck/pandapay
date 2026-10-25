import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/commitments_repository.dart';
import '../../data/pending_bills.dart';
import 'bills_horizon.dart';

class SmsBillsSection extends ConsumerStatefulWidget {
  final BillsHorizonFilter? filter;

  const SmsBillsSection({this.filter, super.key});

  @override
  ConsumerState<SmsBillsSection> createState() => _SmsBillsSectionState();
}

class _SmsBillsSectionState extends ConsumerState<SmsBillsSection> {
  bool _showAll = false;

  @override
  void didUpdateWidget(SmsBillsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filter?.horizon != widget.filter?.horizon) {
      _showAll = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final bills = ref.watch(smsBillRowsProvider);
    return bills.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (rows) {
        final visible = widget.filter == null
            ? rows
            : rows.where(widget.filter!.matchesSmsBill).toList(growable: false);
        if (visible.isEmpty) return const SizedBox.shrink();
        final today = widget.filter?.today ?? _today();
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bill payment status',
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Payment status is matched against transactions in PandaPay.',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
              const SizedBox(height: AppSpace.md),
              for (final bill in visible.take(_showAll ? visible.length : 3))
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _BillRow(
                    bill: bill,
                    today: today,
                    onTap: () => _showBill(context, ref, bill),
                  ),
                ),
              if (visible.length > 3)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _showAll = !_showAll),
                    icon: Icon(
                      _showAll ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    label: Text(_showAll ? 'Show less' : 'Show all ${visible.length}'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

class _BillRow extends StatelessWidget {
  const _BillRow({required this.bill, required this.today, required this.onTap});
  final SmsBillRow bill;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final overdue = bill.dueDate != null && bill.dueDate!.isBefore(today);
    final undated = bill.dueDate == null;
    final (label, color) = switch (bill.state) {
      SmsBillState.linked => ('Payment found', BambooInk.jade),
      SmsBillState.pending => overdue
          ? ('Payment not found yet', BambooInk.clayInk)
          : (undated ? 'No due date seen' : 'Upcoming', BambooInk.ink500),
      SmsBillState.paymentNotDetected => (
        'Payment not detected',
        BambooChartColors.coral,
      ),
    };
    final detail = [
      if (bill.dueDate != null)
        'Due ${DateFormat('d MMM').format(bill.dueDate!)}'
      else
        'Received ${DateFormat('d MMM').format(bill.receivedAt.toLocal())}',
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
  final repository = ref.read(commitmentsRepositoryProvider);
  final namespace = ref.read(cacheNamespaceProvider);
  var saving = false;
  Future<void> save(BuildContext sheetContext, {required bool paid}) async {
    if (saving) return;
    saving = true;
    try {
      final commitment = Commitment(
        id: bill.id,
        title: bill.title,
        category: bill.category,
        amount: bill.amountDue,
        dueOn: bill.dueDate ?? bill.receivedAt,
        identifier: (bill.accountLast4 ?? bill.cardLast4) == null
            ? null : '••••${bill.accountLast4 ?? bill.cardLast4}',
        cadence: CommitmentCadence.oneTime,
        status: paid ? CommitmentStatus.due : CommitmentStatus.dismissed,
        source: CommitmentSource.sms,
        isUserConfirmed: true,
      );
      if (paid) {
        await repository.markAsPaid(
          bill.id, paidOn: DateTime.now(),
          linkedTxnId: bill.linkedTxnId, detectedCommitment: commitment,
        );
      } else {
        await repository.save(commitment);
      }
      if (ref.context.mounted && ref.read(cacheNamespaceProvider) == namespace) {
        ref.invalidate(commitmentsProvider);
        ref.invalidate(smsBillRowsProvider);
      }
      if (sheetContext.mounted) Navigator.pop(sheetContext);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userFacingErrorMessage(error))),
        );
      }
    } finally {
      saving = false;
    }
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: BambooInk.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (context) => SafeArea(
      child: SizedBox(
        // A modal route supplies loose horizontal constraints. Without an
        // explicit width this compact sheet shrinks to its longest line of
        // text, leaving the narrow floating panel seen on phones.
        width: double.infinity,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.xs,
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
                if (bill.state != SmsBillState.linked) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => save(context, paid: true),
                      child: const Text('Mark as paid'),
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                ],
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => save(context, paid: false),
                    icon: const Icon(Icons.visibility_off_outlined),
                    label: const Text('Not a bill'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
