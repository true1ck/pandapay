import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
import '../../../main.dart' show MoneyText;
import 'rewards_report.dart';

/// The cards and categories a person picked in the filter sheet.
typedef RewardsFilterChoice = ({Set<String> cardIds, Set<String> categories});

/// Opens "Filter rewards". [preview] works the page out for a draft choice so
/// the footer can say what Show results will show before it is pressed (the
/// range's transactions are already loaded, so this never fetches).
Future<RewardsFilterChoice?> showRewardsFilterSheet({
  required BuildContext context,
  required String rangeLabel,
  required RewardsReport report,
  required Set<String> cardIds,
  required Set<String> categories,
  required RewardsReport Function(Set<String> cardIds, Set<String> categories)
  preview,
}) {
  return showModalBottomSheet<RewardsFilterChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: BambooInk.paper,
    builder: (_) => RewardsFilterSheet(
      rangeLabel: rangeLabel,
      cardOptions: report.cardOptions,
      categoryOptions: report.categoryOptions,
      initialCardIds: cardIds,
      initialCategories: categories,
      preview: preview,
    ),
  );
}

class RewardsFilterSheet extends StatefulWidget {
  final String rangeLabel;
  final List<RewardFilterOption> cardOptions;
  final List<RewardFilterOption> categoryOptions;
  final Set<String> initialCardIds;
  final Set<String> initialCategories;
  final RewardsReport Function(Set<String> cardIds, Set<String> categories)
  preview;

  const RewardsFilterSheet({
    super.key,
    required this.rangeLabel,
    required this.cardOptions,
    required this.categoryOptions,
    required this.initialCardIds,
    required this.initialCategories,
    required this.preview,
  });

  @override
  State<RewardsFilterSheet> createState() => _RewardsFilterSheetState();
}

class _RewardsFilterSheetState extends State<RewardsFilterSheet> {
  late Set<String> _cardIds = {...widget.initialCardIds};
  late Set<String> _categories = {...widget.initialCategories};
  late RewardsReport _preview = widget.preview(_cardIds, _categories);

  void _update(VoidCallback change) {
    setState(() {
      change();
      _preview = widget.preview(_cardIds, _categories);
    });
  }

  void _toggle(Set<String> set, String key) =>
      _update(() => set.contains(key) ? set.remove(key) : set.add(key));

  @override
  Widget build(BuildContext context) {
    final spends = _preview.rows.length;
    final footer = Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.md,
        AppSpace.xl,
        AppSpace.xs,
      ),
      decoration: const BoxDecoration(
        color: BambooInk.paper,
        border: Border(top: BorderSide(color: BambooInk.hairlineOnPaper)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  '$spends card ${spends == 1 ? 'spend' : 'spends'} · ',
                  key: const Key('rewards-filter-preview-count'),
                  style: BambooFonts.ui(14, color: BambooInk.ink900),
                ),
              ),
              MoneyText(
                _preview.earned,
                confidence: Confidence.estimated,
                showConfidenceIcon: false,
                hidePaise: true,
                prefix: '≈ ',
                suffix: ' earned',
                style: BambooFonts.ui(
                  14,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('rewards-filter-apply'),
              onPressed: () => Navigator.pop<RewardsFilterChoice>(context, (
                cardIds: {..._cardIds},
                categories: {..._categories},
              )),
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.onSlate,
                minimumSize: const Size.fromHeight(52),
                textStyle: BambooFonts.ui(16, weight: FontWeight.w700),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text('Show results'),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              foregroundColor: BambooInk.ink700,
              minimumSize: const Size(0, 44),
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  0,
                  AppSpace.xl,
                  AppSpace.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Filter rewards',
                            style: BambooFonts.heading(
                              20,
                              color: BambooInk.ink900,
                            ),
                          ),
                        ),
                        TextButton(
                          key: const Key('rewards-filter-reset'),
                          onPressed: _cardIds.isEmpty && _categories.isEmpty
                              ? null
                              : () => _update(() {
                                  _cardIds = {};
                                  _categories = {};
                                }),
                          style: TextButton.styleFrom(
                            foregroundColor: BambooInk.ink900,
                            minimumSize: const Size(44, 44),
                            textStyle: BambooFonts.ui(
                              14,
                              weight: FontWeight.w700,
                            ),
                          ),
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                    Text(
                      'Applies to every tab · ${widget.rangeLabel}',
                      style: BambooFonts.ui(13, color: BambooInk.ink500),
                    ),
                    const SizedBox(height: AppSpace.xl),
                    _SheetLabel('Cards'),
                    if (widget.cardOptions.isEmpty)
                      _EmptyLine('No wallet cards yet.')
                    else
                      Wrap(
                        spacing: AppSpace.sm,
                        runSpacing: AppSpace.sm,
                        children: [
                          RewardsSelectChip(
                            label: 'All cards',
                            selected: _cardIds.isEmpty,
                            onTap: () => _update(() => _cardIds = {}),
                          ),
                          for (final option in widget.cardOptions)
                            RewardsSelectChip(
                              label: option.label,
                              count: option.spends,
                              selected: _cardIds.contains(option.key),
                              onTap: () => _toggle(_cardIds, option.key),
                            ),
                        ],
                      ),
                    const SizedBox(height: AppSpace.xl),
                    _SheetLabel('Categories'),
                    if (widget.categoryOptions.isEmpty)
                      _EmptyLine('No card spends in this range.')
                    else
                      Wrap(
                        spacing: AppSpace.sm,
                        runSpacing: AppSpace.sm,
                        children: [
                          RewardsSelectChip(
                            label: 'All categories',
                            selected: _categories.isEmpty,
                            onTap: () => _update(() => _categories = {}),
                          ),
                          for (final option in widget.categoryOptions)
                            RewardsSelectChip(
                              label: option.label,
                              count: option.spends,
                              selected: _categories.contains(option.key),
                              onTap: () => _toggle(_categories, option.key),
                            ),
                        ],
                      ),
                    const SizedBox(height: AppSpace.lg),
                    Text(
                      'To change the dates, use the date button above the tabs.',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
            ),
            footer,
          ],
        ),
      ),
    );
  }
}

/// A selectable pill: slate when on, glass with a hairline when off. Used by
/// the filter sheet and the Transactions tab's status row.
class RewardsSelectChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const RewardsSelectChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    final text = count == null ? label : '$label · $count';
    return Semantics(
      selected: selected,
      button: true,
      child: Pressable(
        onTap: onTap,
        semanticLabel: text,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? BambooInk.slate : BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: selected ? BambooInk.slate : BambooInk.hairlineOnPaper,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                const Icon(
                  Icons.check_rounded,
                  size: 15,
                  color: BambooInk.lime,
                ),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(
                    13,
                    weight: FontWeight.w600,
                    color: selected ? BambooInk.onSlate : BambooInk.ink900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Text(
      text.toUpperCase(),
      style: BambooFonts.ui(
        12,
        weight: FontWeight.w700,
        color: BambooInk.ink500,
      ).copyWith(letterSpacing: 1.1),
    ),
  );
}

class _EmptyLine extends StatelessWidget {
  final String text;
  const _EmptyLine(this.text);

  @override
  Widget build(BuildContext context) =>
      Text(text, style: BambooFonts.ui(13, color: BambooInk.ink500));
}
