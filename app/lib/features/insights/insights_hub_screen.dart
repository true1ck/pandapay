import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/offline_banner.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../../main.dart' show MoneyText;
import 'insights_overview.dart';

/// Design 04 "Insights · what you earned", over ui-spec.md's E1 Insights
/// Hub.
///
/// This screen used to be nothing but the tile grid now sitting at the
/// bottom of it — twelve navigation tiles, so the Insights tab answered no
/// question on arrival and made you guess which tile held the number you
/// wanted. The deck's Insights is a content screen, and that is what runs
/// above the grid now: earned for the period with the spend and effective
/// rate it came from, a category breakdown, what was left on the table
/// beside the best-performing category, the three biggest misses, and the
/// milestone closest to paying out.
///
/// The grid stays, under a "MORE INSIGHTS" header. Design 04 has no such
/// thing, but each of those tiles is the only entry point to a real,
/// shipped E-screen — matching the deck literally would strand a dozen
/// features to win a layout argument.
///
/// Every figure above the grid comes from [insightsOverviewProvider]; see
/// [InsightsOverview] for which of them are records and which are
/// estimates, and why the two are marked differently.
///
/// ui-spec.md E1 heritage: Task E-0 landing
/// (credit_limit_inr/due_day/anniversary_on) unblocked E3/E5/E8's tiles;
/// E6/E9/E10/E11/E12 land in this same pass so their tiles ship together
/// rather than each needing a separate follow-up commit.
///
/// Task E-0c: tiles with a real urgency signal (Caps, Milestones, Fee
/// Waivers) sort nearest-deadline/closest-to-cap first via the shared
/// scorer; tiles with no such notion (Billing Float, All Activity,
/// Portfolio Audit, Spending Overview, Contributions, Credit Utilization,
/// Due Dates, Lounge) are appended after in a fixed order — E3 in
/// particular has no natural urgency (a utilization ratio isn't a
/// deadline), so it stays unordered per the plan's own note.
class InsightsHubScreen extends ConsumerWidget {
  const InsightsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
    final needsReviewCount = ref.watch(needsReviewCountProvider);

    final capRows = [
      for (final (userCard, product) in owned)
        for (final cap in product.capRules) (userCard, cap),
    ];
    final milestoneRows = [
      for (final (userCard, product) in owned)
        for (final m in product.milestoneRules) (userCard, m),
    ];
    final feeWaiverRows = [
      for (final (userCard, _) in owned)
        for (final fw in userCard.feeWaiverStates) fw,
    ];

    UrgencyScore? mostUrgentCap;
    for (final (userCard, cap) in capRows) {
      final consumed = userCard.capConsumed[cap.id] ?? const Money.zero();
      final score = UrgencyScore(ratioConsumed: capRatio(consumed, cap.capValue));
      if (mostUrgentCap == null || score.compareTo(mostUrgentCap) < 0) mostUrgentCap = score;
    }
    UrgencyScore? mostUrgentMilestone;
    for (final (userCard, m) in milestoneRows) {
      final qualified = userCard.milestoneQualifiedSpend[m.id] ?? const Money.zero();
      final end = userCard.milestonePeriodEnd[m.id];
      final score = UrgencyScore(
        ratioConsumed: capRatio(qualified, m.thresholdSpend),
        daysRemaining: end == null ? null : daysUntil(end, DateTime.now()),
      );
      if (mostUrgentMilestone == null || score.compareTo(mostUrgentMilestone) < 0) {
        mostUrgentMilestone = score;
      }
    }
    UrgencyScore? mostUrgentFeeWaiver;
    for (final fw in feeWaiverRows) {
      final score = UrgencyScore(
        ratioConsumed: capRatio(fw.qualifiedSpend, fw.thresholdSpend),
        daysRemaining: daysUntil(fw.periodEnd, DateTime.now()),
      );
      if (mostUrgentFeeWaiver == null || score.compareTo(mostUrgentFeeWaiver) < 0) {
        mostUrgentFeeWaiver = score;
      }
    }

