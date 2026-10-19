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

/// D5 Duplicate Review. Recommended keep-side choices are local UI state until
/// the user confirms the merge.
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
        title: Text('Duplicate review', style: BambooFonts.heading(19)),
      ),
      body: AppBackground(
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
                message: 'When the same spend seems to arrive from two channels, it shows up here.',
              );
            }
            return _DuplicateReviewList(candidates: list);
          },
        ),
      ),
    );
  }
}

class _DuplicateReviewList extends StatefulWidget {
  const _DuplicateReviewList({required this.candidates});
  final List<DuplicateCandidate> candidates;

  @override
  State<_DuplicateReviewList> createState() => _DuplicateReviewListState();
}

class _DuplicateReviewListState extends State<_DuplicateReviewList> {
  final Map<String, String> _keptTransactions = {};
  final Set<String> _keptBoth = {};
  String _filter = 'All';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _autoSelectRecommended(widget.candidates);
  }

  void _autoSelectRecommended(List<DuplicateCandidate> candidates) {
    for (final candidate in candidates) {
      if (!_keptBoth.contains(candidate.id)) {
        _keptTransactions.putIfAbsent(candidate.id, () => _recommendedTransaction(candidate).id);
      }
    }
  }

  DuplicateTransactionSummary _recommendedTransaction(DuplicateCandidate candidate) {
    // Prefer the bank/statement record, which normally carries better data;
    // use the more complete side for other channel combinations.
    final aRank = _sourceRank(candidate.txnA.source);
    final bRank = _sourceRank(candidate.txnB.source);
    if (aRank != bRank) return aRank > bRank ? candidate.txnA : candidate.txnB;
    final aCompleteness = (candidate.txnA.merchantName?.trim().isNotEmpty == true ? 1 : 0) +
        (candidate.txnA.cardDisplayName?.trim().isNotEmpty == true ? 1 : 0);
    final bCompleteness = (candidate.txnB.merchantName?.trim().isNotEmpty == true ? 1 : 0) +
        (candidate.txnB.cardDisplayName?.trim().isNotEmpty == true ? 1 : 0);
    if (aCompleteness != bCompleteness) return aCompleteness > bCompleteness ? candidate.txnA : candidate.txnB;
    return candidate.txnA;
  }

  int _sourceRank(String source) => switch (source) {
        'statement' || 'imported' => 3,
        'email' => 2,
        'sms' || 'sms_bulk' => 1,
        _ => 0,
      };

  @override
  void didUpdateWidget(covariant _DuplicateReviewList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = widget.candidates.map((candidate) => candidate.id).toSet();
    _keptTransactions.removeWhere((key, _) => !ids.contains(key));
    _keptBoth.removeWhere((key) => !ids.contains(key));
    _autoSelectRecommended(widget.candidates);
  }

  bool _isExactAmount(DuplicateCandidate candidate) =>
      candidate.txnA.amount == candidate.txnB.amount;

  bool _isCrossChannel(DuplicateCandidate candidate) =>
      candidate.txnA.source != candidate.txnB.source;

  List<DuplicateCandidate> get _visibleCandidates => widget.candidates.where((candidate) {
        return switch (_filter) {
          'Exact amount' => _isExactAmount(candidate),
          'Cross-channel' => _isCrossChannel(candidate),
          _ => true,
        };
      }).toList();

  double get _overlap => widget.candidates.fold<double>(
        0,
        (sum, candidate) => sum + candidate.txnA.amount.rupees,
      );

  int get _resolvedCount => _keptTransactions.length + _keptBoth.length;
  bool get _allAutoSelected {
    if (_keptBoth.isNotEmpty ||
        _keptTransactions.length != widget.candidates.length) {
      return false;
    }
    return widget.candidates.every(
      (candidate) =>
          _keptTransactions[candidate.id] ==
          _recommendedTransaction(candidate).id,
    );
  }

  void _toggleAutoSelect() {
    setState(() {
      if (_allAutoSelected) {
        _keptTransactions.clear();
        _keptBoth
          ..clear()
          ..addAll(widget.candidates.map((candidate) => candidate.id));
      } else {
        _keptBoth.clear();
        _keptTransactions
          ..clear()
          ..addEntries(widget.candidates.map((candidate) => MapEntry(
                candidate.id,
                _recommendedTransaction(candidate).id,
              )));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleCandidates;
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          decoration: const BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            border: Border(bottom: BorderSide(color: BambooInk.hairlineOnPaper)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.hourglass_bottom_rounded, size: 14, color: Color(0xFF986300)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: BambooInk.rankBadgeBg, borderRadius: BorderRadius.circular(8)),
                child: Text('${widget.candidates.length} pairs', style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.rankBadgeInk)),
              ),
            ]),
            const SizedBox(height: 5),
            Text('₹${_overlap.toStringAsFixed(2)} potential overlap detected', style: BambooFonts.ui(13, color: BambooInk.ink500)),
            const SizedBox(height: 12),
            Semantics(
              container: true,
              button: true,
              toggled: _allAutoSelected,
              label: 'Auto-select recommended transactions',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _toggleAutoSelect,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Icon(
                      _allAutoSelected
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 21,
                      color: BambooInk.jade,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Auto-select recommended (${_keptTransactions.length})',
                        style: BambooFonts.ui(14, weight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: _toggleAutoSelect,
                      child: Text(
                        _allAutoSelected ? 'Keep all separate' : 'Auto-select all',
                        style: BambooFonts.ui(13, color: BambooInk.jade),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _FilterChip(label: 'All', count: widget.candidates.length, selected: _filter == 'All', onTap: () => setState(() => _filter = 'All')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Exact amount', count: widget.candidates.where(_isExactAmount).length, selected: _filter == 'Exact amount', onTap: () => setState(() => _filter = 'Exact amount')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Cross-channel', count: widget.candidates.where(_isCrossChannel).length, selected: _filter == 'Cross-channel', onTap: () => setState(() => _filter = 'Cross-channel')),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final candidate = visible[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _DuplicatePairCard(
                  key: ValueKey(candidate.id),
                  candidate: candidate,
                  keptTransactionId: _keptTransactions[candidate.id],
                  keptBoth: _keptBoth.contains(candidate.id),
                  onKeep: (id) => setState(() {
                    _keptTransactions[candidate.id] = id;
                    _keptBoth.remove(candidate.id);
                  }),
                  onKeepBoth: () => setState(() {
                    _keptBoth.add(candidate.id);
                    _keptTransactions.remove(candidate.id);
                  }),
                ),
              );
            },
          ),
        ),
        _ReviewFooter(
          total: widget.candidates.length,
          resolved: _resolvedCount,
          mergeCount: _keptTransactions.length,
          overlap: _overlap,
          onConfirm: _keptTransactions.isNotEmpty && !_busy
              ? () => _confirmAndMerge(context)
              : null,
          onDismiss: _busy ? null : () => _dismissAll(context),
        ),
      ],
    );
  }

  Future<void> _confirmAndMerge(BuildContext context) async {
    final ref = ProviderScope.containerOf(context, listen: false);
    final repository = ref.read(userCardsRepositoryProvider)!;
    setState(() => _busy = true);
    var alreadyResolved = 0;
    try {
      for (final candidate in widget.candidates) {
        final keptId = _keptTransactions[candidate.id];
        try {
          if (keptId != null) {
            await repository.resolveDuplicateCandidate(
              candidate.id,
              resolution: 'merged',
              keepTransactionId: keptId,
            );
          } else if (_keptBoth.contains(candidate.id)) {
            await repository.resolveDuplicateCandidate(
              candidate.id,
              resolution: 'kept_both',
            );
          }
        } catch (error) {
          if (_isAlreadyResolved(error)) {
            alreadyResolved++;
            continue;
          }
          rethrow;
        }
      }
      ref.invalidate(duplicateCandidatesProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      if (context.mounted) {
        await _showResolutionDialog(
          context,
          alreadyResolved: alreadyResolved > 0,
          count: alreadyResolved,
        );
      }
    } catch (error) {
      if (context.mounted) {
        await _showResolutionError(context, error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismissAll(BuildContext context) async {
    final ref = ProviderScope.containerOf(context, listen: false);
    final repository = ref.read(userCardsRepositoryProvider)!;
    setState(() => _busy = true);
    var alreadyResolved = 0;
    try {
      for (final candidate in widget.candidates) {
        try {
          await repository.resolveDuplicateCandidate(
            candidate.id,
            resolution: 'kept_both',
          );
        } catch (error) {
          if (_isAlreadyResolved(error)) {
            alreadyResolved++;
            continue;
          }
          rethrow;
        }
      }
      ref.invalidate(duplicateCandidatesProvider);
      ref.invalidate(userCardsProvider);
      ref.invalidate(myCardsProvider);
      if (context.mounted) {
        await _showResolutionDialog(
          context,
          alreadyResolved: alreadyResolved > 0,
          count: alreadyResolved,
        );
      }
    } catch (error) {
      if (context.mounted) {
        await _showResolutionError(context, error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isAlreadyResolved(Object error) {
    if (error is! ApiException || error.statusCode != 409) return false;
    final code = error.errorCode?.toLowerCase() ?? '';
    return code.startsWith('already resolved') ||
        error.userMessage.toLowerCase().contains('already resolved');
  }

  Future<void> _showResolutionDialog(
    BuildContext context, {
    required bool alreadyResolved,
    int count = 0,
  }) async {
    if (!context.mounted) return;
    final title = alreadyResolved ? 'Already resolved' : 'Review resolved';
    final message = alreadyResolved
        ? '${count == 1 ? 'This duplicate was' : '$count duplicates were'} already resolved. The review list has been refreshed.'
        : 'Your duplicate choices have been saved successfully.';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _goToInsights(context);
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showResolutionError(BuildContext context, Object error) async {
    if (_isAlreadyResolved(error)) {
      await _showResolutionDialog(context, alreadyResolved: true, count: 1);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Could not save changes'),
        content: Text(userFacingErrorMessage(error)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _goToInsights(BuildContext context) {
    if (!context.mounted) return;
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      context.go('/insights');
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.count, required this.selected, required this.onTap});
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ActionChip(
        onPressed: onTap,
        label: Text('$label ($count)', style: BambooFonts.ui(12.5, color: selected ? BambooInk.onSlate : BambooInk.ink700)),
        backgroundColor: selected ? BambooInk.slate : BambooInk.paper,
        side: BorderSide(color: selected ? BambooInk.slate : BambooInk.hairlineOnPaper),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      );
}

class _DuplicatePairCard extends StatelessWidget {
  const _DuplicatePairCard({super.key, required this.candidate, required this.keptTransactionId, required this.keptBoth, required this.onKeep, required this.onKeepBoth});
  final DuplicateCandidate candidate;
  final String? keptTransactionId;
  final bool keptBoth;
  final ValueChanged<String> onKeep;
  final VoidCallback onKeepBoth;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BambooInk.hairlineOnPaper),
        boxShadow: const [BoxShadow(color: Color(0x0A2B313A), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_rounded, size: 16, color: BambooInk.ink500),
          const SizedBox(width: 8),
          Expanded(child: Text(candidate.matchReason, style: BambooFonts.ui(12.5, color: BambooInk.ink700))),
          const SizedBox(width: 8),
          Text(keptBoth ? 'Not duplicate' : keptTransactionId == null ? 'Review' : 'Not duplicate', style: BambooFonts.ui(11.5, color: BambooInk.ink500)),
        ]),
        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1, color: BambooInk.hairlineOnPaper)),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _TxnCandidateCard(txn: candidate.txnA, label: 'CANDIDATE A', selected: keptTransactionId == candidate.txnA.id, onKeep: () => onKeep(candidate.txnA.id))),
          const SizedBox(width: 10),
          Expanded(child: _TxnCandidateCard(txn: candidate.txnB, label: 'CANDIDATE B', selected: keptTransactionId == candidate.txnB.id, onKeep: () => onKeep(candidate.txnB.id))),
        ]),
        const SizedBox(height: 10),
        TextButton(
          onPressed: onKeepBoth,
          style: TextButton.styleFrom(foregroundColor: BambooInk.jade, padding: const EdgeInsets.symmetric(vertical: 8)),
                child: Text(keptBoth ? '✓ Kept both — not actually duplicates' : 'Keep both — not actually duplicates', textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}

class _TxnCandidateCard extends StatelessWidget {
  const _TxnCandidateCard({required this.txn, required this.label, required this.selected, required this.onKeep});
  final DuplicateTransactionSummary txn;
  final String label;
  final bool selected;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final border = selected ? BambooInk.jade : BambooInk.hairlineOnPaper;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, ${selected ? 'selected' : 'not selected'}',
      child: InkWell(
        onTap: onKeep,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFF8FFFB) : BambooInk.paperMuted,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border, width: selected ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: BambooFonts.ui(11.5, weight: FontWeight.w700, color: selected ? BambooInk.jade : BambooInk.ink500).copyWith(letterSpacing: 0.6))),
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 19, color: selected ? BambooInk.jade : BambooInk.ink500),
        ]),
        const SizedBox(height: 9),
        MoneyText(txn.amount, confidence: Confidence.estimated, style: BambooFonts.money(17)),
        const SizedBox(height: 5),
        Text(txn.merchantName ?? 'Spend', maxLines: 2, overflow: TextOverflow.ellipsis, style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.ink900)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: selected ? const Color(0xFFD9F6EA) : const Color(0xFFECEBE7), borderRadius: BorderRadius.circular(6)),
          child: Text(_sourceLabel(txn.source), maxLines: 1, overflow: TextOverflow.ellipsis, style: BambooFonts.ui(10.5, weight: FontWeight.w600, color: selected ? const Color(0xFF005D45) : BambooInk.ink700)),
        ),
        const SizedBox(height: 6),
        Text(txn.cardDisplayName ?? _formatDate(txn.occurredAt), maxLines: 1, overflow: TextOverflow.ellipsis, style: BambooFonts.ui(11, color: BambooInk.ink500)),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: selected
              ? FilledButton.icon(onPressed: onKeep, icon: const Icon(Icons.check, size: 16), label: const Text('Keep this one ✓'), style: FilledButton.styleFrom(backgroundColor: BambooInk.jade, disabledBackgroundColor: BambooInk.jade, disabledForegroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), textStyle: BambooFonts.ui(11, weight: FontWeight.w700)))
              : OutlinedButton(onPressed: onKeep, style: OutlinedButton.styleFrom(foregroundColor: BambooInk.ink900, side: const BorderSide(color: BambooInk.hairlineOnPaper), padding: const EdgeInsets.symmetric(vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), child: Text('Keep this one', style: BambooFonts.ui(11, weight: FontWeight.w600))),
        ),
          ]),
        ),
      ),
    );
  }

  static String _sourceLabel(String source) => switch (source) {
        'manual' => 'Manual entry',
        'sms' => 'SMS alert',
        'email' => 'Email alert',
        'statement' => 'Statement import',
        'sms_bulk' => 'SMS backup import',
        'imported' => 'Imported',
        _ => source,
      };

  static String _formatDate(DateTime date) => '${date.day}/${date.month}/${date.year}';
}

