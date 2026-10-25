import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/display_text.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import 'card_actions_screen.dart';
import 'card_visual.dart';
import '../insights/credit_utilization_ui.dart';
import '../insights/spending_visuals.dart';
import '../insights/spend_trends_screen.dart'
    show SpendPeriodSelector, SpendingMixCard, spendingMixCategoryKey;
import 'autopay_issuer_links.dart';
import 'benefit_detail_screen.dart';
import 'card_summary.dart';
import '../insights/payments_due_screen.dart'
    show DuePayment, paymentsDueProvider;
import '../insights/lounge_access_screen.dart' show isInCurrentLoungeWindow;
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

const _assumedGracePeriodDays =
    20; // matches billing_float_screen.dart's own assumption

/// Period selection is shared by the mix and performance sections for one
/// card, without changing the global Spending screen's selection.
final cardDetailSpendQueryProvider =
    StateProvider.family<SpendReportQuery, String>(
      (ref, userCardId) => const SpendReportQuery.preset(SpendPeriod.month),
    );

String _normalizedSpendCategoryLabel(String rawLabel) {
  final normalized = rawLabel.trim().replaceAll(RegExp(r'\s+'), ' ');
  final lower = normalized.toLowerCase();
  if (normalized.isEmpty ||
      lower == 'uncategorized' ||
      lower == 'unclassified' ||
      lower == 'unknown' ||
      lower == 'others' ||
      lower == 'other') {
    return 'Other';
  }
  return normalized;
}

List<SpendBreakdownRow> _aggregateCardCategoryRows(
  List<CardCategorySpendRow> rawRows,
  String userCardId,
) {
  final filtered = rawRows.where(
    (r) => r.cardId == userCardId && r.total.paise > 0 && r.txnCount > 0,
  );
  final map =
      <
        String,
        ({String label, Money total, int txnCount, String? categoryId})
      >{};

  for (final r in filtered) {
    final label = _normalizedSpendCategoryLabel(r.categoryName);
    // Report rows may arrive both with and without a category ID. The label
    // is the stable user-facing identity, so keying by it prevents duplicate
    // rows such as "Other" / "Uncategorized" or ID/name variants.
    final key = label.toLowerCase();

    if (map.containsKey(key)) {
      final existing = map[key]!;
      map[key] = (
        label: existing.label,
        total: existing.total + r.total,
        txnCount: existing.txnCount + r.txnCount,
        categoryId: existing.categoryId ?? r.categoryId,
      );
    } else {
      map[key] = (
        label: label,
        total: r.total,
        txnCount: r.txnCount,
        categoryId: r.categoryId,
      );
    }
  }

  return map.values
      .map(
        (v) => SpendBreakdownRow(
          label: v.label,
          total: v.total,
          txnCount: v.txnCount,
          categoryId: v.categoryId,
        ),
      )
      .toList()
    ..sort((a, b) => b.total.paise.compareTo(a.total.paise));
}

/// C2 Card Detail — one vertically scrollable card report (ui-spec Group C,
/// implementation-plan-group-c-d.md).
/// Deep-linkable at /cards/:id. Reads [myCardsWithProductProvider] (not
/// ownedCardsWithProductProvider) deliberately — a card reached from C1's
/// archived filter must still resolve here, read-only.
class CardDetailScreen extends ConsumerWidget {
  final String userCardId;
  final int initialTabIndex;

