import 'engine.dart';
import '../card_rules/card_rules.dart';
import '../clock/clock.dart';
import '../money/money.dart';

/// UA-2.4.1 — E3 Credit Utilization. Informational only; product-plan §2.1
/// requires disclaiming this is not a credit-score guarantee (enforced at
/// the UI layer, not here — this is pure arithmetic).
class UtilizationResult {
  final double ratio; // 0.30 == 30%
  final bool overThreshold;
  final Money? splitRecommendationAmount; // how much to move to stay under threshold

  const UtilizationResult({
    required this.ratio,
    required this.overThreshold,
    this.splitRecommendationAmount,
  });
}

UtilizationResult creditUtilization(
  Money currentBalance,
  Money creditLimit, {
  double threshold = 0.30,
}) {
  if (creditLimit.isZero) {
    return const UtilizationResult(ratio: 0, overThreshold: false);
  }
  final ratio = currentBalance.paise / creditLimit.paise;
  final overThreshold = ratio > threshold;
  Money? splitAmount;
  if (overThreshold) {
    final thresholdBalance = creditLimit * threshold;
    splitAmount = currentBalance - thresholdBalance;
  }
  return UtilizationResult(
    ratio: ratio,
    overThreshold: overThreshold,
    splitRecommendationAmount: splitAmount,
  );
}

/// One card's contribution to a split plan.
class SplitAllocation {
  final CardProduct card;
  final Money amount;
  final Money expectedValue;

  const SplitAllocation({required this.card, required this.amount, required this.expectedValue});
}

/// UA-2.4.2 / G2 — Multi-card split optimizer. Greedy fill by marginal ₹/₹:
/// repeatedly gives the next rupee to whichever card currently offers the
/// best marginal rate, respecting each card's cap headroom and an optional
/// per-card utilization ceiling. Bounded search (single pass, paise-level
/// increments capped at a coarse step) — not a full LP solver, which the
/// plan explicitly doesn't ask for ("bounded search").
class SplitOptimizer {
  final RecommendationEngine engine;

  const SplitOptimizer({this.engine = const RecommendationEngine()});

  List<SplitAllocation> optimize(
    Money totalAmount,
    RecommendationContext baseContext,
    List<CardSnapshot> cards, {
    Map<String, Money>? utilizationCeiling, // card.id -> max additional spend before 30%
    int stepCount = 20,
  }) {
    if (cards.isEmpty || totalAmount.isZero) return const [];

    final stepSize = Money.fromPaise((totalAmount.paise / stepCount).round());
    final remainingCeiling = {
      for (final s in cards)
        s.product.id: utilizationCeiling?[s.product.id] ?? const Money.fromPaise(1 << 50),
    };
    final allocated = {for (final s in cards) s.product.id: const Money.zero()};

    Money placed = const Money.zero();
    while (placed < totalAmount) {
      final stepAmount = (totalAmount - placed) < stepSize ? (totalAmount - placed) : stepSize;
      if (stepAmount.isZero) break;

      // Rank cards for this marginal chunk with each card's *already allocated*
      // amount folded into the context so cap blending reflects prior steps.
      final marginal = <String, Money>{};
      for (final snapshot in cards) {
        final consumedSoFar = allocated[snapshot.product.id]!;
        final adjustedSnapshot = _withReducedCaps(snapshot, consumedSoFar);
        final rec = engine
            .rank(
              RecommendationContext(
                amount: stepAmount,
                categoryId: baseContext.categoryId,
                mcc: baseContext.mcc,
                vpa: baseContext.vpa,
                rail: baseContext.rail,
                isP2P: baseContext.isP2P,
                travelMode: baseContext.travelMode,
                // Propagated, not dropped: a merchant-restricted or expired
                // rule must be evaluated identically on every marginal
                // step, or the split plan optimises against a rate the
                // card would not actually pay.
                merchantName: baseContext.merchantName,
                now: baseContext.now,
              ),
              [adjustedSnapshot],
            )
            .first;
        if (rec.isExcluded) continue;
        if (remainingCeiling[snapshot.product.id]!.isZero) continue;
        marginal[snapshot.product.id] = rec.expectedValue;
      }
      if (marginal.isEmpty) break; // nothing eligible for more spend

      final bestCardId =
          marginal.entries.reduce((a, b) => a.value.paise >= b.value.paise ? a : b).key;
      allocated[bestCardId] = allocated[bestCardId]! + stepAmount;
      remainingCeiling[bestCardId] = remainingCeiling[bestCardId]! - stepAmount;
      placed += stepAmount;
    }

    final result = <SplitAllocation>[];
    for (final snapshot in cards) {
      final amount = allocated[snapshot.product.id]!;
      if (amount.isZero) continue;
      final adjustedSnapshot = _withReducedCaps(snapshot, const Money.zero());
      final rec = engine
          .rank(
            RecommendationContext(
              amount: amount,
              categoryId: baseContext.categoryId,
              rail: baseContext.rail,
              travelMode: baseContext.travelMode,
              merchantName: baseContext.merchantName,
              now: baseContext.now,
            ),
            [adjustedSnapshot],
          )
          .first;
      result.add(SplitAllocation(card: snapshot.product, amount: amount, expectedValue: rec.expectedValue));
    }
    return result;
  }