    // E1 is the single entry point to every E-screen (see class doc-comment)
    // — Caps/Milestones/Fee Waivers must stay reachable even for a user with
    // no cap/milestone-bearing cards yet, so these three always render.
    // Falling back to UrgencyScore() (0 ratio, "effectively never" days)
    // only affects sort position, pushing an empty tile to the back
    // alongside the other unordered tiles rather than hiding it.
    final urgentTiles = <(UrgencyScore, _InsightTile)>[
      (
        mostUrgentCap ?? UrgencyScore(),
        _InsightTile(
          icon: Icons.speed_rounded,
          label: 'Caps & Limits',
          headline: capRows.isEmpty ? null : '${capRows.length} tracked',
          onTap: () => context.push(AppRoute.caps),
        ),
      ),
      (
        mostUrgentMilestone ?? UrgencyScore(),
        _InsightTile(
          icon: Icons.flag_outlined,
          label: 'Milestones',
          headline: milestoneRows.isEmpty ? null : '${milestoneRows.length} active',
          onTap: () => context.push(AppRoute.milestones),
        ),
      ),
      (
        mostUrgentFeeWaiver ?? UrgencyScore(),
        _InsightTile(
          icon: Icons.card_giftcard_outlined,
          label: 'Fee Waivers',
          headline: feeWaiverRows.isEmpty ? null : '${feeWaiverRows.length} tracked',
          onTap: () => context.push(AppRoute.feeWaivers),
        ),
      ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    final unorderedTiles = <_InsightTile>[
      _InsightTile(
        icon: Icons.event_available_outlined,
        label: 'Billing Float',
        headline: null,
        onTap: () => context.push(AppRoute.billingFloat),
      ),
      _InsightTile(
        icon: Icons.pie_chart_outline_rounded,
        label: 'Credit Utilization',
        headline: null,
        onTap: () => context.push(AppRoute.creditUtilization),
      ),
      _InsightTile(
        icon: Icons.airline_seat_flat_angled_rounded,
        label: 'Lounge Access',
        headline: null,
        onTap: () => context.push(AppRoute.loungeAccess),
      ),
      _InsightTile(
        icon: Icons.calendar_month_outlined,
        label: 'Due Dates',
        headline: null,
        onTap: () => context.push(AppRoute.dueDateCalendar),
      ),
      _InsightTile(
        icon: Icons.savings_outlined,
        label: 'Savings Report',
        headline: null,
        onTap: () => context.push(AppRoute.monthlySavings),
      ),
      _InsightTile(
        icon: Icons.fact_check_outlined,
        label: 'Portfolio Audit',
        headline: null,
        onTap: () => context.push(AppRoute.portfolioAudit),
      ),
      _InsightTile(
        icon: Icons.donut_small_outlined,
        label: 'Spending Overview',
        headline: null,
        onTap: () => context.push(AppRoute.spendingOverview),
      ),
      _InsightTile(
        icon: Icons.diversity_3_outlined,
        label: 'My Contributions',
        headline: null,
        onTap: () => context.push(AppRoute.myContributions),
      ),
      _InsightTile(
        icon: Icons.receipt_long_rounded,
        label: 'All Activity',
        headline: null,
        onTap: () => context.push(AppRoute.activity),
      ),
      _InsightTile(
        icon: Icons.trending_down_rounded,
        label: 'Missed Opportunities',
        headline: null,
        onTap: () => context.push(AppRoute.missedOpportunities),
      ),
      // Task D-4: needsReviewCountProvider is on-device only (see
      // NeedsReviewRepository's doc-comment) — this tile is its one
      // visible entry point outside the SMS import screens themselves.
      _InsightTile(
        icon: Icons.mark_email_unread_outlined,
        label: 'Needs Review',
        headline: needsReviewCount > 0 ? '$needsReviewCount' : null,
        onTap: () => context.push(AppRoute.needsReview),
      ),
      _InsightTile(
        icon: Icons.content_copy_outlined,
        label: 'Duplicate Review',
        headline: null,
        onTap: () => context.push(AppRoute.duplicateReview),
      ),
    ];

    final tiles = [for (final (_, tile) in urgentTiles) tile, ...unorderedTiles];
    final period = ref.watch(insightsPeriodProvider);
    final overview = ref.watch(insightsOverviewProvider(period));

    return AppBackground(
      child: ListView(
        // Named so tests can target this scroll view specifically — the
        // period chip row is a second, horizontal Scrollable on this screen,
        // so a bare find.byType(Scrollable) is ambiguous here.
        key: const ValueKey('insightsScroll'),
        // Status bar above (the shell draws no AppBar), nav-pill clearance
        // below (the pill floats over this content) — see AppShell.
        padding: EdgeInsets.fromLTRB(
          AppSpace.lg,
          MediaQuery.paddingOf(context).top + AppSpace.lg,
          AppSpace.lg,
          AppShell.navClearance,
        ),
        children: [
          Text(
            'Insights',
            style: BambooFonts.heading(28, weight: FontWeight.w800, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.md),
          const _PeriodChips(),
          OfflineBanner(gutter: 0, onRetry: () => ref.invalidate(insightsOverviewProvider(period))),
          const SizedBox(height: AppSpace.lg),
          overview.when(
            loading: () => const SkeletonList(count: 3),
            error: (err, _) => ErrorState(
              message: userFacingErrorMessage(err),
              onRetry: () => ref.invalidate(insightsOverviewProvider(period)),
            ),
            data: (data) => _OverviewSections(data: data, milestones: milestoneRows),
          ),
          const SizedBox(height: AppSpace.xxl),
          // The tile grid the whole screen used to be. Design 04 puts real
          // content first and doesn't show these at all, but every one of
          // them is a shipped E-screen whose only entry point is here —
          // dropping them to match the deck literally would strand a dozen
          // features, so they keep their grid below the fold under a header
          // that says what they are.
          Text(
            'MORE INSIGHTS',
            style: BambooFonts.ui(
              12,
              weight: FontWeight.w700,
              color: BambooInk.ink500,
            ).copyWith(letterSpacing: 1.1),
          ),
          const SizedBox(height: AppSpace.md),
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: AppSpace.md,
              mainAxisSpacing: AppSpace.md,
              childAspectRatio: 1.1,
            ),
            children: tiles,
          ),
        ],
      ),
    );
  }
}

