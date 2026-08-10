import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../app/router.dart';

/// ui-spec.md E1 Insights Hub. Entry point to every E-screen. Task E-0
/// landing (credit_limit_inr/due_day/anniversary_on) unblocked E3/E5/E8's
/// tiles; E6/E9/E10/E11/E12 land in this same pass so their tiles ship
/// together rather than each needing a separate follow-up commit.
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
      for (final (userCard, product) in owned) for (final cap in product.capRules) (userCard, cap),
    ];
    final milestoneRows = [
      for (final (userCard, product) in owned) for (final m in product.milestoneRules) (userCard, m),
    ];
    final feeWaiverRows = [
      for (final (userCard, _) in owned) for (final fw in userCard.feeWaiverStates) fw,
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
      if (mostUrgentMilestone == null || score.compareTo(mostUrgentMilestone) < 0) mostUrgentMilestone = score;
    }
    UrgencyScore? mostUrgentFeeWaiver;
    for (final fw in feeWaiverRows) {
      final score = UrgencyScore(
        ratioConsumed: capRatio(fw.qualifiedSpend, fw.thresholdSpend),
        daysRemaining: fw.periodEnd == null ? null : daysUntil(fw.periodEnd!, DateTime.now()),
      );
      if (mostUrgentFeeWaiver == null || score.compareTo(mostUrgentFeeWaiver) < 0) mostUrgentFeeWaiver = score;
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

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.9, -0.7),
          radius: 1.3,
          colors: [BambooInk.wash, BambooInk.paper],
          stops: [0.0, 0.6],
        ),
      ),
      child: GridView(
        padding: const EdgeInsets.all(AppSpace.lg),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: AppSpace.md,
          mainAxisSpacing: AppSpace.md,
          childAspectRatio: 1.1,
        ),
        children: tiles,
      ),
    );
  }
}

class _InsightTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? headline;
  final VoidCallback onTap;

  const _InsightTile({
    required this.icon,
    required this.label,
    required this.headline,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey(label),
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: BambooInk.hairlineOnPaper),
            boxShadow: [
              BoxShadow(color: BambooInk.ink900.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
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
      ),
    );
  }
}
