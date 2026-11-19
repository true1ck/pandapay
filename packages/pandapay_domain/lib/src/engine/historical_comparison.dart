import '../card_rules/card_rules.dart';
import '../money/money.dart';

/// "Was this transaction's card the best choice, in hindsight?" — the result
/// type shared by the Rewards page's Missed tab and the Insights hub, built by
/// [SpendComparer] (`spend_comparison.dart`).
///
/// **Deliberately scoped, not a full historical engine replay.** A fully
/// accurate answer would need each owned card's cap/milestone/fee-waiver
/// STATE exactly as it stood on the transaction's date — this schema only
/// ever stores the CURRENT period's state (cap_states/milestone_states are
/// upserted in place, not append-only history), so that state is
/// unrecoverable for a past transaction after the fact. What the comparison
/// does use is each card's own earning rules for the spend (category,
/// merchant, minimum spend, exclusions), exactly as the reward engine reads
/// them; caps and milestones are left out, so a gap is an estimate.
class HistoricalCardComparison {
  final CardProduct usedCard;
  final Money actualValue;
  final CardProduct? betterCard;
  final Money betterValue;

  const HistoricalCardComparison({
    required this.usedCard,
    required this.actualValue,
    this.betterCard,
    required this.betterValue,
  });

  bool get hadBetterOption => betterCard != null;

  Money get missedValue {
    if (!hadBetterOption) return const Money.zero();
    final delta = betterValue - actualValue;
    // This is an opportunity-cost figure, never a debit. Keep the domain
    // Money type signed for refunds, but do not let a comparison inversion
    // leak a negative "missed" value into Insights.
    return delta.isNegative ? const Money.zero() : delta;
  }
}

/// The BASE reward [product] would earn on a purchase of [amount] in
/// [categoryId], with nothing known about the merchant: `amount *`
/// [baseRatePerRupee]. For a person's own spends use [SpendComparer], which
/// prices the real merchant, rail and date through the reward engine; this is
/// the "unknown shop" answer (the Split planner's whole-purchase baseline).
Money baseRateValueFor({
  required CardProduct product,
  required Money amount,
  String? categoryId,
}) {
  if (amount.isZero || amount.isNegative) return const Money.zero();
  return amount * baseRatePerRupee(product: product, categoryId: categoryId);
}

/// An earning rule that pays on any purchase in its category, with no
/// condition on the merchant, payment platform, MCC list or rail. Those are the
/// only rules that say what a card pays "in general".
///
/// A rule's minimum spend is deliberately not a condition here: the base rule
/// of most v2 cards reads "1% on spends of ₹100 or more", and a general rate
/// is about ordinary purchases, not a ₹40 chai.
bool _paysInGeneral(RewardRule rule) {
  if (rule.isV1Only) return false;
  final role = rule.effectiveRole;
  if (role != RuleRole.earn && role != RuleRole.base) return false;
  final pattern = rule.merchantPattern;
  return rule.merchantSlugs.isEmpty &&
      (pattern == null || pattern.trim().isEmpty) &&
      rule.platformSlugs.isEmpty &&
      rule.mccInclude.isEmpty &&
      rule.rail == null;
}

/// The share of a purchase [product] pays in [categoryId] with nothing else
/// known about it, clamped to 0..1: [baseRateValueFor] is
/// `amount * baseRatePerRupee(...)`.
///
/// The rate comes from the card's general earning rules for the category (a
/// category rule, else the all-other-spends rule) by priority, then the card's
/// own stated base rate when the catalogue wrote no general rule. A category
/// the card leaves out of rewards pays 0.
///
/// This used to pick the lowest-priority rule among every rule with no
/// category. On the v2 catalogue that is an exclusion (a "no rewards under
/// ₹100" or EMI rule at priority 0), so every card read as 0% and no card was
/// ever better than another. Exclusion, info and conditional rules are not
/// general earning rules and are never picked here.
///
/// A base-rate reward is a portion of the purchase value, not a debt or a
/// bonus unrelated to the purchase. Catalogue mistakes (for example a
/// malformed points value/rate) must not produce an impossible reward that is
/// below zero or larger than the spend itself, hence the clamp.
double baseRatePerRupee({required CardProduct product, String? categoryId}) {
  if (product.excludesCategory(categoryId)) return 0;
  final rules = uniqueRewardRules(product.rewardRules);
  // A rule that keeps this whole category out of rewards (rent, wallet loads).
  final categoryExcluded = categoryId != null &&
      rules.any(
        (r) =>
            !r.isV1Only &&
            r.effectiveRole == RuleRole.exclusion &&
            r.categoryId == categoryId &&
            r.merchantSlugs.isEmpty &&
            r.platformSlugs.isEmpty &&
            r.mccInclude.isEmpty &&
            r.rail == null &&
            r.maxTxn == null,
      );
  if (categoryExcluded) return 0;
  final matching = rules
      .where(
        (r) =>
            _paysInGeneral(r) &&
            (r.categoryId == null || r.categoryId == categoryId),
      )
      .toList()
    ..sort((a, b) {
      final byPriority = a.priority.compareTo(b.priority);
      if (byPriority != 0) return byPriority;
      // A rule for this very category over the all-other-spends rule.
      if ((a.categoryId == null) != (b.categoryId == null)) {
        return a.categoryId == null ? 1 : -1;
      }
      return b.rate.compareTo(a.rate);
    });
  double rate;
  if (matching.isEmpty) {
    rate = product.baseRatePerRupee;
  } else {
    final rule = matching.first;
    if (rule.unit == RewardUnit.flatPoints) return 0;
    rate = rule.unit.effectiveRatePerRupee(
      rule.rate,
      pointValueInr: product.pointValueInr,
    );
  }
  if (rate < 0) return 0;
  if (rate > 1) return 1;
  return rate;
}