/// Design 04's period chip row. Same visual language as design 01's
/// category chips — unselected glass with a hairline, selected solid
/// slate — so the two tabs read as one app.
class _PeriodChips extends ConsumerWidget {
  const _PeriodChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(insightsPeriodProvider);
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final period in InsightsPeriod.values)
            Padding(
              padding: const EdgeInsets.only(right: AppSpace.sm),
              child: Pressable(
                enforceMinTarget: false,
                onTap: () => ref.read(insightsPeriodProvider.notifier).state = period,
                semanticLabel: period.label,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  decoration: BoxDecoration(
                    color: period == selected ? BambooInk.slate : BambooInk.glassFillOnPaper,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: period == selected ? BambooInk.slate : BambooInk.hairlineOnPaper,
                    ),
                  ),
                  child: Text(
                    period.label,
                    style: BambooFonts.ui(
                      13.5,
                      weight: FontWeight.w600,
                      color: period == selected ? BambooInk.onSlate : BambooInk.ink900,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Design 04's content, top to bottom: the earned hero, the category
/// breakdown, the missed/best-category pair, the missed-opportunities
/// preview, and the milestone in reach.
class _OverviewSections extends StatelessWidget {
  final InsightsOverview data;
  final List<(UserCard, MilestoneRule)> milestones;

  const _OverviewSections({required this.data, required this.milestones});

  @override
  Widget build(BuildContext context) {
    if (data.transactionCount == 0) {
      return const EmptyState(
        icon: Icons.insights_outlined,
        title: 'Nothing to report yet',
        message: 'Log a payment and this fills in with what you earned and what you left behind.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _EarnedHero(data: data),
        if (data.byCategory.isNotEmpty) ...[
          const SizedBox(height: AppSpace.lg),
          _CategoryBars(categories: data.byCategory),
        ],
        const SizedBox(height: AppSpace.lg),
        _MissedAndBest(data: data),
        if (data.topMissed.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xl),
          _MissedPreview(rows: data.topMissed),
        ],
        _MilestoneInReach(milestones: milestones),
      ],
    );
  }
}

/// Design 04's hero: the slate panel carrying the one number the tab
/// exists to report, with the spend it came off and the effective rate it
/// works out to.
class _EarnedHero extends StatelessWidget {
  final InsightsOverview data;
  const _EarnedHero({required this.data});

  @override
  Widget build(BuildContext context) {
    final rate = data.effectiveRatePct;
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(28),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REWARDS EARNED',
            style: BambooFonts.ui(
              11,
              weight: FontWeight.w700,
              color: BambooInk.onSlateMuted,
            ).copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: AppSpace.sm),
          // Lime on slate — the one place the accent is allowed to carry a
          // number, per the palette rule in app_theme.dart.
          MoneyText(
            data.earned,
            confidence: Confidence.confirmed,
            style: BambooFonts.money(40, color: BambooInk.lime),
            hidePaise: true,
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Text('on ', style: BambooFonts.ui(12.5, color: BambooInk.onSlateSubtle)),
              MoneyText(
                data.spend,
                confidence: Confidence.confirmed,
                style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.onSlateSubtle),
                hidePaise: true,
                showConfidenceIcon: false,
              ),
              Text(
                rate == null ? ' of spend' : ' of spend · ${rate.toStringAsFixed(1)}% effective',
                style: BambooFonts.ui(12.5, color: BambooInk.onSlateSubtle),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Design 04's category breakdown. Bars are proportional to the largest
/// category rather than to the total, so a month dominated by one category
/// still shows readable bars for the rest.
class _CategoryBars extends StatelessWidget {
  final List<CategoryEarning> categories;
  const _CategoryBars({required this.categories});

  @override
  Widget build(BuildContext context) {
    final top = categories.take(5).toList();
    final maxPaise = top.first.earned.paise;

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Where it came from', style: BambooFonts.heading(15, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.md),
          for (final category in top) ...[
            Semantics(
              label: '${category.label}, ${category.earned.format()} earned',
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(category.label, style: BambooFonts.ui(13, color: BambooInk.ink900)),
                        ),
                        MoneyText(
                          category.earned,
                          confidence: Confidence.confirmed,
                          style: BambooFonts.money(13, color: BambooInk.ink900),
                          hidePaise: true,
                          showConfidenceIcon: false,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: maxPaise == 0 ? 0 : category.earned.paise / maxPaise,
                        minHeight: 6,
                        backgroundColor: BambooInk.paperMuted,
                        valueColor: const AlwaysStoppedAnimation(BambooInk.slate),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (category != top.last) const SizedBox(height: AppSpace.md),
          ],
        ],
      ),
    );
  }
}

/// Design 04's paired tiles: what slipped, and what worked. Clay on the
/// left, jade on the right — the deck's own two-tier semantic pair.
class _MissedAndBest extends StatelessWidget {
  final InsightsOverview data;
  const _MissedAndBest({required this.data});

  @override
  Widget build(BuildContext context) {
    final best = data.bestCategory;
    // IntrinsicHeight so the two tiles match height whichever caption wraps
    // further. `stretch` alone can't do it here: this sits in a ListView, so
    // the Row's height constraint is unbounded and stretching to it asserts.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _StatTile(
              label: 'Left on the table',
              value: data.missed,
              // Estimated, not confirmed: the comparator behind this can't see
              // historical cap state. See InsightsOverview.missedIsEstimate.
              confidence: Confidence.estimated,
              valueColor: BambooInk.clay,
              caption: data.missedCount == 0
                  ? 'Every payment used one of your best cards'
                  : '${data.missedCount} ${data.missedCount == 1 ? 'swipe' : 'swipes'} on the wrong card',
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: best == null
                ? const _StatTile(
                    label: 'Best category',
                    value: null,
                    confidence: Confidence.confirmed,
                    valueColor: BambooInk.ink900,
                    caption: 'Categorise a payment to see this',
                  )
                : _StatTile(
                    label: 'Best category',
                    value: best.earned,
                    confidence: Confidence.confirmed,
                    valueColor: BambooInk.ink900,
                    caption: '${best.label} earned the most',
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final Money? value;
  final Confidence confidence;
  final Color valueColor;
  final String caption;

  const _StatTile({
    required this.label,
    required this.value,
    required this.confidence,
    required this.valueColor,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.sm),
          if (value == null)
            Text('—', style: BambooFonts.money(22, color: BambooInk.ink300))
          else
            MoneyText(
              value!,
              confidence: confidence,
              style: BambooFonts.money(22, color: valueColor),
              hidePaise: true,
            ),
          const SizedBox(height: 6),
          Text(caption, style: BambooFonts.ui(12, color: BambooInk.ink500)),
        ],
      ),
    );
  }
}

/// Design 04's "Missed opportunities · See all" preview — the three
/// biggest, with the full D6 screen one tap away.
class _MissedPreview extends StatelessWidget {
  final List<MissedEarning> rows;
  const _MissedPreview({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Missed opportunities', style: BambooFonts.heading(17, color: BambooInk.ink900)),
            ),
            TextButton(
              onPressed: () => GoRouter.of(context).push(AppRoute.missedOpportunities),
              style: TextButton.styleFrom(
                foregroundColor: BambooInk.ink900,
                minimumSize: const Size(44, 44),
                textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
              ),
              child: const Text('See all'),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Container(
              decoration: BoxDecoration(
                color: BambooInk.glassFillOnPaper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              padding: const EdgeInsets.all(AppSpace.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.entry.merchantName ?? row.entry.categoryName ?? 'Payment',
                          style: BambooFonts.ui(14, weight: FontWeight.w600, color: BambooInk.ink900),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${row.betterCard.name} would have paid more',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  MoneyText(
                    row.missed,
                    confidence: Confidence.estimated,
                    style: BambooFonts.money(15, color: BambooInk.clay),
                    hidePaise: true,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Design 04's "Milestone in reach" card — the single milestone closest to
/// paying out, with how much more spend it needs.
///
/// Silent when the user has no milestone-bearing cards, or when every
/// milestone is already met: the deck shows one card here, and an empty
/// "nothing in reach" panel would be noise on a screen that is already
/// dense.
class _MilestoneInReach extends StatelessWidget {
  final List<(UserCard, MilestoneRule)> milestones;
  const _MilestoneInReach({required this.milestones});

  @override
  Widget build(BuildContext context) {
    (UserCard, MilestoneRule, Money, double)? closest;
    for (final (userCard, rule) in milestones) {
      final qualified = userCard.milestoneQualifiedSpend[rule.id] ?? const Money.zero();
      if (rule.thresholdSpend.paise <= 0) continue;
      final progress = qualified.paise / rule.thresholdSpend.paise;
      if (progress >= 1.0) continue; // already earned — not "in reach"
      final remaining = rule.thresholdSpend - qualified;
      if (closest == null || progress > closest.$4) {
        closest = (userCard, rule, remaining, progress);
      }
    }
    if (closest == null) return const SizedBox.shrink();

    final (_, rule, remaining, progress) = closest;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xl),
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.rankBadgeBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: BambooInk.rankBadgeBorder),
        ),
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Milestone in reach',
              style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.rankBadgeInk),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                MoneyText(
                  remaining,
                  confidence: Confidence.confirmed,
                  style: BambooFonts.money(20, color: BambooInk.ink900),
                  hidePaise: true,
                  showConfidenceIcon: false,
                ),
                Flexible(
                  child: Text(
                    ' more to go — ${rule.label}',
                    style: BambooFonts.ui(13, color: BambooInk.ink900),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: BambooInk.paper,
                valueColor: const AlwaysStoppedAnimation(BambooInk.jade),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InsightTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? headline;
  final VoidCallback onTap;

  const _InsightTile({required this.icon, required this.label, required this.headline, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // See account_screen.dart's _AccountTile for why Pressable, not
    // Material+InkWell.
    return Pressable(
      key: ValueKey(label),
      onTap: onTap,
      semanticLabel: headline == null ? label : '$label, $headline',
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: BambooInk.hairlineOnPaper),
          boxShadow: [
            BoxShadow(
              color: BambooInk.ink900.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: BambooInk.slate, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: BambooInk.lime, size: 20),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: BambooFonts.heading(14, color: BambooInk.ink900)),
                if (headline != null) ...[
                  const SizedBox(height: 2),
                  Text(headline!, style: BambooFonts.ui(12, color: BambooInk.ink500)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
