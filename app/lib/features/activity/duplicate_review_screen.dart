import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// D5 Duplicate Review (ui-spec Group D). Side-by-side suspected
/// duplicates (same amount+merchant+date across channels — detected
/// server-side by Task D-5's `detectDuplicates`, run on every transaction
/// insert). Merge / keep both / delete one. Explains why they're flagged
/// via `match_reason`.
class DuplicateReviewScreen extends ConsumerWidget {
  const DuplicateReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates = ref.watch(duplicateCandidatesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicate review')),
      body: candidates.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(duplicateCandidatesProvider),
        ),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.content_copy_outlined,
              title: 'No duplicates to review',
              message: 'When the same spend seems to arrive from two channels (e.g. SMS and a later statement import), it shows up here.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(AppSpace.lg),
            itemCount: list.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.lg),
              child: _DuplicatePairCard(list[index]),
            ),
          );
        },
      ),
    );
  }
}

class _DuplicatePairCard extends ConsumerStatefulWidget {
  final DuplicateCandidate candidate;
  const _DuplicatePairCard(this.candidate);

  @override
  ConsumerState<_DuplicatePairCard> createState() => _DuplicatePairCardState();
}

class _DuplicatePairCardState extends ConsumerState<_DuplicatePairCard> {
  bool _busy = false;

  Future<void> _resolve(String resolution, {String? keepTransactionId}) async {
    setState(() => _busy = true);
    try {
      await ref.read(userCardsRepositoryProvider)!.resolveDuplicateCandidate(
            widget.candidate.id,
            resolution: resolution,
            keepTransactionId: keepTransactionId,
          );
      ref.invalidate(duplicateCandidatesProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 14, color: AppColors.ink500),
              const SizedBox(width: 4),
              Expanded(child: Text(candidate.matchReason, style: textTheme.bodySmall)),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: _TxnColumn(
                  txn: candidate.txnA,
                  onKeepThis: _busy ? null : () => _resolve('deleted_one', keepTransactionId: candidate.txnA.id),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: _TxnColumn(
                  txn: candidate.txnB,
                  onKeepThis: _busy ? null : () => _resolve('deleted_one', keepTransactionId: candidate.txnB.id),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Center(
            child: TextButton(
              onPressed: _busy ? null : () => _resolve('kept_both'),
              child: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Keep both — not actually duplicates'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TxnColumn extends StatelessWidget {
  final DuplicateTransactionSummary txn;
  final VoidCallback? onKeepThis;
  const _TxnColumn({required this.txn, required this.onKeepThis});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MoneyText(txn.amount, confidence: Confidence.estimated, style: textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(txn.merchantName ?? 'Spend', style: textTheme.bodySmall, overflow: TextOverflow.ellipsis),
          Text(_sourceLabel(txn.source), style: textTheme.bodySmall?.copyWith(color: AppColors.ink500)),
          if (txn.cardDisplayName != null)
            Text(txn.cardDisplayName!, style: textTheme.bodySmall?.copyWith(color: AppColors.ink500)),
          const SizedBox(height: AppSpace.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onKeepThis,
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: AppSpace.xs)),
              child: const Text('Keep this one', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

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
