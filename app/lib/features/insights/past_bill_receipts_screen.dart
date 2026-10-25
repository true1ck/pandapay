import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/past_bill_receipts.dart';
import 'bills_horizon.dart';

class PastBillReceiptsScreen extends ConsumerWidget {
  final BillsHorizonFilter? filter;

  const PastBillReceiptsScreen({super.key, this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(pastBillReceiptsProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Past bills & receipts',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: history.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(AppSpace.lg),
            child: SkeletonList(count: 4),
          ),
          error: (_, _) => const Center(
            child: Text('Past bills are unavailable right now.'),
          ),
          data: (allItems) {
            final items = filter == null
                ? allItems
                : allItems
                      .where(filter!.matchesReceipt)
                      .toList(growable: false);
            return items.isEmpty
                ? Center(
                    child: Text(
                      filter == null || filter!.isUpcoming
                          ? 'No past bills or receipts yet.'
                          : 'No past bills or receipts in ${filter!.label}.',
                      style: BambooFonts.ui(14, color: BambooInk.ink500),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpace.sm),
                    itemBuilder: (_, index) =>
                        _PastBillHistoryRow(item: items[index]),
                  );
          },
        ),
      ),
    );
  }
}

class PastBillReceiptDetailScreen extends StatelessWidget {
  final PastBillReceipt item;
  const PastBillReceiptDetailScreen({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        title: Text(
          item.merchant,
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        backgroundColor: BambooInk.paper,
        elevation: 0,
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              item.amount?.format(hidePaise: true) ?? 'Amount not seen',
              style: BambooFonts.money(26, color: BambooInk.ink900),
            ),
            Text(
              _pastBillStatusLabel(item),
              style: BambooFonts.ui(
                14,
                color:
                    item.status == PastBillReceiptStatus.historicalUnpaid ||
                        item.status == PastBillReceiptStatus.needsConfirmation
                    ? BambooInk.clayInk
                    : BambooInk.jade,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailLine(
                    'Date',
                    DateFormat('d MMM yyyy').format(item.occurredAt),
                  ),
                  if (item.sender?.isNotEmpty == true)
                    _detailLine('From', item.sender!),
                  _detailLine(
                    'Received',
                    DateFormat('d MMM yyyy, h:mm a').format(item.receivedAt.toLocal()),
                  ),
                  if (item.linkedTransactionId != null)
                    _detailLine(
                      'Linked transaction',
                      item.linkedTransactionId!,
                    ),
                ],
              ),
            ),
            if (item.body?.isNotEmpty == true &&
                !RegExp(r'^Card ending \d{4}$').hasMatch(item.body!)) ...[
              const SizedBox(height: AppSpace.lg),
              Container(
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: BambooInk.glassFillOnPaper,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                child: Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: true,
                    title: Text(
                      'Original SMS',
                      style: BambooFonts.ui(
                        14,
                        color: BambooInk.ink900,
                        weight: FontWeight.w600,
                      ),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          item.body!,
                          style: BambooFonts.ui(14, color: BambooInk.ink700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(height: AppSpace.lg),
              Text(
                'Original SMS text is unavailable.',
                style: BambooFonts.ui(13, color: BambooInk.ink500),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _detailLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: BambooFonts.ui(12, color: BambooInk.ink500)),
        Text(value, style: BambooFonts.ui(14, color: BambooInk.ink900)),
      ],
    ),
  );
}

class _PastBillHistoryRow extends StatelessWidget {
  final PastBillReceipt item;
  const _PastBillHistoryRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.xs,
      ),
      tileColor: BambooInk.glassFillOnPaper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      leading: const Icon(Icons.receipt_long_outlined, color: BambooInk.ink500),
      title: Text(
        item.merchant,
        style: BambooFonts.ui(
          14,
          color: BambooInk.ink900,
          weight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${DateFormat('d MMM yyyy').format(item.occurredAt)} · ${_pastBillStatusLabel(item)}',
        style: BambooFonts.ui(
          12,
          color:
              item.status == PastBillReceiptStatus.historicalUnpaid ||
                  item.status == PastBillReceiptStatus.needsConfirmation
              ? BambooInk.clayInk
              : BambooInk.jade,
        ),
      ),
      trailing: item.amount == null
          ? null
          : Text(
              item.amount!.format(hidePaise: true),
              style: BambooFonts.money(14, color: BambooInk.ink900),
            ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PastBillReceiptDetailScreen(item: item),
        ),
      ),
    );
  }
}

String _pastBillStatusLabel(PastBillReceipt item) => switch (item.status) {
  PastBillReceiptStatus.paidLinked => 'Paid · Linked',
  PastBillReceiptStatus.paidUnlinked => 'Paid · Unlinked',
  PastBillReceiptStatus.historicalUnpaid => 'Past bill · Payment not detected',
  PastBillReceiptStatus.needsConfirmation =>
    item.kind == PastBillReceiptKind.bill
        ? 'Past bill · Needs confirmation'
        : 'Receipt · Needs confirmation',
  PastBillReceiptStatus.userSavedPurchase => 'Saved purchase',
};
