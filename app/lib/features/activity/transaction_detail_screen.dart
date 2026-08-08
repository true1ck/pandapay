import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// D2 Transaction Detail (ui-spec Group D). Deep-linkable at /activity/:id.
/// Full record incl. source and reconciliation status. Actions: edit (D3),
/// mark ignored (refund/reversal/transfer). "A better card existed" panel
/// and "split" are NOT built here — the former needs the shared historical-
/// recompute calculator (a separate, larger piece, not yet wired into any
/// screen), the latter needs a `transaction_splits` write path that doesn't
/// exist server-side yet (the table does, per database.sql, but no route
/// reads or writes it) — both flagged as real gaps, not silently faked.
class TransactionDetailScreen extends ConsumerWidget {
  final String transactionId;
  const TransactionDetailScreen({super.key, required this.transactionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txn = ref.watch(_transactionProvider(transactionId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction'),
        actions: [
          if (txn.valueOrNull?.status == 'active')
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/activity/$transactionId/edit'),
            ),
        ],
      ),
      body: txn.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(_transactionProvider(transactionId)),
        ),
        data: (entry) => _DetailBody(entry: entry),
      ),
    );
  }
}

final _transactionProvider = FutureProvider.family<TransactionEntry, String>((ref, id) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) throw ApiException('Not signed in');
  return repo.fetchTransaction(id);
});

class _DetailBody extends ConsumerStatefulWidget {
  final TransactionEntry entry;
  const _DetailBody({required this.entry});

  @override
  ConsumerState<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends ConsumerState<_DetailBody> {
  bool _ignoring = false;

  Future<void> _markIgnored(String reason) async {
    setState(() => _ignoring = true);
    try {
      await ref.read(userCardsRepositoryProvider)!.ignoreTransaction(widget.entry.id, reason: reason);
      ref.invalidate(_transactionProvider(widget.entry.id));
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marked as ignored.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _ignoring = false);
    }
  }

  Future<void> _showIgnoreSheet() async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(AppSpace.lg),
              child: Text('Why is this being ignored?'),
            ),
            for (final r in const ['refund', 'reversal', 'transfer'])
              ListTile(title: Text(_reasonLabel(r)), onTap: () => Navigator.of(context).pop(r)),
          ],
        ),
      ),
    );
    if (reason != null) await _markIgnored(reason);
  }

  static String _reasonLabel(String r) => switch (r) {
        'refund' => 'Refund',
        'reversal' => 'Reversal',
        'transfer' => 'Transfer (not really a spend)',
        _ => r,
      };

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final textTheme = Theme.of(context).textTheme;
    final isActive = entry.status == 'active';

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        if (!isActive)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.lg),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.visibility_off_outlined, size: 16, color: AppColors.ink500),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(
                    'This transaction is ${entry.status} — excluded from caps and rankings.',
                    style: textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        Center(
          child: Column(
            children: [
              MoneyText(entry.amount, confidence: Confidence.estimated, style: textTheme.headlineMedium),
              const SizedBox(height: AppSpace.xs),
              Text(entry.merchantName ?? 'Spend', style: textTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        _DetailRow(label: 'Card', value: entry.cardDisplayName ?? '—'),
        _DetailRow(label: 'Category', value: entry.categoryName ?? '—'),
        _DetailRow(label: 'Date', value: entry.occurredAt.toLocal().toString().split('.').first),
        _DetailRow(label: 'Rail', value: _railLabel(entry.rail)),
        _DetailRow(label: 'Source', value: _sourceLabel(entry.source)),
        _DetailRow(label: 'Status', value: entry.status[0].toUpperCase() + entry.status.substring(1)),
        if (entry.note != null) _DetailRow(label: 'Note', value: entry.note!),
        const SizedBox(height: AppSpace.xl),
        if (isActive)
          OutlinedButton.icon(
            onPressed: _ignoring ? null : _showIgnoreSheet,
            icon: _ignoring
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.visibility_off_outlined),
            label: const Text('Mark as ignored (refund / reversal / transfer)'),
          ),
      ],
    );
  }

  static String _railLabel(TxnRail rail) => switch (rail) {
        TxnRail.upiQr => 'UPI QR',
        TxnRail.swipe => 'Swipe',
        TxnRail.online => 'Online',
        TxnRail.contactless => 'Contactless',
        TxnRail.atm => 'ATM',
        TxnRail.emi => 'EMI',
        TxnRail.unknown => 'Unknown',
      };

  static String _sourceLabel(String source) => switch (source) {
        'manual' => 'Entered manually',
        'sms' => 'SMS',
        'email' => 'Email',
        'statement' => 'Statement import',
        'sms_bulk' => 'SMS backup import',
        'imported' => 'Imported',
        _ => source,
      };
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(value, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
