import '../money/money.dart';

/// Task E4 (implementation-plan-group-e-f-g.md §2) — "chasing beats base
/// rate" flag. A milestone's implied marginal ₹-of-reward per ₹-of-spend
/// (reward ÷ remaining spend needed) compared against the card's base
/// reward rate (already a ₹-per-₹ fraction, e.g. 0.02 for 2% cashback) —
/// if the milestone's marginal rate beats the base rate, actively chasing
/// it is worth more than the card's normal earn rate on that same spend,
/// which is the whole point of surfacing it.
class MilestoneChase {
  final double marginalRatePerRupee; // reward.paise / remainingSpend.paise
  final bool beatsBaseRate;

  const MilestoneChase({required this.marginalRatePerRupee, required this.beatsBaseRate});
}

/// [remainingSpend] must be the milestone's still-needed spend (threshold -
/// qualified so far), already clamped to >= 0 by the caller — a milestone
/// already reached has no meaningful "chasing" rate, so callers should
/// special-case `remainingSpend.isZero` before calling this (a zero
/// remaining spend here returns beatsBaseRate: false rather than dividing
/// by zero).
MilestoneChase evaluateMilestoneChase({
  required Money rewardValue,
  required Money remainingSpend,
  required double baseRatePerRupee,
}) {
  if (remainingSpend.isZero) {
    return const MilestoneChase(marginalRatePerRupee: 0, beatsBaseRate: false);
  }
  final marginal = rewardValue.paise / remainingSpend.paise;
  return MilestoneChase(
    marginalRatePerRupee: marginal,
    beatsBaseRate: marginal > baseRatePerRupee,
  );
}