class _ReviewFooter extends StatelessWidget {
  const _ReviewFooter({required this.total, required this.resolved, required this.mergeCount, required this.overlap, required this.onConfirm, required this.onDismiss});
  final int total;
  final int resolved;
  final int mergeCount;
  final double overlap;
  final VoidCallback? onConfirm;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
        decoration: BoxDecoration(color: BambooInk.paper, border: const Border(top: BorderSide(color: BambooInk.hairlineOnPaper)), boxShadow: const [BoxShadow(color: Color(0x0D2B313A), blurRadius: 12, offset: Offset(0, -3))]),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(Icons.circle, size: 10, color: onConfirm == null ? BambooInk.ink500 : BambooInk.jade),
              const SizedBox(width: 8),
              Expanded(child: Text('Ready to merge: $resolved of $total pairs resolved', style: BambooFonts.ui(12.5, color: BambooInk.ink900))),
              Text('Overlaps: ₹${overlap.toStringAsFixed(2)}', style: BambooFonts.ui(12, color: BambooInk.ink500)),
            ]),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: onConfirm,
              icon: const Icon(Icons.check, size: 19),
              label: Text('Confirm & Merge $mergeCount Items'),
              style: FilledButton.styleFrom(backgroundColor: BambooInk.jade, disabledBackgroundColor: BambooInk.ink500, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), textStyle: BambooFonts.ui(16, weight: FontWeight.w700)),
            )),
            TextButton(onPressed: onDismiss, child: Text('Dismiss & keep all as distinct expenses', style: BambooFonts.ui(13, color: BambooInk.ink500))),
          ]),
        ),
      );

}