  const CardDetailScreen({
    super.key,
    required this.userCardId,
    this.initialTabIndex = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(myCardsWithProductProvider);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          pairs.valueOrNull
                  ?.where((p) => p.$1.id == userCardId)
                  .map(
                    (p) => p.$1.nickname?.isNotEmpty == true
                        ? p.$1.nickname!
                        : p.$2.name,
                  )
                  .firstOrNull ??
              'Card detail',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
        actions: [
          if (pairs.valueOrNull?.any((p) => p.$1.id == userCardId) ??
              false) ...[
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/cards/$userCardId/edit'),
            ),
            IconButton(
              tooltip: 'Report wrong data',
              icon: const Icon(Icons.flag_outlined),
              onPressed: () => context.push(
                '${AppRoute.reportWrongData}?cardProductId=${pairs.requireValue.firstWhere((p) => p.$1.id == userCardId).$2.id}',
              ),
            ),
            // Design 23 Card actions — pause / report lost / default /
            // remove. Kept off the tab bar below: those six tabs are all
            // *readings* of the card, these are the things that change it.
            IconButton(
              tooltip: 'Card actions',
              icon: const Icon(Icons.more_horiz_rounded),
              onPressed: () {
                final pair = pairs.requireValue.firstWhere(
                  (p) => p.$1.id == userCardId,
                );
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        CardActionsScreen(card: pair.$1, product: pair.$2),
                  ),
                );
              },
            ),
          ],
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            Expanded(
              child: pairs.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  child: SkeletonList(count: 4),
                ),
                error: (err, _) => ErrorState(
                  message: userFacingErrorMessage(err),
                  onRetry: () => ref.invalidate(myCardsProvider),
                ),
                data: (owned) {
                  final match = owned
                      .where((p) => p.$1.id == userCardId)
                      .firstOrNull;
                  if (match == null) {
                    return const ErrorState(
                      message:
                          'This card could not be found — it may have been removed.',
                    );
                  }
                  final (userCard, product) = match;
                  final spendSummary = ref.watch(
                    cardSpendSummaryProvider,
                  )[userCard.id];
                  final cardUtilization = ref.watch(
                    creditUtilizationProvider,
                  )[userCard.id];
                  final duePayments =
                      ref.watch(paymentsDueProvider).valueOrNull ??
                      const <DuePayment>[];
                  final duePayment = duePayments
                      .where((d) => d.card.id == userCard.id)
                      .firstOrNull;
                  final sections = [
                    (
                      label: 'Rewards',
                      body: _RewardsTab(
                        product: product,
                        userCardId: userCard.id,
                        userCard: userCard,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Spend',
                      body: _SpendSection(userCard: userCard, product: product),
                    ),
                    (
                      label: 'Caps',
                      body: _CapsTab(
                        userCard: userCard,
                        product: product,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Milestones',
                      body: _MilestonesTab(
                        userCard: userCard,
                        product: product,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Fees',
                      body: _FeesTab(
                        userCard: userCard,
                        product: product,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Benefits',
                      body: _BenefitsTab(
                        userCard: userCard,
                        product: product,
                        embedded: true,
                      ),
                    ),
                    (
                      label: 'Statement',
                      body: _StatementTab(
                        userCard: userCard,
                        product: product,
                        duePayment: duePayment,
                        embedded: true,
                      ),
                    ),
                  ];
                  final selected = initialTabIndex.clamp(
                    0,
                    sections.length - 1,
                  );
                  final ordered = [
                    ...sections.skip(selected),
                    ...sections.take(selected),
                  ];
                  return ListView(
                    key: const ValueKey('cardDetailScroll'),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.lg,
                      AppSpace.lg,
                      AppSpace.lg,
                      AppSpace.xl,
                    ),
                    children: [
                      CardVisual(
                        product: product,
                        height: 190,
                        userCard: userCard,
                        cycleSpend: spendSummary?.cycleTotal,
                        latestSpend: spendSummary?.latestSpend,
                        effectiveBillingDay:
                            duePayment?.bill?.statementDate.day ??
                            userCard.statementDay,
                        effectiveDueDay:
                            duePayment?.dueOn.day ?? userCard.dueDay,
                      ),
                      if (userCard.isDefault || userCard.isArchived) ...[
                        const SizedBox(height: AppSpace.sm),
                        Row(
                          children: [
                            if (userCard.isDefault)
                              const StatusPill(
                                label: 'DEFAULT CARD',
                                foreground: BambooInk.onSlate,
                                background: BambooInk.slate,
                                icon: Icons.check_circle_rounded,
                              ),
                            if (userCard.isArchived) ...[
                              const SizedBox(width: AppSpace.xs),
                              const StatusPill(
                                label: 'PAUSED',
                                foreground: BambooInk.onSlate,
                                background: BambooInk.amber,
                                icon: Icons.pause_circle_rounded,
                              ),
                            ],
                          ],
                        ),
                      ],
                      const SizedBox(height: AppSpace.xs),
                      _CardUtilizationHeaderBar(
                        card: userCard,
                        result: cardUtilization,
                      ),
                      const SizedBox(height: AppSpace.md),
                      _CardSpendingMixSection(userCard: userCard),
                      const SizedBox(height: AppSpace.lg),
                      for (final section in ordered) ...[
                        _CardDetailSection(
                          label: section.label,
                          summary: _sectionSummary(
                            section.label,
                            userCard,
                            product,
                          ),
                          body: section.body,
                        ),
                      ],
                      _RecentCardActivitySection(userCardId: userCard.id),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _sectionSummary(String label, UserCard card, CardProduct product) {
  return switch (label) {
    'Rewards' =>
      '${uniqueRewardRules(product.rewardRules).length + (product.fuelRule == null ? 0 : 1)} earning rules · tap rows for details',
    'Spend' => 'This month · actual spend and effective reward rate',
    'Caps' =>
      '${uniqueCapRules(product.capRules).length} tracked caps · consumption resets by period',
    'Milestones' =>
      '${uniqueMilestoneRules(product.milestoneRules).length} milestone${uniqueMilestoneRules(product.milestoneRules).length == 1 ? '' : 's'} · progress to unlock',
    'Fees' =>
      card.annualFeeOverride?.isZero == true
          ? 'Lifetime free for you'
          : '${card.feeWaiverStates.length} waiver rule${card.feeWaiverStates.length == 1 ? '' : 's'} · annual fee below',
    'Benefits' =>
      '${uniqueCardBenefits(product.benefits).length} benefits · lounge access and protections',
    'Statement' =>
      card.statementDay == null
          ? 'Add statement day to see your billing cycle'
          : 'Cuts on day ${card.statementDay} · due day ${card.dueDay ?? 'not set'}',
    _ => '',
  };
}

Money? _effectiveAnnualFee(UserCard card, CardProduct product) =>
    card.annualFeeOverride ?? product.annualFeeInr;

class _CardDetailSection extends StatelessWidget {
  final String label;
  final String summary;
  final Widget body;

  const _CardDetailSection({
    required this.label,
    required this.summary,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpace.xs,
              bottom: AppSpace.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  label.toUpperCase(),
                  style: BambooFonts.ui(
                    12,
                    weight: FontWeight.w700,
                    color: BambooInk.ink500,
                  ).copyWith(letterSpacing: 1),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }
}

class _CardUtilizationHeaderBar extends StatelessWidget {
  final UserCard card;
  final UtilizationResult? result;

  const _CardUtilizationHeaderBar({required this.card, required this.result});

  @override
  Widget build(BuildContext context) {
    final tracked = result;
    final limit = card.creditLimit;
    final hasLimit = limit != null && tracked != null;
    final ratio = hasLimit ? tracked.ratio : 0.0;
    final color = hasLimit
        ? CreditUtilizationUi.color(ratio)
        : BambooInk.ink500;
    final icon = hasLimit
        ? CreditUtilizationUi.icon(ratio)
        : Icons.credit_score_outlined;
    final title = hasLimit
        ? 'Credit utilization: ${(ratio * 100).clamp(0, 999).toStringAsFixed(0)}% · ${CreditUtilizationUi.label(ratio)}'
        : 'Credit utilization · Add a limit';
    String trailing;
    if (hasLimit) {
      final available = limit - tracked.currentBalance;
      final headroom = available.isNegative ? const Money.zero() : available;
      trailing = '${headroom.format(hidePaise: true)} headroom';
    } else {
      trailing = 'Add limit';
    }

    return InkWell(
      onTap: () => context.push('/cards/${card.id}/edit'),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.ui(
                      12,
                      weight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
                Text(
                  trailing,
                  style: BambooFonts.ui(
                    11.5,
                    weight: FontWeight.w600,
                    color: hasLimit ? BambooInk.ink700 : BambooInk.jade,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: hasLimit ? BambooInk.ink500 : BambooInk.jade,
                ),
              ],
            ),
            if (hasLimit) ...[
              const SizedBox(height: 7),
              ClipRRect(
                key: const Key('card_credit_utilization_bar'),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: BambooInk.paperMuted,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Horizontal unroll of the spending-mix donut: same category colours,
/// same proportions, as a pill bar.
class _SpendingMixStackedBar extends StatelessWidget {
  final List<SpendBreakdownRow> rows;

  const _SpendingMixStackedBar({required this.rows});

  @override
  Widget build(BuildContext context) {
    final totalPaise = rows.fold<int>(0, (sum, row) => sum + row.total.paise);
    final label = totalPaise <= 0
        ? 'No spending mix this month'
        : rows
              .map(
                (row) =>
                    '${row.label} ${((row.total.paise / totalPaise) * 100).round()}%',
              )
              .join(', ');

    return Semantics(
      key: const Key('card_spending_mix_bar'),
      label: 'Spending mix bar, $label',
      child: SizedBox(
        height: 14,
        width: double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: CustomPaint(
            painter: _SpendingMixBarPainter(rows: rows, totalPaise: totalPaise),
          ),
        ),
      ),
    );
  }
}

class _SpendingMixBarPainter extends CustomPainter {
  final List<SpendBreakdownRow> rows;
  final int totalPaise;

  const _SpendingMixBarPainter({required this.rows, required this.totalPaise});

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()..color = BambooInk.paperMuted;
    canvas.drawRect(Offset.zero & size, track);
    if (totalPaise <= 0 || size.width <= 0) return;

    var x = 0.0;
    for (final row in rows) {
      final width = size.width * (row.total.paise / totalPaise);
      if (width <= 0) continue;
      final paint = Paint()..color = spendingCategoryVisual(row.label).accent;
      canvas.drawRect(Rect.fromLTWH(x, 0, width, size.height), paint);
      x += width;
    }
  }

  @override
  bool shouldRepaint(covariant _SpendingMixBarPainter oldDelegate) =>
      oldDelegate.rows != rows || oldDelegate.totalPaise != totalPaise;
}

class _CardSpendingMixSection extends ConsumerStatefulWidget {
  final UserCard userCard;

  const _CardSpendingMixSection({required this.userCard});

  @override
  ConsumerState<_CardSpendingMixSection> createState() =>
      _CardSpendingMixSectionState();
}

class _CardSpendingMixSectionState
    extends ConsumerState<_CardSpendingMixSection> {
  String? _selectedCategoryKey;
  bool _showAllCategories = false;

  String _categoryKey(SpendBreakdownRow row) => spendingMixCategoryKey(row);

  String _categoryLabel(String rawLabel) =>
      _normalizedSpendCategoryLabel(rawLabel);

  void _selectCategory(int? index, List<SpendBreakdownRow> rows) {
    setState(() {
      if (index == null || index >= rows.length) {
        _selectedCategoryKey = null;
      } else {
        final key = _categoryKey(rows[index]);
        _selectedCategoryKey = _selectedCategoryKey == key ? null : key;
      }
    });
  }

  List<SpendBreakdownRow> _aggregateCardCategories(
    List<CardCategorySpendRow> rawRows,
    String userCardId,
  ) => _aggregateCardCategoryRows(rawRows, userCardId);

  List<TransactionEntry> _transactionsForCategory(
    SpendBreakdownRow row,
    List<TransactionEntry> cardTransactions,
  ) {
    return cardTransactions.where((entry) {
      if (row.categoryId != null &&
          (entry.categoryId == row.categoryId ||
              entry.userCategoryId == row.categoryId ||
              entry.parentUserCategoryId == row.categoryId ||
              entry.parentCategoryId == row.categoryId)) {
        return true;
      }
      final entryCat = entry.categoryName == null
          ? null
          : _categoryLabel(entry.categoryName!).toLowerCase();
      if (entryCat == null || entryCat.isEmpty || entryCat == 'other') {
        return row.label.toLowerCase() == 'other';
      }
      return entryCat == row.label.toLowerCase();
    }).toList();
  }

  List<TransactionEntry> _transactionsForReportPeriod(
    List<TransactionEntry> transactions,
    SpendReport report,
  ) => transactions
      .where(
        (entry) =>
            !entry.occurredAt.isBefore(report.periodStart) &&
            entry.occurredAt.isBefore(report.periodEnd),
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    final selectedQuery = ref.watch(
      cardDetailSpendQueryProvider(widget.userCard.id),
    );
    final reportState = ref.watch(spendReportProvider(selectedQuery));
    final allTransactions =
        ref.watch(transactionsProvider).valueOrNull ??
        const <TransactionEntry>[];
    final cardTransactions = allTransactions
        .where((e) => e.userCardId == widget.userCard.id)
        .toList();

    final content = reportState.when(
      loading: () => const CardSummaryPanel(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpace.md),
          child: SkeletonList(count: 3),
        ),
      ),
      error: (err, _) => CardSummaryPanel(
        child: ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(spendReportProvider(selectedQuery)),
        ),
      ),
      data: (data) {
        if (data == null) {
          return const SizedBox.shrink();
        }

        final periodTransactions = _transactionsForReportPeriod(
          cardTransactions,
          data,
        );
        final nonZeroRows = _aggregateCardCategories(
          data.byCardCategory,
          widget.userCard.id,
        );

        if (nonZeroRows.isEmpty) {
          return CardSummaryPanel(
            child: Row(
              children: [
                const SpendingVisualBadge(
                  visual: SpendingVisual(
                    icon: Icons.pie_chart_outline_rounded,
                    accent: BambooChartColors.teal,
                  ),
                  size: 38,
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Spending mix · ${data.displayLabel}',
                        style: BambooFonts.heading(
                          14.5,
                          color: BambooInk.ink900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'No spending recorded on this card for ${data.displayLabel.toLowerCase()} yet.',
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        final cardTotal = nonZeroRows.fold<Money>(
          const Money.zero(),
          (sum, r) => sum + r.total,
        );

        final matchedIndex = _selectedCategoryKey == null
            ? -1
            : nonZeroRows.indexWhere(
                (row) => _categoryKey(row) == _selectedCategoryKey,
              );
        final selectedIndex = matchedIndex < 0 ? null : matchedIndex;
        const initialVisibleCount = 4;
        final visibleRows = nonZeroRows
            .take(_showAllCategories ? nonZeroRows.length : initialVisibleCount)
            .toList();
        final remaining = (nonZeroRows.length - initialVisibleCount).clamp(
          0,
          nonZeroRows.length,
        );

        return Column(
          key: const Key('card_spending_mix'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SpendingMixCard(
              rows: nonZeroRows,
              total: cardTotal,
              selectedCategoryKey: _selectedCategoryKey,
              onCategorySelected: (row) => setState(
                () => _selectedCategoryKey = row == null
                    ? null
                    : _categoryKey(row),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            CardSummaryPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CATEGORY BREAKDOWN & MERCHANTS',
                    style: BambooFonts.ui(
                      11.5,
                      weight: FontWeight.w700,
                      color: BambooInk.ink500,
                    ).copyWith(letterSpacing: 0.8),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  for (final row in visibleRows)
                    _CardExpandableCategoryRow(
                      row: row,
                      total: cardTotal,
                      entries: _transactionsForCategory(
                        row,
                        periodTransactions,
                      ),
                      initiallyExpanded:
                          selectedIndex != null &&
                          nonZeroRows.indexOf(row) == selectedIndex,
                      onExpansionChanged: (expanded) {
                        final index = nonZeroRows.indexOf(row);
                        if (expanded && selectedIndex != index) {
                          _selectCategory(index, nonZeroRows);
                        } else if (!expanded && selectedIndex == index) {
                          _selectCategory(null, nonZeroRows);
                        }
                      },
                    ),
                  if (remaining > 0)
                    Align(
                      alignment: Alignment.center,
                      child: TextButton.icon(
                        key: const Key('card_spending_mix_show_more'),
                        onPressed: () => setState(
                          () => _showAllCategories = !_showAllCategories,
                        ),
                        icon: Icon(
                          _showAllCategories
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _showAllCategories
                              ? 'Show fewer categories'
                              : 'Show $remaining more ${remaining == 1 ? 'category' : 'categories'}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SpendPeriodSelector(
          selected: selectedQuery,
          filtersActive: false,
          showFilters: false,
          onChanged: (query) {
            ref
                    .read(
                      cardDetailSpendQueryProvider(widget.userCard.id).notifier,
                    )
                    .state =
                query;
            setState(() {
              _selectedCategoryKey = null;
              _showAllCategories = false;
            });
          },
        ),
        content,
      ],
    );
  }
}

class _CardExpandableCategoryRow extends StatefulWidget {
  final SpendBreakdownRow row;
  final Money total;
  final List<TransactionEntry> entries;
  final bool initiallyExpanded;
  final ValueChanged<bool> onExpansionChanged;

  const _CardExpandableCategoryRow({
    required this.row,
    required this.total,
    required this.entries,
    this.initiallyExpanded = false,
    required this.onExpansionChanged,
  });

  @override
  State<_CardExpandableCategoryRow> createState() =>
      _CardExpandableCategoryRowState();
}

class _CardExpandableCategoryRowState
    extends State<_CardExpandableCategoryRow> {
  final ExpansibleController _controller = ExpansibleController();

  @override
  void didUpdateWidget(covariant _CardExpandableCategoryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initiallyExpanded == widget.initiallyExpanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.initiallyExpanded) {
        _controller.expand();
      } else {
        _controller.collapse();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<MapEntry<String, List<TransactionEntry>>> _merchantGroups() {
    final grouped = <String, List<TransactionEntry>>{};
    final unnamed = <MapEntry<String, List<TransactionEntry>>>[];
    for (final entry in widget.entries) {
      final merchant = entry.merchantName?.trim();
      if (merchant == null || merchant.isEmpty) {
        if (unnamed.isEmpty) {
          unnamed.add(MapEntry('Merchant not captured', [entry]));
        } else {
          unnamed.first.value.add(entry);
        }
        continue;
      }
      grouped.putIfAbsent(merchant, () => []).add(entry);
    }
    return [...grouped.entries, ...unnamed]..sort((a, b) {
      final aTotal = a.value.fold<int>(0, (s, e) => s + e.amount.paise);
      final bTotal = b.value.fold<int>(0, (s, e) => s + e.amount.paise);
      return bTotal.compareTo(aTotal);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ratio = widget.total.isZero
        ? 0.0
        : (widget.row.total.paise / widget.total.paise).clamp(0.0, 1.0);
    final visual = spendingCategoryVisual(widget.row.label);
    final groups = _merchantGroups();

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey(
              'card_cat_${widget.row.categoryId}_${widget.row.label}',
            ),
            controller: _controller,
            initiallyExpanded: widget.initiallyExpanded,
            onExpansionChanged: widget.onExpansionChanged,
            tilePadding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.xs,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              0,
              AppSpace.md,
              AppSpace.sm,
            ),
            leading: SpendingVisualBadge(visual: visual, size: 36),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SpendingBreakdownHeader(
                  label: Text(
                    widget.row.label,
                    style: BambooFonts.ui(
                      13.5,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  percentage: '${(ratio * 100).toStringAsFixed(0)}%',
                  amount: MoneyText(
                    widget.row.total,
                    confidence: Confidence.estimated,
                    style: BambooFonts.ui(
                      13.5,
                      weight: FontWeight.w700,
                      color: BambooInk.ink900,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${widget.row.txnCount} ${widget.row.txnCount == 1 ? 'transaction' : 'transactions'} · Tap to see merchants',
                  style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 4.5,
                    backgroundColor: BambooInk.paperMuted,
                    color: visual.accent,
                  ),
                ),
              ],
            ),
            children: [
              if (groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No individual transaction records available for this period.',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ),
                )
              else
                for (final group in groups)
                  _CardMerchantGroupItem(
                    merchant: group.key,
                    entries: group.value,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardMerchantGroupItem extends StatelessWidget {
  final String merchant;
  final List<TransactionEntry> entries;

  const _CardMerchantGroupItem({required this.merchant, required this.entries});

  @override
  Widget build(BuildContext context) {
    final merchantTotal = entries.fold<Money>(
      const Money.zero(),
      (sum, e) => sum + e.amount,
    );

    return Container(
      margin: const EdgeInsets.only(top: AppSpace.xs),
      padding: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.store_outlined,
                size: 15,
                color: BambooInk.ink500,
              ),
              const SizedBox(width: AppSpace.xs),
              Expanded(
                child: Text(
                  merchant,
                  style: BambooFonts.ui(
                    12.5,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              MoneyText(
                merchantTotal,
                confidence: Confidence.confirmed,
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w600,
                  color: BambooInk.ink900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final entry in entries)
            InkWell(
              onTap: () => context.push('/activity/${entry.id}'),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                child: Row(
                  children: [
                    Text(
                      '${entry.occurredAt.day} ${_monthAbbr(entry.occurredAt.month)}',
                      style: BambooFonts.ui(11, color: BambooInk.ink500),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    if (entry.note != null && entry.note!.isNotEmpty)
                      Expanded(
                        child: Text(
                          entry.note!,
                          style: BambooFonts.ui(11, color: BambooInk.ink500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    else
                      const Spacer(),
                    MoneyText(
                      entry.amount,
                      confidence: Confidence.confirmed,
                      style: BambooFonts.ui(12, color: BambooInk.ink900),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 14,
                      color: BambooInk.ink500,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _monthAbbr(int month) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month - 1];
}

class _CardPointsSummaryTile extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;

  const _CardPointsSummaryTile({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = userCard.pointsBalance ?? userCard.totalPointsEarned;
    final valueEstimate = Money.fromRupees(points * product.pointValueInr);
    final ledger =
        ref.watch(pointsLedgerProvider(userCard.id)).valueOrNull ??
        const <PointsLedgerEntry>[];
    final withExpiry = ledger.where((e) => e.expiresOn != null).toList()
      ..sort((a, b) => a.expiresOn!.compareTo(b.expiresOn!));
    final nearestExpiry = withExpiry.firstOrNull;
    final daysToExpiry = nearestExpiry == null
        ? null
        : daysUntil(nearestExpiry.expiresOn!, DateTime.now());

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: BambooChartColors.amber.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.stars_rounded,
              color: BambooChartColors.amber,
              size: 22,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${points.toStringAsFixed(0)} pts',
                      style: BambooFonts.heading(15, color: BambooInk.ink900),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Text(
                      '(≈ ${valueEstimate.format(hidePaise: true)})',
                      style: BambooFonts.ui(
                        12.5,
                        weight: FontWeight.w600,
                        color: BambooInk.jade,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                if (nearestExpiry != null && daysToExpiry != null)
                  Text(
                    daysToExpiry <= 30
                        ? 'Expiring in $daysToExpiry days (${nearestExpiry.expiresOn!.day}/${nearestExpiry.expiresOn!.month})'
                        : 'Next expiry in $daysToExpiry days',
                    style: BambooFonts.ui(
                      11.5,
                      weight: FontWeight.w500,
                      color: daysToExpiry <= 30
                          ? BambooInk.clay
                          : BambooInk.ink500,
                    ),
                  )
                else
                  Text(
                    '${product.pointValueInr > 0 ? "1 pt = ₹${product.pointValueInr.toStringAsFixed(2)}" : "Rewards balance"} · No expiry on file',
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
              ],
            ),
          ),
          InkWell(
            onTap: () => context.push(AppRoute.pointsExpiry),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Details',
                    style: BambooFonts.ui(
                      12,
                      weight: FontWeight.w600,
                      color: BambooInk.ink700,
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: BambooInk.ink500,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentCardActivitySection extends ConsumerWidget {
  final String userCardId;

  const _RecentCardActivitySection({required this.userCardId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all =
        ref.watch(transactionsProvider).valueOrNull ??
        const <TransactionEntry>[];
    final cardTxns = all.where((t) => t.userCardId == userCardId).toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    if (cardTxns.isEmpty) {
      return const SizedBox.shrink();
    }

    final recent = cardTxns.take(4).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: CardSummaryPanel(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.history_rounded,
                  size: 20,
                  color: BambooInk.ink700,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'Recent Card Activity',
                    style: BambooFonts.heading(15, color: BambooInk.ink900),
                  ),
                ),
                TextButton(
                  onPressed: () => context.push(AppRoute.activity),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'View all',
                        style: BambooFonts.ui(
                          12.5,
                          weight: FontWeight.w600,
                          color: BambooInk.ink700,
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: BambooInk.ink700,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            for (final txn in recent) ...[
              InkWell(
                onTap: () => context.push('/activity/${txn.id}'),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      SpendingVisualBadge(
                        visual: spendingCategoryVisual(
                          txn.categoryName ?? 'Other',
                        ),
                        size: 32,
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              txn.merchantName?.isNotEmpty == true
                                  ? txn.merchantName!
                                  : (txn.categoryName ?? 'Card transaction'),
                              style: BambooFonts.ui(
                                13,
                                weight: FontWeight.w600,
                                color: BambooInk.ink900,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${txn.occurredAt.day} ${_monthName(txn.occurredAt.month)} · ${txn.categoryName ?? 'Other'}',
                              style: BambooFonts.ui(
                                11,
                                color: BambooInk.ink500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      MoneyText(
                        txn.amount,
                        confidence: Confidence.confirmed,
                        style: BambooFonts.ui(
                          13.5,
                          weight: FontWeight.w600,
                          color: BambooInk.ink900,
                        ),
                      ),
                      const SizedBox(width: AppSpace.xs),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 14,
                        color: BambooInk.ink500,
                      ),
                    ],
                  ),
                ),
              ),
              if (txn != recent.last)
                const Divider(color: BambooInk.hairlineOnPaper, height: 1),
            ],
          ],
        ),
      ),
    );
  }

  static String _monthName(int month) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month - 1];
}

/// What this card actually did this month, and what it really paid.
///
/// Card Detail had six tabs describing the card's TERMS — its rates, caps,
/// milestones, fees, benefits and statement dates — and none describing the
/// card's PERFORMANCE. So the one question a cardholder most wants
/// answered, "is this card earning its keep?", had no home, even though
/// every figure needed to answer it was already being recorded.
///
/// Reuses the shared spend report rather than adding a per-card endpoint:
/// `GET /spend-report` already returns a per-card breakdown, so filtering
/// it here keeps one definition of "spend on this card" instead of two that
/// can drift.
int _calendarMonthSpan(DateTime from, DateTime to) {
  final months = (to.year - from.year) * 12 + to.month - from.month;
  return months < 1 ? 1 : months;
}

class _SpendSection extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  const _SpendSection({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedQuery = ref.watch(cardDetailSpendQueryProvider(userCard.id));
    final report = ref.watch(spendReportProvider(selectedQuery));

    return report.when(
      loading: () => const _SpendDisclosure(
        trailing: 'Loading',
        details: [
          Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
            child: SkeletonList(count: 3),
          ),
        ],
      ),
      error: (err, _) => _SpendDisclosure(
        trailing: 'Retry',
        details: [
          ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(spendReportProvider(selectedQuery)),
          ),
        ],
      ),
      data: (data) {
        if (data == null) {
          return const _SpendDisclosure(
            trailing: 'Open',
            details: [
              EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Sign in to see this card\'s spending',
                message:
                    'Per-card reports are built from your transaction history, which lives with '
                    'your account.',
              ),
            ],
          );
        }
        final row = data.byCard
            .where((c) => c.cardId == userCard.id)
            .firstOrNull;
        if (row == null || row.total.isZero) {
          final suffix = userCard.last4 == null
              ? ''
              : ' ending ${userCard.last4}';
          return _SpendDisclosure(
            trailing: '₹0',
            details: [
              EmptyState(
                icon: Icons.show_chart_rounded,
                title:
                    'Nothing on ${userCard.cardName}$suffix for ${selectedQuery.shortLabel.toLowerCase()} yet',
                message:
                    'Once spend is logged against this card, you\'ll see what it earned and the '
                    'rate it really paid.',
              ),
            ],
          );
        }

        final rate = row.effectiveRatePerRupee;
        final fee = _effectiveAnnualFee(userCard, product);
        // Annualised from ONE month, and labelled as such. A month is a
        // small sample and a bad one to extrapolate from blindly, but the
        // alternative — comparing a month of rewards against a year of fee
        // — is the comparison people make in their heads anyway, and it is
        // wrong by a factor of twelve.
        final periodMonths = _calendarMonthSpan(
          data.periodStart,
          data.periodEnd,
        );
        final annualisedRewards = row.rewards * (12 / periodMonths);
        final mixRows = _aggregateCardCategoryRows(
          data.byCardCategory,
          userCard.id,
        );

        return _SpendDisclosure(
          trailing: row.total.format(compact: true),
          subtitle:
              '${selectedQuery.shortLabel} · actual spend and effective reward rate',
          details: [
            _SpendBarSummary(
              spend: row.total,
              transactionCount: row.txnCount,
              mixRows: mixRows,
              periodLabel: selectedQuery.shortLabel,
            ),
            const SizedBox(height: AppSpace.md),
            _SpendStatCard(
              label: 'Earned in ${selectedQuery.shortLabel.toLowerCase()}',
              value: row.rewards,
              sub: rate == null
                  ? null
                  : 'An effective ${(rate * 100).toStringAsFixed(2)}% on what you spent here — '
                        'this is what the card actually paid, not its headline rate.',
            ),
            if (fee != null && !fee.isZero) ...[
              const SizedBox(height: AppSpace.md),
              _SpendStatCard(
                label: 'Annual fee',
                value: fee,
                sub: annualisedRewards >= fee
                    ? 'At this period\'s pace you\'d earn about '
                          '${annualisedRewards.format(compact: true)} a year — more than the fee.'
                    : 'At this period\'s pace you\'d earn about '
                          '${annualisedRewards.format(compact: true)} a year, which is less than '
                          'the fee. One month is a small sample — check the Savings Report before '
                          'deciding.',
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SpendDisclosure extends StatelessWidget {
  final String trailing;
  final String subtitle;
  final List<Widget> details;

  const _SpendDisclosure({
    required this.trailing,
    this.subtitle = 'This month · actual spend and effective reward rate',
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    return _CompactDisclosure(
      title: 'Spend',
      subtitle: subtitle,
      trailing: trailing,
      details: details,
    );
  }
}

class _SpendStatCard extends StatelessWidget {
  final String label;
  final Money value;
  final String? sub;
  const _SpendStatCard({required this.label, required this.value, this.sub});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    sub!,
                    style: BambooFonts.ui(12, color: BambooInk.ink500),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpace.md),
          MoneyText(
            value,
            confidence: Confidence.estimated,
            style: BambooFonts.money(18, color: BambooInk.ink900),
          ),
        ],
      ),
    );
  }
}

class _SpendBarSummary extends StatelessWidget {
  final Money spend;
  final int transactionCount;
  final List<SpendBreakdownRow> mixRows;
  final String periodLabel;

  const _SpendBarSummary({
    required this.spend,
    required this.transactionCount,
    required this.mixRows,
    required this.periodLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      child: Column(
        children: [
          MoneyText(
            spend,
            confidence: Confidence.estimated,
            style: BambooFonts.money(30, color: BambooInk.ink900),
          ),
          const SizedBox(height: 1),
          Text(
            'spent in ${periodLabel.toLowerCase()} · $transactionCount ${transactionCount == 1 ? 'transaction' : 'transactions'}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          _SpendingMixStackedBar(rows: mixRows),
        ],
      ),
    );
  }
}

/// A compact summary row used throughout card detail. The first frame shows
/// the useful answer (category, rate, consumption, or status); the issuer
/// wording and constraints remain one tap away instead of making the page a
/// wall of repeated cards.
class _CompactDisclosure extends StatelessWidget {
  final String title;
  final String subtitle;
  final String trailing;
  final List<Widget> details;

  const _CompactDisclosure({
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: AppSpace.lg,
              vertical: AppSpace.xs,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              0,
              AppSpace.lg,
              AppSpace.lg,
            ),
            title: Text(
              title,
              style: BambooFonts.heading(14.5, color: BambooInk.ink900),
            ),
            subtitle: Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  trailing,
                  style: BambooFonts.heading(15.5, color: BambooInk.ink900),
                ),
                const SizedBox(width: AppSpace.xs),
                const Icon(Icons.expand_more_rounded, color: BambooInk.ink500),
              ],
            ),
            children: details,
          ),
        ),
      ),
    );
  }
}

class _RewardsTab extends ConsumerWidget {
  final CardProduct product;
  final String userCardId;
  final UserCard? userCard;
  final bool embedded;
  const _RewardsTab({
    required this.product,
    required this.userCardId,
    this.userCard,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    final reportState = ref.watch(
      spendReportProvider(const SpendReportQuery.preset(SpendPeriod.month)),
    );
    final report = reportState.valueOrNull;
    final fuelCategory = categories.where((c) => c.slug == 'fuel').firstOrNull;
    String categoryName(String? id) {
      if (id == null) return 'All other spends';
      for (final c in categories) {
        if (c.id == id) return c.name;
      }
      return 'Unknown category';
    }

    final rules = List<RewardRule>.from(uniqueRewardRules(product.rewardRules))
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final hasFuelInRules = rules.any(
      (r) =>
          (fuelCategory != null && r.categoryId == fuelCategory.id) ||
          r.categoryId == 'fuel',
    );

    if (rules.isEmpty && product.fuelRule == null) {
      return const EmptyState(
        icon: Icons.percent_outlined,
        title: 'No reward structure on file yet',
      );
    }
    final grouped = <String, List<RewardRule>>{};
    for (final rule in rules) {
      grouped.putIfAbsent(categoryName(rule.categoryId), () => []).add(rule);
    }
    if (!hasFuelInRules &&
        product.fuelRule != null &&
        product.fuelRule!.waiverPercent > 0) {
      grouped.putIfAbsent('Fuel', () => []);
    }
    bool matchesCategory(CardCategorySpendRow row, String label) {
      final ids = grouped[label]!
          .map((rule) => rule.categoryId)
          .whereType<String>()
          .toSet();
      if (label == 'Fuel' && grouped[label]!.isEmpty) {
        // The report can arrive before category metadata. Its Fuel label is
        // still usable for this synthesized waiver row until the ID resolves.
        if (fuelCategory == null) {
          return row.categoryId == 'fuel' ||
              row.categoryName.toLowerCase() == 'fuel';
        }
        ids.add(fuelCategory.id);
      }
      return row.categoryId != null
          ? ids.contains(row.categoryId)
          : row.categoryName.toLowerCase() == label.toLowerCase();
    }

    String? categorySpendFor(String label) {
      if (report == null) return null;
      return report.byCardCategory
          .where(
            (row) =>
                row.cardId == userCardId &&
                (label == 'All other spends'
                    ? !grouped.keys
                          .where((key) => key != 'All other spends')
                          .any((key) => matchesCategory(row, key))
                    : matchesCategory(row, label)),
          )
          .fold<Money>(Money.zero(), (sum, row) => sum + row.total)
          .format(compact: true);
    }

    final spendUnavailable = report == null
        ? reportState.isLoading
              ? 'Loading this month’s spend'
              : reportState.hasError
              ? 'Spend unavailable'
              : 'Sign in to see actual spend'
        : null;

    CapRule? capFor(RewardRule rule) => uniqueCapRules(product.capRules)
        .where(
          (cap) =>
              (cap.rewardRuleId != null && cap.rewardRuleId == rule.id) ||
              (cap.categoryId != null && cap.categoryId == rule.categoryId),
        )
        .firstOrNull;

    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        if (userCard != null)
          _CardPointsSummaryTile(userCard: userCard!, product: product),
        if (product.verifiedAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Text(
              'Verified ${_monthYear(product.verifiedAt!)}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
        for (final entry in grouped.entries)
          _CompactDisclosure(
            title: entry.key,
            subtitle: <String>[
              entry.value.isEmpty
                  ? 'Surcharge waiver'
                  : entry.value.length == 1
                  ? _ruleSummary(entry.value.first)
                  : '${entry.value.length} reward rules · expand for rails and limits',
              if (entry.value.isEmpty)
                '${_rate(product.fuelRule!.waiverPercent)}% waiver'
              else if (entry.value.length == 1)
                'Reward ${_rateLabel(entry.value.first, product)}',
              if (entry.key == 'Fuel' &&
                  product.fuelRule != null &&
                  entry.value.isNotEmpty)
                '${_rate(product.fuelRule!.waiverPercent)}% waiver',
              if (spendUnavailable != null)
                spendUnavailable
              else
                'Spent this month ${categorySpendFor(entry.key)}',
            ].join(' · '),
            trailing:
                categorySpendFor(entry.key) ??
                (reportState.isLoading ? '…' : '—'),
            details: entry.value.isEmpty
                ? [_fuelDetail(product.fuelRule!)]
                : [
                    for (final rule in entry.value)
                      _rewardRuleDetail(rule, product, cap: capFor(rule)),
                  ],
          ),
      ],
    );
  }

  static String _ruleSummary(RewardRule rule) {
    final qualifiers = <String>[
      if (rule.rail != null && _railLabel(rule.rail!).isNotEmpty)
        _railLabel(rule.rail!),
      if (rule.merchantPattern != null) 'at ${rule.merchantPattern}',
    ];
    return qualifiers.isEmpty ? 'Base category rate' : qualifiers.join(' · ');
  }

  static Widget _rewardRuleDetail(
    RewardRule rule,
    CardProduct product, {
    CapRule? cap,
  }) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _rateLabel(rule, product),
              style: BambooFonts.ui(
                13.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            if (rule.rail != null)
              Text(
                _railLabel(rule.rail!),
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
          ],
        ),
        if (rule.merchantPattern != null)
          Text(
            'Merchant: ${rule.merchantPattern}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        if (rule.minTxn != null || rule.maxTxn != null)
          Text(
            '${rule.minTxn == null ? '' : 'From ${rule.minTxn!.format()}'}${rule.minTxn != null && rule.maxTxn != null ? ' · ' : ''}${rule.maxTxn == null ? '' : 'Up to ${rule.maxTxn!.format()} per transaction'}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        if (rule.unit != RewardUnit.cashbackPercent &&
            rule.unit != RewardUnit.discountPercent &&
            rule.unit != RewardUnit.flatPoints &&
            product.pointValueInr > 0)
          Text(
            'Conversion used: ₹${product.pointValueInr.toStringAsFixed(2)} per ${rule.unit == RewardUnit.milesPer100 ? 'mile' : 'point'} · ${_effectiveValueLabel(rule, product)}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        if (cap != null)
          Text(
            'Cap: ${_capValueLabel(cap)} · ${_periodLabel(cap.period)}',
            style: BambooFonts.ui(
              12.5,
              weight: FontWeight.w600,
              color: BambooInk.amber,
            ),
          ),
      ],
    ),
  );

  static Widget _fuelDetail(FuelSurchargeRule fuel) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.sm),
    child: Text(
      'Surcharge waived${fuel.minTxn == null ? '' : ' above ${fuel.minTxn!.format()}'}${fuel.maxTxn == null ? '' : ' up to ${fuel.maxTxn!.format()}'}.',
      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
    ),
  );

  static String _rate(double rate) =>
      rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate.toString();

  static String _rateLabel(
    RewardRule rule,
    CardProduct product,
  ) => switch (rule.unit) {
    RewardUnit.cashbackPercent ||
    RewardUnit.discountPercent => '${_rate(rule.rate)}%',
    RewardUnit.pointsPer100 =>
      '${_rate(rule.rate)} pts/₹100 · ${_effectiveValueLabel(rule, product)}',
    RewardUnit.pointsPer150 =>
      '${_rate(rule.rate)} pts/₹150 · ${_effectiveValueLabel(rule, product)}',
    RewardUnit.pointsPer200 =>
      '${_rate(rule.rate)} pts/₹200 · ${_effectiveValueLabel(rule, product)}',
    RewardUnit.milesPer100 =>
      '${_rate(rule.rate)} miles/₹100 · ${_effectiveValueLabel(rule, product)}',
    RewardUnit.flatPoints => '${_rate(rule.rate)} pts flat',
  };

  static String _effectiveValueLabel(RewardRule rule, CardProduct product) {
    final percent =
        rule.unit.effectiveRatePerRupee(
          rule.rate,
          pointValueInr: product.pointValueInr,
        ) *
        100;
    final formatted = percent == percent.roundToDouble()
        ? percent.toStringAsFixed(0)
        : percent.toStringAsFixed(2);
    return '$formatted% value';
  }

  static String _capValueLabel(CapRule cap) => switch (cap.measure) {
    CapMeasure.rewardValue => '${cap.capValue.format()} reward value',
    CapMeasure.spendAmount => '${cap.capValue.format()} eligible spend',
    CapMeasure.txnCount =>
      '${cap.capValue.rupees.toStringAsFixed(0)} transactions',
  };

  static String _periodLabel(CapPeriod period) => switch (period) {
    CapPeriod.statementCycle => 'each statement cycle',
    CapPeriod.calendarMonth => 'each calendar month',
    CapPeriod.quarter => 'each quarter',
    CapPeriod.halfYear => 'each half-year',
    CapPeriod.annual => 'each year',
    CapPeriod.lifetime => 'lifetime',
  };

  static String _railLabel(TxnRail rail) => switch (rail) {
    TxnRail.upiQr => 'UPI QR only',
    TxnRail.swipe => 'Swipe only',
    TxnRail.online => 'Online only',
    TxnRail.contactless => 'Contactless only',
    TxnRail.atm => 'ATM only',
    TxnRail.emi => 'EMI only',
    TxnRail.unknown => '',
  };

  static String _monthYear(DateTime d) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }
}

class _CapsTab extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  final bool embedded;
  const _CapsTab({
    required this.userCard,
    required this.product,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    String categoryName(String? id) {
      if (id == null) return 'All other spends';
      return categories
              .where((c) => c.id == id)
              .map((c) => c.name)
              .firstOrNull ??
          'Card-wide';
    }

    String measureLabel(CapRule cap) => switch (cap.measure) {
      CapMeasure.rewardValue => 'reward value cap',
      CapMeasure.spendAmount => 'spend cap',
      CapMeasure.txnCount => 'transaction cap',
    };

    final caps = uniqueCapRules(product.capRules);
    if (caps.isEmpty && product.fuelRule == null) {
      return const EmptyState(
        icon: Icons.speed_outlined,
        title: 'No caps on this card',
      );
    }
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        for (final cap in caps)
          Builder(
            builder: (context) {
              final consumed =
                  userCard.capConsumed[cap.id] ?? const Money.zero();
              final ratio = capRatio(consumed, cap.capValue);
              final isCount = cap.measure == CapMeasure.txnCount;
              final consumption = isCount
                  ? '${consumed.paise ~/ 100} of ${cap.capValue.paise ~/ 100} transactions'
                  : '${consumed.format()} of ${cap.capValue.format()}';
              return _CompactDisclosure(
                title: capRuleDisplayLabel(
                  cap,
                  categoryName: categoryName(cap.categoryId),
                ),
                subtitle:
                    '${categoryName(cap.categoryId)} · ${measureLabel(cap)} · resets ${_periodLabel(cap.period)}',
                trailing: consumption,
                details: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 8,
                      backgroundColor: BambooInk.paperMuted,
                      color: ratio >= 0.9 ? BambooInk.clay : BambooInk.jade,
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    consumption,
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Resets: ${_periodLabel(cap.period)}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  if (cap.postCapRate != null)
                    Text(
                      'After cap: ${cap.postCapRate}% ${humanizeIdentifier(cap.postCapUnit?.name, fallback: '')}',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                ],
              );
            },
          ),
        if (product.fuelRule != null) ...[
          if (caps.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Text(
                'Fuel surcharge waivers',
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Container(
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    userCard.nickname?.isNotEmpty == true
                        ? userCard.nickname!
                        : product.name,
                    style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${product.fuelRule!.waiverPercent.toStringAsFixed(product.fuelRule!.waiverPercent == product.fuelRule!.waiverPercent.roundToDouble() ? 0 : 2)}% surcharge waived'
                    '${product.fuelRule!.minTxn != null ? " on spends above ${product.fuelRule!.minTxn!.format()}" : ""}'
                    '${product.fuelRule!.maxTxn != null ? " up to ${product.fuelRule!.maxTxn!.format()}" : ""}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _periodLabel(CapPeriod period) => switch (period) {
    CapPeriod.statementCycle => 'each statement cycle',
    CapPeriod.calendarMonth => 'each calendar month',
    CapPeriod.quarter => 'each quarter',
    CapPeriod.halfYear => 'each half-year',
    CapPeriod.annual => 'each year',
    CapPeriod.lifetime => 'never (lifetime cap)',
  };
}

class _MilestonesTab extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final bool embedded;
  const _MilestonesTab({
    required this.userCard,
    required this.product,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    final milestones = uniqueMilestoneRules(product.milestoneRules);
    if (milestones.isEmpty) {
      return const EmptyState(
        icon: Icons.flag_outlined,
        title: 'No milestones on this card',
      );
    }
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        for (final milestone in milestones)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(
              builder: (context) {
                final qualified =
                    userCard.milestoneQualifiedSpend[milestone.id] ??
                    const Money.zero();
                final remainingPaise =
                    (milestone.thresholdSpend.paise - qualified.paise).clamp(
                      0,
                      milestone.thresholdSpend.paise,
                    );
                final remaining = Money.fromPaise(remainingPaise);
                final ratio = milestone.thresholdSpend.isZero
                    ? 0.0
                    : capRatio(qualified, milestone.thresholdSpend);
                final reached = remainingPaise == 0;
                final periodEnd = userCard.milestonePeriodEnd[milestone.id];
                final daysLeft = periodEnd == null
                    ? null
                    : daysUntil(periodEnd, DateTime.now());

                return Container(
                  decoration: BoxDecoration(
                    color: reached
                        ? BambooInk.jade.withValues(alpha: 0.10)
                        : BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(
                      color: reached
                          ? BambooInk.jade
                          : BambooInk.hairlineOnPaper,
                    ),
                  ),
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              humanizeIdentifier(milestone.label),
                              style: BambooFonts.heading(
                                14.5,
                                color: BambooInk.ink900,
                              ),
                            ),
                          ),
                          if (reached)
                            const StatusPill(
                              label: 'REACHED',
                              foreground: BambooInk.onSlate,
                              background: BambooInk.jade,
                              icon: Icons.check_rounded,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.sm),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 8,
                          backgroundColor: BambooInk.paperMuted,
                          color: BambooInk.jade,
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            reached ? 'Reached' : '${remaining.format()} to go',
                            style: BambooFonts.ui(
                              12.5,
                              weight: FontWeight.w700,
                              color: BambooInk.ink900,
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                'Reward ',
                                style: BambooFonts.ui(
                                  12.5,
                                  color: BambooInk.ink500,
                                ),
                              ),
                              MoneyText(
                                milestone.rewardValue,
                                confidence: Confidence.estimated,
                                style: BambooFonts.ui(
                                  12.5,
                                  color: BambooInk.ink500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (!reached && daysLeft != null) ...[
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          '$daysLeft days left this period',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _FeesTab extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final bool embedded;
  const _FeesTab({
    required this.userCard,
    required this.product,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    // Design 08 lists the annual fee as a required element of Card detail.
    // It was parsed (CardProduct.annualFeeInr) but never rendered anywhere —
    // this tab only ever showed fee-WAIVER progress, which is a different
    // thing and meaningless without the fee it waives.
    final effectiveFee = _effectiveAnnualFee(userCard, product);
    final feeHeader = Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ANNUAL FEE',
                    style: BambooFonts.ui(
                      11,
                      weight: FontWeight.w600,
                      color: BambooInk.ink500,
                    ).copyWith(letterSpacing: 1),
                  ),
                  const SizedBox(height: 4),
                  if (effectiveFee == null)
                    Text(
                      'Not recorded for this card',
                      style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                    )
                  else if (effectiveFee.isZero)
                    Text(
                      'Lifetime free',
                      style: BambooFonts.heading(20, color: BambooInk.jade),
                    )
                  else
                    MoneyText(
                      effectiveFee,
                      confidence: Confidence.confirmed,
                      style: BambooFonts.money(22, color: BambooInk.ink900),
                    ),
                ],
              ),
            ),
            if (product.joiningFeeInr != null && !product.joiningFeeInr!.isZero)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'JOINING',
                    style: BambooFonts.ui(
                      11,
                      weight: FontWeight.w600,
                      color: BambooInk.ink500,
                    ).copyWith(letterSpacing: 1),
                  ),
                  const SizedBox(height: 4),
                  MoneyText(
                    product.joiningFeeInr!,
                    confidence: Confidence.confirmed,
                    style: BambooFonts.ui(
                      15,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );

    if (userCard.feeWaiverStates.isEmpty) {
      return ListView(
        padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
        shrinkWrap: embedded,
        physics: embedded ? const NeverScrollableScrollPhysics() : null,
        children: [
          feeHeader,
          const EmptyState(
            icon: Icons.card_giftcard_outlined,
            title: 'No fee-waiver rule on this card',
          ),
        ],
      );
    }
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        feeHeader,
        for (final fw in userCard.feeWaiverStates)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Builder(
              builder: (context) {
                final waived = fw.waivedAt != null;
                final ratio = capRatio(fw.qualifiedSpend, fw.thresholdSpend);
                return Container(
                  decoration: BoxDecoration(
                    color: waived
                        ? BambooInk.jade.withValues(alpha: 0.10)
                        : BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(
                      color: waived
                          ? BambooInk.jade
                          : BambooInk.hairlineOnPaper,
                    ),
                  ),
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Fee waived at ',
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink500,
                            ),
                          ),
                          MoneyText(
                            fw.waivesFee,
                            confidence: Confidence.estimated,
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink500,
                            ),
                          ),
                          const Spacer(),
                          if (waived)
                            const StatusPill(
                              label: 'WAIVED',
                              foreground: BambooInk.onSlate,
                              background: BambooInk.jade,
                              icon: Icons.check_rounded,
                            ),
                        ],
                      ),
                      if (!waived) ...[
                        const SizedBox(height: AppSpace.sm),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 8,
                            backgroundColor: BambooInk.paperMuted,
                            color: ratio >= 0.9
                                ? BambooInk.clay
                                : BambooInk.jade,
                          ),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        Text(
                          '${fw.qualifiedSpend.format()} of ${fw.thresholdSpend.format()}',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        if (userCard.anniversaryOn != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              'Card anniversary: ${userCard.anniversaryOn!.toLocal().toString().split(' ').first}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
      ],
    );
  }
}

class _BenefitsTab extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  final bool embedded;
  const _BenefitsTab({
    required this.userCard,
    required this.product,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final benefits = [
      ...uniqueCardBenefits(product.benefits),
      if (product.fuelRule != null &&
          !uniqueCardBenefits(
            product.benefits,
          ).any((b) => b.kind == BenefitKind.fuelSurcharge))
        CardBenefit(
          id: 'fuel-${product.id}',
          kind: BenefitKind.fuelSurcharge,
          label:
              '${product.fuelRule!.waiverPercent == product.fuelRule!.waiverPercent.roundToDouble() ? product.fuelRule!.waiverPercent.toStringAsFixed(0) : product.fuelRule!.waiverPercent.toStringAsFixed(2)}% fuel surcharge waiver',
          description:
              'Fuel surcharge waived'
              '${product.fuelRule!.minTxn != null ? " on transactions above ${product.fuelRule!.minTxn!.format()}" : ""}'
              '${product.fuelRule!.maxTxn != null ? " up to ${product.fuelRule!.maxTxn!.format()}" : ""}.',
        ),
    ];
    if (benefits.isEmpty) {
      return const EmptyState(
        icon: Icons.workspace_premium_outlined,
        title: 'No benefits on file for this card',
      );
    }
    final visits = ref.watch(loungeUsageProvider).valueOrNull ?? const [];
    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        for (final benefit in benefits)
          Builder(
            builder: (context) {
              final isLounge =
                  benefit.kind == BenefitKind.loungeDomestic ||
                  benefit.kind == BenefitKind.loungeInternational;
              final used = isLounge
                  ? visits
                        .where(
                          (visit) =>
                              visit.userCardId == userCard.id &&
                              visit.benefitId == benefit.id,
                        )
                        .where(
                          (visit) => isInCurrentLoungeWindow(
                            visit.usedOn,
                            benefit.quotaPeriod,
                          ),
                        )
                        .length
                  : 0;
              final quota = benefit.quotaCount;
              final usage = isLounge && quota != null
                  ? '$used / $quota used'
                  : isLounge
                  ? '$used used · no fixed quota'
                  : 'Tap to view details';
              final details = <Widget>[
                if (benefit.description != null)
                  Text(
                    benefit.description!,
                    style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                  ),
                if (benefit.networkProgram != null)
                  Text(
                    'Program: ${humanizeIdentifier(benefit.networkProgram)}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                if (quota != null)
                  Text(
                    'Allowance: $quota per ${humanizeIdentifier(benefit.quotaPeriod?.name, fallback: 'period').toLowerCase()}',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                if (isLounge && quota != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: LinearProgressIndicator(
                      value: quota == 0 ? 0 : (used / quota).clamp(0.0, 1.0),
                      minHeight: 8,
                      backgroundColor: BambooInk.paperMuted,
                      color: used >= quota ? BambooInk.clay : BambooInk.jade,
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    used >= quota
                        ? 'No lounge visits remaining in this period'
                        : '${quota - used} lounge visit${quota - used == 1 ? '' : 's'} remaining',
                    style: BambooFonts.ui(
                      12.5,
                      color: used >= quota ? BambooInk.clay : BambooInk.ink500,
                    ),
                  ),
                ],
              ];
              return _CompactDisclosure(
                title: humanizeIdentifier(benefit.label),
                subtitle: isLounge
                    ? 'Lounge access · ${humanizeIdentifier(benefit.networkProgram, fallback: 'eligible program')}'
                    : benefit.description ?? 'Card benefit',
                trailing: usage,
                details: [
                  ...details,
                  const SizedBox(height: AppSpace.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                        label: Text(
                          isLounge
                              ? 'Log visit & view lounge info'
                              : 'View full benefit terms',
                          style: BambooFonts.ui(12.5, weight: FontWeight.w600),
                        ),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => BenefitDetailScreen(
                                userCard: userCard,
                                product: product,
                                benefit: benefit,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _StatementTab extends StatelessWidget {
  final UserCard userCard;
  final CardProduct? product;
  final DuePayment? duePayment;
  final bool embedded;
  const _StatementTab({
    required this.userCard,
    this.product,
    this.duePayment,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context) {
    if (userCard.statementDay == null && duePayment?.bill == null) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Statement date not set',
        message:
            'Add a statement day from Edit Card to see your billing cycle and interest-free float here.',
      );
    }
    final float = userCard.statementDay != null
        ? billingCycleFloat(
            statementDay: userCard.statementDay!,
            gracePeriodDays: _assumedGracePeriodDays,
          )
        : null;
    final bill = duePayment?.bill;
    final autopayUrl = officialAutopayUrl(
      issuerName: product?.issuerName,
      cardName: product?.name ?? userCard.cardName,
    );

    return ListView(
      padding: embedded ? EdgeInsets.zero : const EdgeInsets.all(AppSpace.lg),
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        if (bill != null) ...[
          Container(
            margin: const EdgeInsets.only(bottom: AppSpace.md),
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
                    Expanded(
                      child: Text(
                        'Active statement bill',
                        style: BambooFonts.heading(15, color: BambooInk.ink900),
                      ),
                    ),
                    if (bill.isPaid)
                      const StatusPill(
                        label: 'PAID IN FULL',
                        foreground: BambooInk.onSlate,
                        background: BambooInk.jade,
                        icon: Icons.check_rounded,
                      )
                    else
                      StatusPill(
                        label: duePayment != null
                            ? 'DUE IN ${duePayment!.daysUntilDue} DAYS'
                            : 'PAYMENT DUE',
                        foreground: BambooInk.onSlate,
                        background: (duePayment?.daysUntilDue ?? 10) <= 3
                            ? BambooInk.clay
                            : BambooInk.amber,
                        icon: Icons.schedule_rounded,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Total amount due',
                          style: BambooFonts.ui(12, color: BambooInk.ink500),
                        ),
                        const SizedBox(height: 2),
                        MoneyText(
                          bill.amountDue ?? const Money.zero(),
                          confidence: Confidence.confirmed,
                          style: BambooFonts.heading(
                            18,
                            color: BambooInk.ink900,
                          ),
                        ),
                      ],
                    ),
                    if (bill.minimumDue != null && !bill.minimumDue!.isZero)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Minimum due',
                            style: BambooFonts.ui(12, color: BambooInk.ink500),
                          ),
                          const SizedBox(height: 2),
                          MoneyText(
                            bill.minimumDue!,
                            confidence: Confidence.confirmed,
                            style: BambooFonts.ui(
                              14,
                              weight: FontWeight.w600,
                              color: BambooInk.ink700,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  'Statement cut on ${bill.statementDate.day} ${_monthName(bill.statementDate.month)} · Due on ${duePayment?.dueOn.day ?? userCard.dueDay} ${_monthName(duePayment?.dueOn.month ?? DateTime.now().month)}',
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
        ],
        if (float != null)
          Container(
            decoration: BoxDecoration(
              color: BambooInk.glassFillOnPaper,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: BambooInk.hairlineOnPaper),
            ),
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Statement cuts on day ${userCard.statementDay}',
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  'Next statement in ${float.daysUntilStatement} days',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  'Spending today gets up to ${float.totalInterestFreeDays} interest-free days '
                  '(assumes a $_assumedGracePeriodDays-day grace period to the due date).',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
                if (userCard.dueDay != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    'Payment due on day ${userCard.dueDay}',
                    style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                  ),
                ],
              ],
            ),
          ),
        if (autopayUrl != null) ...[
          const SizedBox(height: AppSpace.md),
          Container(
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: BambooInk.hairlineOnPaper),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.account_balance_rounded,
                  size: 20,
                  color: BambooInk.ink700,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Issuer payments & autopay',
                        style: BambooFonts.ui(
                          13,
                          weight: FontWeight.w600,
                          color: BambooInk.ink900,
                        ),
                      ),
                      Text(
                        'Set up or verify autopay on official bank portal',
                        style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse(autopayUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Open portal'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _monthName(int month) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month - 1];
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