  CardSnapshot _withReducedCaps(CardSnapshot snapshot, Money consumed) {
    if (consumed.isZero) return snapshot;
    final reduced = <String, Money>{};
    for (final entry in snapshot.capRemaining.entries) {
      final remaining = entry.value - consumed;
      reduced[entry.key] = remaining.isNegative ? const Money.zero() : remaining;
    }
    return CardSnapshot(
      product: snapshot.product,
      capRemaining: reduced,
      milestoneProgress: snapshot.milestoneProgress,
      forcedOverrideCardId: snapshot.forcedOverrideCardId,
    );
  }
}

/// UA-2.4.3 / E7 — Billing-cycle float: interest-free days remaining from
/// today given a statement day and grace period.
class BillingCycleFloat {
  final int daysUntilStatement;
  final int totalInterestFreeDays;

  const BillingCycleFloat({required this.daysUntilStatement, required this.totalInterestFreeDays});
}

BillingCycleFloat billingCycleFloat({
  required int statementDay,
  required int gracePeriodDays,
  Clock clock = const SystemClock(),
}) {
  final now = clock.now();
  var nextStatement = DateTime(now.year, now.month, statementDay);
  if (!nextStatement.isAfter(now)) {
    nextStatement = DateTime(now.year, now.month + 1, statementDay);
  }
  final daysUntilStatement = nextStatement.difference(DateTime(now.year, now.month, now.day)).inDays;
  return BillingCycleFloat(
    daysUntilStatement: daysUntilStatement,
    totalInterestFreeDays: daysUntilStatement + gracePeriodDays,
  );
}

/// UA-2.4.4 / G3 — EMI advisor verdict.
class EmiAdvice {
  final Money totalInterest;
  final Money effectiveCost; // interest + forfeited rewards
  final Money forfeitedRewards;
  final String verdictLine;

  const EmiAdvice({
    required this.totalInterest,
    required this.effectiveCost,
    required this.forfeitedRewards,
    required this.verdictLine,
  });
}

EmiAdvice adviseEmi({
  required Money principal,
  required double annualInterestRatePercent,
  required int tenureMonths,
  required Money forgoneRewardValue, // what you'd have earned paying in full instead
}) {
  final monthlyRate = annualInterestRatePercent / 100 / 12;
  Money totalPaid;
  if (monthlyRate == 0) {
    totalPaid = principal;
  } else {
    final emi = principal.rupees *
        monthlyRate *
        _pow(1 + monthlyRate, tenureMonths) /
        (_pow(1 + monthlyRate, tenureMonths) - 1);
    totalPaid = Money.fromRupees(emi * tenureMonths);
  }
  final totalInterest = totalPaid - principal;
  final effectiveCost = totalInterest + forgoneRewardValue;

  final verdict = effectiveCost.paise > 0
      ? 'EMI costs ${effectiveCost.format()} more than paying in full — avoid it if you can.'
      : 'EMI has no real cost here — the numbers work out even.';

  return EmiAdvice(
    totalInterest: totalInterest,
    effectiveCost: effectiveCost,
    forfeitedRewards: forgoneRewardValue,
    verdictLine: verdict,
  );
}

double _pow(double base, int exponent) {
  double result = 1;
  for (var i = 0; i < exponent; i++) {
    result *= base;
  }
  return result;
}

/// UA-2.4.5 / §10.7 — UPI-vs-swipe comparison: ranks the same card set on
/// both rails and surfaces the delta so the user can see whether tapping
/// through UPI or swiping actually pays more.
class RailComparison {
  final Recommendation upiTop;
  final Recommendation swipeTop;
  final Money delta; // swipe - upi; positive means swipe pays more

  const RailComparison({required this.upiTop, required this.swipeTop, required this.delta});
}

RailComparison compareRails(
  RecommendationEngine engine,
  RecommendationContext baseContext,
  List<CardSnapshot> cards,
) {
  final upiResults = engine.rank(
    RecommendationContext(
      amount: baseContext.amount,
      categoryId: baseContext.categoryId,
      mcc: baseContext.mcc,
      vpa: baseContext.vpa,
      rail: TxnRail.upiQr,
      travelMode: baseContext.travelMode,
      merchantName: baseContext.merchantName,
      now: baseContext.now,
    ),
    cards,
  );
  final swipeResults = engine.rank(
    RecommendationContext(
      amount: baseContext.amount,
      categoryId: baseContext.categoryId,
      mcc: baseContext.mcc,
      vpa: baseContext.vpa,
      rail: TxnRail.swipe,
      travelMode: baseContext.travelMode,
      merchantName: baseContext.merchantName,
      now: baseContext.now,
    ),
    cards,
  );

  final upiTop = upiResults.firstWhere((r) => !r.isExcluded, orElse: () => upiResults.first);
  final swipeTop = swipeResults.firstWhere((r) => !r.isExcluded, orElse: () => swipeResults.first);

  return RailComparison(
    upiTop: upiTop,
    swipeTop: swipeTop,
    delta: swipeTop.expectedValue - upiTop.expectedValue,
  );
}
