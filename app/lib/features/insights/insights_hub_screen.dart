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
/// "12 tracked · 3 active" — one line covering everything behind the
/// Limits & perks tile, so collapsing four tiles into one doesn't cost the
/// at-a-glance counts the separate tiles used to give.
String? _limitsHeadline(int caps, int milestones, int feeWaivers) {
  final parts = <String>[
    if (caps > 0) '$caps cap${caps == 1 ? '' : 's'}',
    if (milestones > 0) '$milestones milestone${milestones == 1 ? '' : 's'}',
    if (feeWaivers > 0) '$feeWaivers waiver${feeWaivers == 1 ? '' : 's'}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

class InsightsHubScreen extends ConsumerWidget {
  const InsightsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
    // The two review queues are ACTIONS, not insights, so they no longer
    // take up two permanent tiles in the grid. They appear as a single row
    // above it, and only when there is actually something to do — a queue
    // that is empty most of the time does not deserve standing real estate.
    final needsReviewCount = ref.watch(needsReviewCountProvider);
    final duplicateCount = ref.watch(duplicateCandidatesProvider).valueOrNull?.length ?? 0;

    // A budget that needs attention is the one thing on this hub worth
    // saying before the user taps anything, so it rides on the tile itself.
    final flaggedBudgets = ref.watch(budgetsNeedingAttentionProvider);
    final budgetHeadline = flaggedBudgets.isEmpty
        ? null
        : flaggedBudgets.first.isOver
            ? 'Over on ${flaggedBudgets.first.label}'
            : 'Ahead of pace';

    // Shown on the tile because the annual figure is the whole point: a
    // ₹649 monthly charge doesn't feel like much, and ₹7,788 a year does.
    final recurring = ref.watch(recurringReportProvider).valueOrNull;
    final subscriptionHeadline = recurring == null || recurring.series.isEmpty
        ? null
        : '${recurring.totalAnnual.format(compact: true)}/yr';

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

    // SIX tiles, not eighteen.
    //
    // This grid had grown one tile per shipped screen, and most of them
    // answered slices of the same few questions: Caps/Milestones/Fee
    // Waivers/Lounge are all "progress toward a threshold on a card";
    // Savings/Missed/Portfolio are all "did this wallet pay off";
    // Due Dates/Float/Utilization are all "when and how much to pay". Laid
    // out as eighteen equal choices, the grouping had to happen in the
    // user's head every single time — and "Spending Overview" had become a
    // strict subset of "Spending" once the latter gained periods, a
    // previous-period comparison and a per-card split.
    //
    // Each tile below opens a GroupedInsightScreen holding the ORIGINAL
    // screens as tabs. Nothing was deleted and every old route still works;
    // what changed is how many decisions the hub asks for at once.
    final urgentTiles = <(UrgencyScore, _InsightTile)>[
      (
        // Sorted by whichever of its tabs is most urgent — a cap about to
        // run out should pull the tile up the grid even though the tile now
        // covers milestones and fee waivers too.
        [mostUrgentCap, mostUrgentMilestone, mostUrgentFeeWaiver]
                .nonNulls
                .fold<UrgencyScore?>(null, (a, b) => a == null || b.compareTo(a) < 0 ? b : a) ??
            UrgencyScore(),
        _InsightTile(
          icon: Icons.speed_rounded,
          label: 'Limits & perks',
          headline: _limitsHeadline(capRows.length, milestoneRows.length, feeWaiverRows.length),
          onTap: () => context.push(AppRoute.limitsAndPerks),
        ),
      ),
    ];

    final unorderedTiles = <_InsightTile>[
      // First two on purpose. "Where is my money going" and "am I over
      // budget" are the questions people open a spend tracker to ask;
      // everything else here answers a question about a card.
      _InsightTile(
        icon: Icons.show_chart_rounded,
        label: 'Spending',
        headline: 'Trends & reports',
        onTap: () => context.push(AppRoute.spendTrends),
      ),
      _InsightTile(
        icon: Icons.savings_outlined,
        label: 'Budgets',
        headline: budgetHeadline,
        onTap: () => context.push(AppRoute.budgets),
      ),
      _InsightTile(
        icon: Icons.workspace_premium_outlined,
        label: 'Rewards',
        headline: 'What your cards earned',
        onTap: () => context.push(AppRoute.rewardsGroup),
      ),
      _InsightTile(
        icon: Icons.event_available_outlined,
        label: 'Payments',
        headline: 'Due dates & credit',
        onTap: () => context.push(AppRoute.paymentsGroup),
      ),
      _InsightTile(
        icon: Icons.autorenew_rounded,
        label: 'Subscriptions',
        headline: subscriptionHeadline,
        onTap: () => context.push(AppRoute.subscriptions),
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
          if (needsReviewCount > 0 || duplicateCount > 0) ...[
            _ReviewRow(needsReview: needsReviewCount, duplicates: duplicateCount),
            const SizedBox(height: AppSpace.xl),
          ],
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
          const SizedBox(height: AppSpace.lg),
          // Not a seventh tile — a plain row, because the transaction list
          // is a destination rather than an insight.
          //
          // It also can't live ONLY inside Spending, which is where it sits
          // contextually: that screen shows a sign-in wall when signed out,
          // so burying Activity there made it unreachable for exactly the
          // users who most need to find the sign-in prompt behind it.
          _ActivityLink(),
        ],
      ),
    );
  }
}

/// The transaction list, as a row rather than a grid tile.
class _ActivityLink extends StatelessWidget {
  const _ActivityLink();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => context.push(AppRoute.activity),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
          child: Row(
            children: [
              const Icon(Icons.receipt_long_rounded, size: 18, color: BambooInk.ink500),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  'See every transaction',
                  style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: BambooInk.ink900),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20, color: BambooInk.ink500),
            ],
          ),
        ),
      ),
    );
  }
}

/// "3 to review" — the two transaction queues, shown only when non-empty.
///
/// Needs Review (a message we couldn't attribute) and Duplicate Review (a
/// possible double-count) both mean the same thing to the user: some
/// transactions need a decision. They held two permanent grid tiles that
/// read "0" most of the time, which is the worst kind of clutter — always
/// present, rarely relevant. Now they surface only when they have work in
/// them, and above the grid rather than buried in it, because an item
/// waiting on the user outranks anything they might browse to.
class _ReviewRow extends StatelessWidget {
  final int needsReview;
  final int duplicates;

  const _ReviewRow({required this.needsReview, required this.duplicates});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (needsReview > 0)
          _ReviewTile(
            icon: Icons.mark_email_unread_outlined,
            label: needsReview == 1 ? '1 message needs review' : '$needsReview messages need review',
            detail: 'We couldn\'t tell which card these belong to.',
            onTap: () => context.push(AppRoute.needsReview),
          ),
        if (needsReview > 0 && duplicates > 0) const SizedBox(height: AppSpace.sm),
        if (duplicates > 0)
          _ReviewTile(
            icon: Icons.content_copy_outlined,
            label: duplicates == 1 ? '1 possible duplicate' : '$duplicates possible duplicates',
            detail: 'Same amount and day from two different sources.',
            onTap: () => context.push(AppRoute.duplicateReview),
          ),
      ],
    );
  }
}

class _ReviewTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  const _ReviewTile({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BambooInk.paperMuted,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            children: [
              Icon(icon, size: 20, color: BambooInk.amber),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: BambooFonts.ui(13.5, weight: FontWeight.w700, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(detail, style: BambooFonts.ui(12, color: BambooInk.ink500)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20, color: BambooInk.ink500),
            ],
          ),
        ),
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
