import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/user_cards_repository.dart';

/// Presents the server-owned related-transaction snapshot after the original
/// category edit has been saved. The data models live in the repository layer
/// so preview IDs, selection tiers, and row versions cannot be reconstructed
/// by the UI.
Future<CategoryBulkApplyResult?> showCategoryBulkReviewSheet({
  required BuildContext context,
  required RelatedCategoryPreview preview,
  required Future<CategoryBulkApplyResult> Function(Set<String> ids) onApply,
  Future<RelatedCategoryPreview> Function()? onRetry,
}) {
  return showModalBottomSheet<CategoryBulkApplyResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: BambooInk.paper,
    builder: (sheetContext) => _CategoryBulkReviewSheet(
      preview: preview,
      onApply: onApply,
      onRetry: onRetry,
    ),
  );
}

class _CategoryBulkReviewSheet extends StatefulWidget {
  final RelatedCategoryPreview preview;
  final Future<CategoryBulkApplyResult> Function(Set<String> ids) onApply;
  final Future<RelatedCategoryPreview> Function()? onRetry;

  const _CategoryBulkReviewSheet({
    required this.preview,
    required this.onApply,
    this.onRetry,
  });

  @override
  State<_CategoryBulkReviewSheet> createState() =>
      _CategoryBulkReviewSheetState();
}

class _CategoryBulkReviewSheetState extends State<_CategoryBulkReviewSheet> {
  late RelatedCategoryPreview _preview = widget.preview;
  late Set<String> _selected = _defaultSelection(widget.preview);
  bool _applying = false;
  bool _retrying = false;
  String? _error;

  static Set<String> _defaultSelection(RelatedCategoryPreview preview) => {
    for (final candidate in preview.candidates)
      if (candidate.isDefaultSelected && candidate.isSelectable) candidate.id,
  };

  void _replacePreview(RelatedCategoryPreview preview) {
    setState(() {
      _preview = preview;
      _selected = _defaultSelection(preview);
      _error = null;
    });
  }

  Future<void> _retry() async {
    final onRetry = widget.onRetry;
    if (onRetry == null) return;
    setState(() {
      _retrying = true;
      _error = null;
    });
    try {
      _replacePreview(await onRetry());
    } catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _apply() async {
    if (_selected.isEmpty || _applying) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final result = await widget.onApply(Set.unmodifiable(_selected));
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _applying = false;
          _error = _messageFor(error);
        });
      }
    }
  }

  String _messageFor(Object error) => error is CategoryBulkConflictException
      ? error.userMessage
      : 'Could not apply this category. Check your connection and try again.';

  @override
  Widget build(BuildContext context) {
    final selectedCount = _selected.length;
    final selectable = _preview.candidates
        .where((item) => item.isSelectable)
        .toList(growable: false);
    final manualReview = _preview.candidates.any(
      (item) => item.selectionTier == RelatedTransactionSelectionTier.manualReview,
    );
    final ineligible = _preview.candidates.any(
      (item) => item.selectionTier == RelatedTransactionSelectionTier.ineligible,
    );
    final targetLabel = _preview.targetCategoryName ?? 'this category';
    final merchantLabel = _preview.matchBasis == RelatedTransactionMatchBasis.vpa
        ? 'Matching UPI transactions'
        : 'Matching merchant transactions';
    return FractionallySizedBox(
      heightFactor: 0.9,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Apply $targetLabel to more?',
                  style: BambooFonts.heading(19, color: BambooInk.ink900),
                ),
                const SizedBox(height: 5),
                Text(
                  '$merchantLabel · ${_preview.totalCandidateCount} matching transactions',
                  style: BambooFonts.ui(13, color: BambooInk.ink500),
                ),
                if (_preview.overflow) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Showing ${_preview.candidates.length} of ${_preview.totalCandidateCount}. Narrow the date range to apply to more.',
                    style: BambooFonts.ui(12.5, color: BambooInk.clay),
                  ),
                ],
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Material(
                color: BambooInk.clay.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.info_outline, color: BambooInk.clay),
                  title: Text(
                    _error!,
                    style: BambooFonts.ui(12.5, color: BambooInk.clay),
                  ),
                  trailing: widget.onRetry == null
                      ? null
                      : TextButton(
                          onPressed: _retrying ? null : _retry,
                          child: _retrying
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Refresh'),
                        ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                Text(
                  '$selectedCount selected',
                  style: BambooFonts.ui(
                    13.5,
                    color: BambooInk.ink700,
                    weight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _applying || selectable.isEmpty
                      ? null
                      : () => setState(
                            () => _selected = {
                              for (final item in selectable) item.id,
                            },
                          ),
                  child: const Text('Select all'),
                ),
                TextButton(
                  onPressed: _applying || _selected.isEmpty
                      ? null
                      : () => setState(() => _selected = {}),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [
                for (final candidate in _preview.candidates)
                  _candidateTile(candidate),
                if (manualReview)
                  _sectionHint('Manual review rows start unchecked'),
                if (ineligible)
                  _sectionHint('Some rows are unavailable for bulk editing'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _applying
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _selected.isEmpty || _applying ? null : _apply,
                    child: _applying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text('Apply to $selectedCount'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHint(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(text, style: BambooFonts.ui(12, color: BambooInk.ink500)),
      );

  Widget _candidateTile(RelatedTransactionCandidate candidate) {
    final checked = _selected.contains(candidate.id);
    final disabled = !candidate.isSelectable || _applying;
    final localDate = candidate.occurredAt.toLocal().toString().split(' ').first;
    return CheckboxListTile(
      value: checked,
      onChanged: disabled
          ? null
          : (value) => setState(() {
                if (value == true) {
                  _selected.add(candidate.id);
                } else {
                  _selected.remove(candidate.id);
                }
              }),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
        '${candidate.amount.format(hidePaise: true)} · $localDate',
        style: BambooFonts.ui(
          14,
          color: disabled ? BambooInk.ink500 : BambooInk.ink900,
          weight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        [
          candidate.currentCategoryLabel,
          if (candidate.paymentSource != null) candidate.paymentSource!,
          if (candidate.reason != null) candidate.reason!,
        ].join(' · '),
        style: BambooFonts.ui(12, color: BambooInk.ink500),
      ),
    );
  }
}
