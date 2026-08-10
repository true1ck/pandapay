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
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Duplicate review', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
        child: candidates.when(
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
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 14, color: BambooInk.ink500),
              const SizedBox(width: 4),
              Expanded(child: Text(candidate.matchReason, style: BambooFonts.ui(12.5, color: BambooInk.ink500))),
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
              style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
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
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MoneyText(txn.amount, confidence: Confidence.estimated, style: BambooFonts.money(14, color: BambooInk.ink900)),
          const SizedBox(height: 2),
          Text(txn.merchantName ?? 'Spend', style: BambooFonts.ui(12.5, color: BambooInk.ink900), overflow: TextOverflow.ellipsis),
          Text(_sourceLabel(txn.source), style: BambooFonts.ui(12, color: BambooInk.ink500)),
          if (txn.cardDisplayName != null)
            Text(txn.cardDisplayName!, style: BambooFonts.ui(12, color: BambooInk.ink500)),
          const SizedBox(height: AppSpace.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onKeepThis,
              style: OutlinedButton.styleFrom(
                foregroundColor: BambooInk.ink900,
                side: const BorderSide(color: BambooInk.hairlineOnPaper),
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('Keep this one', style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.ink900)),
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
