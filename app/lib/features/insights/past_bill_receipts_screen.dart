import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/past_bill_receipts.dart';

class PastBillReceiptsScreen extends ConsumerWidget {
  const PastBillReceiptsScreen({super.key});

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
        title: Text('Past bills & receipts', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: history.when(
          loading: () => const Padding(padding: EdgeInsets.all(AppSpace.lg), child: SkeletonList(count: 4)),
          error: (_, _) => const Center(child: Text('Past bills are unavailable right now.')),
          data: (items) => items.isEmpty
              ? Center(child: Text('No past bills or receipts yet.', style: BambooFonts.ui(14, color: BambooInk.ink500)))
              : ListView.separated(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpace.sm),
                  itemBuilder: (_, index) => _PastBillHistoryRow(item: items[index]),
                ),
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
      appBar: AppBar(title: Text(item.merchant, style: BambooFonts.heading(18, color: BambooInk.ink900)), backgroundColor: BambooInk.paper, elevation: 0),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(item.amount?.format(hidePaise: true) ?? 'Amount not seen', style: BambooFonts.money(26, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.xs),
            Text(_pastBillStatusLabel(item), style: BambooFonts.ui(14, color: item.status == PastBillReceiptStatus.historicalUnpaid ? BambooInk.clayInk : BambooInk.jade, weight: FontWeight.w600)),
            const SizedBox(height: AppSpace.lg),
            Text('Date', style: BambooFonts.ui(12, color: BambooInk.ink500)),
            Text(DateFormat('d MMM yyyy').format(item.occurredAt), style: BambooFonts.ui(15, color: BambooInk.ink900)),
            if (item.linkedTransactionId != null) ...[
              const SizedBox(height: AppSpace.md),
              Text('Linked transaction', style: BambooFonts.ui(12, color: BambooInk.ink500)),
              Text(item.linkedTransactionId!, style: BambooFonts.ui(14, color: BambooInk.ink900)),
            ],
            if (item.body != null) ...[
              const SizedBox(height: AppSpace.lg),
              Text('Receipt evidence', style: BambooFonts.ui(12, color: BambooInk.ink500)),
              const SizedBox(height: AppSpace.xs),
              Text(item.body!, style: BambooFonts.ui(14, color: BambooInk.ink700)),
            ],
          ],
        ),
      ),
    );
  }
}

class _PastBillHistoryRow extends StatelessWidget {
  final PastBillReceipt item;
  const _PastBillHistoryRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.xs),
      tileColor: BambooInk.glassFillOnPaper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: BambooInk.hairlineOnPaper)),
      leading: const Icon(Icons.receipt_long_outlined, color: BambooInk.ink500),
      title: Text(item.merchant, style: BambooFonts.ui(14, color: BambooInk.ink900, weight: FontWeight.w600)),
      subtitle: Text('${DateFormat('d MMM yyyy').format(item.occurredAt)} · ${_pastBillStatusLabel(item)}', style: BambooFonts.ui(12, color: item.status == PastBillReceiptStatus.historicalUnpaid ? BambooInk.clayInk : BambooInk.jade)),
      trailing: item.amount == null ? null : Text(item.amount!.format(hidePaise: true), style: BambooFonts.money(14, color: BambooInk.ink900)),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PastBillReceiptDetailScreen(item: item))),
    );
  }
}

String _pastBillStatusLabel(PastBillReceipt item) => switch (item.status) {
  PastBillReceiptStatus.paidLinked => 'Paid · Linked',
  PastBillReceiptStatus.paidUnlinked => 'Paid · Unlinked',
  PastBillReceiptStatus.historicalUnpaid => 'Past bill · Payment not detected',
  PastBillReceiptStatus.needsConfirmation => 'Needs confirmation',
  PastBillReceiptStatus.userSavedPurchase => 'Saved purchase',
};
