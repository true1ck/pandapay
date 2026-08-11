import '../card_rules/card_rules.dart';
import '../money/money.dart';

/// Task D-13 (implementation-plan-group-c-d.md's flagged largest technical
/// risk in Group D) — "was this transaction's card the best choice, in
/// hindsight?" Shared by D1's row-level optimality indicator and D6
/// Missed Opportunities, so the two never disagree about the same
/// transaction.
///
/// **Deliberately scoped, not a full historical engine replay.** A fully
/// accurate answer would need each owned card's cap/milestone/fee-waiver
/// STATE exactly as it stood on the transaction's date — this schema only
/// ever stores the CURRENT period's state (cap_states/milestone_states are
/// upserted in place, not append-only history), so that state is
/// unrecoverable for a past transaction after the fact. Building an
/// append-only state history table would be a real, much larger project,
/// not attempted in this pass.
///
/// What this DOES compare, honestly: the BASE reward rate (category match,
/// no cap/milestone/forex/fuel adjustment) each owned card would have
/// earned on this transaction's category and amount, using the exact same
/// rule-selection convention (lowest-priority-number reward_rules row
/// wins; `categoryId == null` is the base "all other spends" rate) already
/// used by RecommendationEngine, api/'s insertTransactionAndUpdateState,
/// and MilestonesScreen's "chasing beats base rate" flag — so this stays
/// consistent with every other place in the app that answers "what would
/// this card have earned," rather than inventing a fourth slightly-
/// different version. `flat_points` rules contribute zero comparable value
/// here, same convention the server-side helper already uses (a fixed
/// bonus isn't a per-transaction rate).
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

  Money get missedValue => hadBetterOption ? (betterValue - actualValue) : const Money.zero();
}

/// The BASE reward rate (category match, no cap/milestone/forex/fuel
/// adjustment) [product] would earn on a transaction of [amount] in
/// [categoryId] — same rule-selection convention as everywhere else that
/// answers "what would this card have earned" (see the class doc-comment
/// above). Exported on its own, not just inlined into
/// [compareToOwnedCards], because E9 Monthly Savings Report's
/// baseline_single_card ("what a single best-overall card would have
/// earned across the WHOLE month") needs the exact same per-transaction
/// rate applied card-by-card across many transactions, not just the
/// pairwise "better than what was used" comparison this file was built
/// for — reusing this keeps both screens' numbers consistent with each
/// other instead of growing a second, slightly different rate calculator.
Money baseRateValueFor({
  required CardProduct product,
  required Money amount,
  String? categoryId,
}) {
  final matching = product.rewardRules.where((r) => r.categoryId == null || r.categoryId == categoryId).toList()
    ..sort((a, b) => a.priority.compareTo(b.priority));
  if (matching.isEmpty) return const Money.zero();
  final rule = matching.first;
  if (rule.unit == RewardUnit.flatPoints) return const Money.zero();
  final rate = rule.unit.effectiveRatePerRupee(rule.rate, pointValueInr: product.pointValueInr);
  return amount * rate;
}

/// [ownedCards] must include [usedCard] itself (its own base rate is one of
/// the candidates compared, so a card that WAS the best choice correctly
/// produces `hadBetterOption == false` rather than always finding
/// something "better").
HistoricalCardComparison compareToOwnedCards({
  required CardProduct usedCard,
  required List<CardProduct> ownedCards,
  required Money amount,
  String? categoryId,
}) {
  Money valueFor(CardProduct product) => baseRateValueFor(product: product, amount: amount, categoryId: categoryId);

  final actualValue = valueFor(usedCard);

  CardProduct? bestOther;
  var bestOtherValue = const Money.zero();
  for (final card in ownedCards) {
    if (card.id == usedCard.id) continue;
    final value = valueFor(card);
    if (bestOther == null || value > bestOtherValue) {
      bestOther = card;
      bestOtherValue = value;
    }
  }

  final hasBetter = bestOther != null && bestOtherValue > actualValue;
  return HistoricalCardComparison(
    usedCard: usedCard,
    actualValue: actualValue,
    betterCard: hasBetter ? bestOther : null,
    betterValue: hasBetter ? bestOtherValue : actualValue,
  );
}
