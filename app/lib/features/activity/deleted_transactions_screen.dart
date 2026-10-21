import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../data/api_exception.dart' show userFacingErrorMessage;
import '../../main.dart' show MoneyText;

class DeletedTransactionsScreen extends ConsumerStatefulWidget {
  const DeletedTransactionsScreen({super.key});

  @override
  ConsumerState<DeletedTransactionsScreen> createState() =>
      _DeletedTransactionsScreenState();
}

class _DeletedTransactionsScreenState
    extends ConsumerState<DeletedTransactionsScreen> {
  List<TransactionEntry>? _entries;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _entries = null;
      _error = null;
    });
    try {
      final repository = ref.read(userCardsRepositoryProvider);
      if (repository == null) throw StateError('Account is unavailable.');
      final entries = await repository.fetchDeletedTransactions();
      if (mounted) setState(() => _entries = entries);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _restore(TransactionEntry entry, {bool edit = false}) async {
    try {
      final repository = ref.read(userCardsRepositoryProvider);
      if (repository == null) throw StateError('Account is unavailable.');
      await repository.restoreTransaction(entry.id);
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(utilizationTransactionsProvider);
      ref.invalidate(homeSummaryProvider);
      if (!mounted) return;
      setState(() => _entries?.removeWhere((item) => item.id == entry.id));
      if (edit) {
        await context.push('/activity/${entry.id}/edit');
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Transaction restored.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        elevation: 0,
        title: const Text('Deleted transactions'),
        actions: [
          IconButton(
            tooltip: 'Refresh deleted transactions',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _error != null
          ? ErrorState(message: userFacingErrorMessage(_error!), onRetry: _load)
          : entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? const EmptyState(
              icon: Icons.delete_sweep_outlined,
              title: 'No deleted transactions',
              message: 'Transactions you delete will appear here for recovery.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(AppSpace.lg),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpace.sm),
              itemBuilder: (context, index) => _DeletedTransactionCard(
                entry: entries[index],
                onRestore: () => _restore(entries[index]),
                onRestoreAndEdit: () => _restore(entries[index], edit: true),
              ),
            ),
    );
  }
}

class _DeletedTransactionCard extends StatelessWidget {
  final TransactionEntry entry;
  final VoidCallback onRestore;
  final VoidCallback onRestoreAndEdit;

  const _DeletedTransactionCard({
    required this.entry,
    required this.onRestore,
    required this.onRestoreAndEdit,
  });

  @override
  Widget build(BuildContext context) {
    final date = entry.occurredAt.toLocal().toString().split(' ').first;
    return Card(
      color: BambooInk.paper,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.delete_sweep_outlined, color: AppColors.error),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    entry.merchantName ?? 'Transaction',
                    style: BambooFonts.ui(15, weight: FontWeight.w700),
                  ),
                ),
                MoneyText(
                  entry.amount,
                  confidence: Confidence.estimated,
                  style: BambooFonts.money(16, color: AppColors.error),
                  showConfidenceIcon: false,
                  hidePaise: true,
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              '$date · Deleted from spending',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              children: [
                TextButton.icon(
                  onPressed: onRestore,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore'),
                ),
                TextButton.icon(
                  onPressed: onRestoreAndEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Restore & edit'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
