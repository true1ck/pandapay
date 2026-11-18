import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
import '../../../app/providers.dart';
import '../../../data/api_exception.dart';
import '../../../data/spend_reports_repository.dart';
import '../spend_trends_screen.dart' show SpendPeriodSelector;
import 'rewards_filter.dart';
import 'rewards_filter_sheet.dart';
import 'rewards_providers.dart';
import 'rewards_report.dart';
import 'rewards_tabs.dart';

/// The tabs, in order. The names double as the `tab=` deep-link values.
enum RewardsTab {
  summary('Summary'),
  transactions('Transactions'),
  missed('Missed'),
  cards('Cards');

  final String label;
  const RewardsTab(this.label);

  static RewardsTab fromParam(String? value) => switch (value) {
    'transactions' => RewardsTab.transactions,
    'missed' => RewardsTab.missed,
    'cards' || 'by-card' => RewardsTab.cards,
    _ => RewardsTab.summary,
  };
}

/// Insights → Rewards (Bug 16 redesign, docs/rewards-page-redesign-2026-11-18.md).
///
/// One scope for the page (dates, cards, categories) sits above four views of
/// it. Every figure on every tab comes from one [RewardsReport], so they always
/// agree: the Summary total is the sum of the Transactions list, Missed is a
/// subset of it, and Cards splits it by card.
class RewardsScreen extends ConsumerStatefulWidget {
  final RewardsTab initialTab;
  final SpendReportQuery initialQuery;

  const RewardsScreen({
    super.key,
    this.initialTab = RewardsTab.summary,
    this.initialQuery = const SpendReportQuery.preset(SpendPeriod.month),
  });

  @override
  ConsumerState<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends ConsumerState<RewardsScreen>
    with SingleTickerProviderStateMixin {
  late RewardsFilter _filter = RewardsFilter(query: widget.initialQuery);
  late final TabController _tabs = TabController(
    length: RewardsTab.values.length,
    vsync: this,
    initialIndex: widget.initialTab.index,
  );

  /// The Transactions tab's status chip. Kept here so Summary's "not counted"
  /// note can open the tab already narrowed to those spends.
  RewardRowStatus? _status;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _setFilter(RewardsFilter next) {
    if (next == _filter) return;
    setState(() => _filter = next);
  }

  void _openTab(RewardsTab tab, {RewardRowStatus? status}) {
    if (tab == RewardsTab.transactions) setState(() => _status = status);
    _tabs.animateTo(tab.index);
  }

  Future<void> _openFilters(RewardsScope scope, RewardsReport report) async {
    final transactions =
        ref.read(rewardsTransactionsProvider(scope.range)).valueOrNull ??
        const [];
    final wallet =
        ref.read(ownedCardsWithProductProvider).valueOrNull ?? const [];
    final choice = await showRewardsFilterSheet(
      context: context,
      rangeLabel: rewardsRangeLabel(scope.range),
      report: report,
      cardIds: _filter.cardIds,
      categories: _filter.categories,
      preview: (cardIds, categories) => buildRewardsReport(
        transactions: transactions,
        range: scope.range,
        walletCards: wallet,
        cardIds: cardIds,
        categories: categories,
      ),
    );
    if (choice == null || !mounted) return;
    _setFilter(
      _filter.copyWith(cardIds: choice.cardIds, categories: choice.categories),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(clockProvider).now();
    final scope = RewardsScope.of(_filter, now);
    final report = ref.watch(rewardsReportProvider(scope));
    final loaded = report.valueOrNull;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Rewards',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: Column(
          children: [
            SpendPeriodSelector(
              key: const Key('rewards-period'),
              selected: _filter.query,
              filtersActive: _filter.narrowed,
              filterCount: _filter.cardIds.length + _filter.categories.length,
              onFilters: loaded == null
                  ? null
                  : () => _openFilters(scope, loaded),
              onChanged: (query) => _setFilter(_filter.copyWith(query: query)),
              rangeNote:
                  'Rewards cover purchases paid by a credit card in your wallet.',
            ),
            if (_filter.narrowed)
              _ActiveFilters(
                filter: _filter,
                cardLabel: (id) => loaded?.cardLabel(id) ?? 'Card',
                onChanged: _setFilter,
              ),
            Container(
              alignment: Alignment.centerLeft,
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: BambooInk.hairlineOnPaper),
                ),
              ),
              child: TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                labelColor: BambooInk.slate,
                unselectedLabelColor: BambooInk.ink500,
                indicatorColor: BambooInk.slate,
                labelStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                unselectedLabelStyle: BambooFonts.ui(
                  13.5,
                  weight: FontWeight.w500,
                ),
                tabs: [
                  for (final tab in RewardsTab.values)
                    Tab(
                      key: Key('rewards-tab-${tab.name}'),
                      text: _tabLabel(tab, loaded),
                    ),
                ],
              ),
            ),
            Expanded(
              child: report.when(
                skipLoadingOnReload: true,
                skipLoadingOnRefresh: true,
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => ErrorState(
                  message: userFacingErrorMessage(error),
                  error: error,
                  onRetry: () =>
                      ref.invalidate(rewardsTransactionsProvider(scope.range)),
                ),
                data: (data) => TabBarView(
                  controller: _tabs,
                  children: [
                    RewardsSummaryTab(
                      report: data,
                      filter: _filter,
                      onFilterChanged: _setFilter,
                      onOpenTab: _openTab,
                    ),
                    RewardsTransactionsTab(
                      report: data,
                      filter: _filter,
                      status: _status,
                      onStatusChanged: (status) =>
                          setState(() => _status = status),
                      onFilterChanged: _setFilter,
                    ),
                    RewardsMissedTab(
                      report: data,
                      filter: _filter,
                      onFilterChanged: _setFilter,
                    ),
                    RewardsCardsTab(
                      report: data,
                      filter: _filter,
                      onFilterChanged: _setFilter,
                      onOpenTab: _openTab,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _tabLabel(RewardsTab tab, RewardsReport? report) {
    if (report == null) return tab.label;
    return switch (tab) {
      RewardsTab.missed when report.missedCount > 0 =>
        '${tab.label} · ${report.missedCount}',
      _ => tab.label,
    };
  }
}

/// The cards and categories that narrow the page, each removable on its own.
class _ActiveFilters extends StatelessWidget {
  final RewardsFilter filter;
  final String Function(String cardId) cardLabel;
  final ValueChanged<RewardsFilter> onChanged;

  const _ActiveFilters({
    required this.filter,
    required this.cardLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        key: const Key('rewards-active-filters'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.xs,
          AppSpace.lg,
          AppSpace.xs,
        ),
        children: [
          for (final id in filter.cardIds)
            _RemovableChip(
              label: cardLabel(id),
              onRemove: () => onChanged(
                filter.copyWith(cardIds: {...filter.cardIds}..remove(id)),
              ),
            ),
          for (final category in filter.categories)
            _RemovableChip(
              label: category,
              onRemove: () => onChanged(
                filter.copyWith(
                  categories: {...filter.categories}..remove(category),
                ),
              ),
            ),
          TextButton(
            key: const Key('rewards-clear-filters'),
            onPressed: () => onChanged(
              filter.copyWith(cardIds: const {}, categories: const {}),
            ),
            style: TextButton.styleFrom(
              foregroundColor: BambooInk.ink900,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
              minimumSize: const Size(0, 36),
              textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
            ),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }
}

class _RemovableChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;

  const _RemovableChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: BambooInk.wash,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onRemove,
          child: Semantics(
            button: true,
            label: 'Remove $label',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 170),
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        12.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: BambooInk.ink700,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
