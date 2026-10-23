import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../data/api_exception.dart';
import '../../data/merchant_category_rules_repository.dart';

/// Offers the opt-in future-only rule after the existing one-time category
/// review.  The checkbox is deliberately false on every open: changing old
/// transactions and remembering future transactions are separate choices.
Future<MerchantCategoryRule?> showMerchantFutureRuleSheet({
  required BuildContext context,
  required MerchantCategoryRulePreview preview,
  required Future<MerchantCategoryRule> Function() onCreate,
  Future<MerchantCategoryRule> Function(MerchantCategoryRule rule)? onUpdate,
  bool offline = false,
}) {
  return showModalBottomSheet<MerchantCategoryRule>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: BambooInk.paper,
    builder: (sheetContext) => _MerchantFutureRuleSheet(
      preview: preview,
      onCreate: onCreate,
      onUpdate: onUpdate,
      offline: offline,
    ),
  );
}

class _MerchantFutureRuleSheet extends StatefulWidget {
  final MerchantCategoryRulePreview preview;
  final Future<MerchantCategoryRule> Function() onCreate;
  final Future<MerchantCategoryRule> Function(MerchantCategoryRule rule)? onUpdate;
  final bool offline;

  const _MerchantFutureRuleSheet({
    required this.preview,
    required this.onCreate,
    this.onUpdate,
    required this.offline,
  });

  @override
  State<_MerchantFutureRuleSheet> createState() => _MerchantFutureRuleSheetState();
}

class _MerchantFutureRuleSheetState extends State<_MerchantFutureRuleSheet> {
  bool _remember = false;
  bool _saving = false;
  String? _error;
  MerchantCategoryRule? _conflictRule;

  MerchantCategoryRule? get _currentRule =>
      _conflictRule ?? widget.preview.existingRule;

  bool get _hasIdentity =>
      widget.preview.hasUsableIdentity &&
      (widget.preview.canCreate || _currentRule != null);

  Future<void> _save() async {
    if (!_remember || _saving || widget.offline || !_hasIdentity) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final current = _currentRule;
      final result = current == null
          ? await widget.onCreate()
          : widget.onUpdate == null
          ? throw StateError('This future rule needs review before it can change.')
          : await widget.onUpdate!(current);
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (error is MerchantRuleConflictException && error.currentRule != null) {
          _conflictRule = error.currentRule;
        }
        _error = error is MerchantRuleConflictException
            ? error.userMessage
            : userFacingErrorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentRule;
    final hasActive = current?.isActive == true;
    final hasDisabled = current != null && !current.isActive;
    final title = hasActive
        ? 'Update future rule?'
        : hasDisabled
        ? 'Re-enable future rule?'
        : 'Remember for future transactions?';
    final action = hasActive
        ? 'Update future rule'
        : hasDisabled
        ? 'Enable for future'
        : 'Remember for future';
    final explanation = hasActive
        ? 'A future rule already exists for this merchant. Updating it changes only new eligible spends.'
        : hasDisabled
        ? 'This merchant rule is disabled. Re-enabling it affects only new eligible spends.'
        : 'PandaPay can use this category for new eligible spends from this exact merchant.';

    return FractionallySizedBox(
      heightFactor: 0.88,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              children: [
                Text(title, style: BambooFonts.heading(19, color: BambooInk.ink900)),
                const SizedBox(height: 6),
                Text(
                  '${widget.preview.displayMerchantName} · ${widget.preview.categoryName ?? 'this category'}',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink700, weight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(explanation, style: BambooFonts.ui(13, color: BambooInk.ink700)),
                const SizedBox(height: 8),
                _infoCard(
                  icon: Icons.schedule_outlined,
                  text: 'Future only. Existing transactions stay unchanged and can still be handled by the one-time review.',
                ),
                const SizedBox(height: 8),
                _infoCard(
                  icon: widget.preview.matchBasis == MerchantRuleMatchBasis.vpa
                      ? Icons.alternate_email
                      : Icons.storefront_outlined,
                  text: widget.preview.matchBasis == MerchantRuleMatchBasis.vpa
                      ? 'Matches this exact merchant VPA. Other VPAs with the same name are not included.'
                      : 'Matches this exact normalized merchant name. Similar names and marketplaces are not included.',
                ),
                if (widget.preview.examples.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Selected preview transactions', style: BambooFonts.ui(13.5, color: BambooInk.ink900, weight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('These examples show the merchant scope. They are not changed by saving this rule.', style: BambooFonts.ui(12, color: BambooInk.ink500)),
                  const SizedBox(height: 4),
                  for (final example in widget.preview.examples) _exampleTile(example),
                ],
                if (current != null) ...[
                  const SizedBox(height: 10),
                  _infoCard(
                    icon: hasActive ? Icons.sync_problem_outlined : Icons.pause_circle_outline,
                    color: hasActive ? BambooInk.clay : BambooInk.ink500,
                    text: hasActive
                        ? 'Another rule is active for this merchant. Choose Update future rule to make this category explicit.'
                        : 'This rule is disabled. It will not classify future transactions until you enable it.',
                  ),
                ],
                if (widget.offline) ...[
                  const SizedBox(height: 10),
                  _infoCard(
                    icon: Icons.cloud_off_outlined,
                    color: BambooInk.clay,
                    text: 'You are offline. Future rules need a connection so the exact merchant scope can be checked safely.',
                  ),
                ] else if (!_hasIdentity) ...[
                  const SizedBox(height: 10),
                  _infoCard(
                    icon: Icons.info_outline,
                    color: BambooInk.clay,
                    text: 'This transaction does not have a safe exact merchant identity, so a future rule is unavailable.',
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  _infoCard(icon: Icons.error_outline, color: BambooInk.clay, text: _error!),
                ],
                const SizedBox(height: 8),
                Semantics(
                  label: 'Remember this category for future transactions',
                  child: CheckboxListTile(
                    value: _remember,
                    onChanged: _saving || widget.offline || !_hasIdentity
                        ? null
                        : (value) => setState(() => _remember = value == true),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Remember for future transactions'),
                    subtitle: const Text('Off by default. You can disable this later.'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _remember && !_saving && !widget.offline && _hasIdentity
                        ? _save
                        : null,
                    child: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(action),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String text,
    Color color = BambooInk.slate,
  }) => Material(
    color: color.withValues(alpha: 0.09),
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.all(11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: BambooFonts.ui(12.5, color: color))),
        ],
      ),
    ),
  );

  Widget _exampleTile(MerchantRulePreviewTransaction example) {
    final date = example.occurredAt.toLocal().toString().split(' ').first;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.receipt_long_outlined, size: 19),
      title: Text('${example.amountLabel} · $date', style: BambooFonts.ui(13, color: BambooInk.ink900, weight: FontWeight.w600)),
      subtitle: Text(
        [
          if (example.merchantName != null) example.merchantName!,
          if (example.currentCategoryName != null) example.currentCategoryName!,
        ].join(' · '),
        style: BambooFonts.ui(11.5, color: BambooInk.ink500),
      ),
    );
  }
}
