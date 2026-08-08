import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md E4 Milestones. `MilestoneRule` (threshold, reward) and
/// `UserCard.milestoneQualifiedSpend` (this period's progress — Chunk 17)
/// were both fully wired before this screen existed to show them.
/// Task E4 additions: days-left (from `UserCard.milestonePeriodEnd`, Task
/// E-0's fold-in of `period_end` into GET /user-cards) and the
/// "chasing beats base rate" flag (`evaluateMilestoneChase`, new pure
/// function in pandapay_domain next to calculators.dart's other one-off
/// comparisons, per the plan).
class MilestonesScreen extends ConsumerWidget {
  const MilestonesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(ownedCardsWithProductProvider);
    return pairs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (owned) {
        final rows = <(UserCard, CardProduct, MilestoneRule)>[
          for (final (userCard, product) in owned)
            for (final milestone in product.milestoneRules) (userCard, product, milestone),
        ];
        // Task E-0c: nearest-deadline/closest-to-target first, same shared
        // scorer E1/E2 use.
        rows.sort((a, b) {
          final qualifiedA = a.$1.milestoneQualifiedSpend[a.$3.id] ?? const Money.zero();
          final qualifiedB = b.$1.milestoneQualifiedSpend[b.$3.id] ?? const Money.zero();
          final endA = a.$1.milestonePeriodEnd[a.$3.id];
          final endB = b.$1.milestonePeriodEnd[b.$3.id];
          final scoreA = UrgencyScore(
            ratioConsumed: capRatio(qualifiedA, a.$3.thresholdSpend),
            daysRemaining: endA == null ? null : daysUntil(endA, DateTime.now()),
          );
          final scoreB = UrgencyScore(
            ratioConsumed: capRatio(qualifiedB, b.$3.thresholdSpend),
            daysRemaining: endB == null ? null : daysUntil(endB, DateTime.now()),
          );
          return scoreA.compareTo(scoreB);
        });
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.flag_outlined,
            title: 'No milestones to chase',
            message: 'None of your cards have spend milestones — or you haven\'t added a card yet.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(AppSpace.lg),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final (userCard, product, milestone) = rows[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _MilestoneTile(userCard: userCard, product: product, milestone: milestone),
            );
          },
        );
      },
    );
  }
}

class _MilestoneTile extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final MilestoneRule milestone;
  const _MilestoneTile({required this.userCard, required this.product, required this.milestone});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final qualified = userCard.milestoneQualifiedSpend[milestone.id] ?? const Money.zero();
    final remainingPaise =
        (milestone.thresholdSpend.paise - qualified.paise).clamp(0, milestone.thresholdSpend.paise);
    final remaining = Money.fromPaise(remainingPaise);
    final ratio = milestone.thresholdSpend.isZero
        ? 0.0
        : (qualified.paise / milestone.thresholdSpend.paise).clamp(0.0, 1.0);
    final reached = remainingPaise == 0;

    final periodEnd = userCard.milestonePeriodEnd[milestone.id];
    final daysLeft = periodEnd == null ? null : daysUntil(periodEnd, DateTime.now());

    // "Chasing beats base rate": the milestone's marginal ₹/₹ vs. the
    // card's base reward rate (categoryId == null, lowest priority wins —
    // same rule-selection RecommendationEngine._evaluate uses for "all
    // other spends").
    final baseRule = product.rewardRules.where((r) => r.categoryId == null).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    MilestoneChase? chase;
    if (!reached && baseRule.isNotEmpty) {
      final baseRate =
          baseRule.first.unit.effectiveRatePerRupee(baseRule.first.rate, pointValueInr: product.pointValueInr);
      chase = evaluateMilestoneChase(
        rewardValue: milestone.rewardValue,
        remainingSpend: remaining,
        baseRatePerRupee: baseRate,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: reached ? AppColors.successBg : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: reached ? AppColors.success : AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(milestone.label, style: textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (reached)
                const StatusPill(
                  label: 'REACHED',
                  foreground: Colors.white,
                  background: AppColors.success,
                  icon: Icons.check_rounded,
                )
              else if (milestone.isRepeatable)
                const StatusPill(label: 'Repeats', foreground: AppColors.navy800, background: AppColors.surfaceMuted),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: AppColors.surfaceMuted,
              color: reached ? AppColors.success : AppColors.teal600,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                reached ? 'Milestone reached' : '${remaining.format()} to go',
                style: textTheme.labelLarge?.copyWith(color: reached ? AppColors.success : AppColors.navy800),
              ),
              Row(
                children: [
                  Text('Reward ', style: textTheme.bodySmall),
                  MoneyText(milestone.rewardValue, confidence: Confidence.estimated, style: textTheme.bodySmall),
                ],
              ),
            ],
          ),
          if (!reached && daysLeft != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              daysLeft >= 0 ? '$daysLeft days left this period' : 'Period ended ${-daysLeft} days ago',
              style: textTheme.bodySmall?.copyWith(color: AppColors.ink500),
            ),
          ],
          if (chase != null && chase.beatsBaseRate) ...[
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 14, color: AppColors.teal600),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Chasing this beats your base rate — worth prioritizing this spend here.',
                    style: textTheme.bodySmall?.copyWith(color: AppColors.teal600, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
