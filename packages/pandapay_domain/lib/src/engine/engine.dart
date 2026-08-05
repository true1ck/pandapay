import '../card_rules/card_rules.dart';
import '../confidence/confidence.dart';
import '../money/money.dart';

/// UA-2.1.1. Everything the engine needs to know about *this* transaction.
class RecommendationContext {
  final Money amount;
  final String? categoryId;
  final String? mcc;
  final String? vpa;
  final TxnRail rail;
  final bool isP2P;
  final bool travelMode;

  const RecommendationContext({
    required this.amount,
    this.categoryId,
    this.mcc,
    this.vpa,
    required this.rail,
    this.isP2P = false,
    this.travelMode = false,
  });
}

/// UA-2.1.2. Per-card state the engine needs, assembled by a repository —
/// the engine itself performs no IO and never queries anything.
class CardSnapshot {
  final CardProduct product;
  final Map<String, Money> capRemaining; // capRule.id -> remaining headroom
  final Map<String, Money> milestoneProgress; // milestoneRule.id -> spend so far
  final String? forcedOverrideCardId; // set when a B8 override targets this txn

  const CardSnapshot({
    required this.product,
    this.capRemaining = const {},
    this.milestoneProgress = const {},
    this.forcedOverrideCardId,
  });
}

/// UA-2.1.3. `reasonLines` is required — "Why this card?" is not optional.
class Recommendation {
  final CardProduct card;
  final Money expectedValue;
  final Confidence confidence;
  final String? exclusionReason;
  final List<String> reasonLines;
  final bool isOverride;

  const Recommendation({
    required this.card,
    required this.expectedValue,
    required this.confidence,
    this.exclusionReason,
    required this.reasonLines,
    this.isOverride = false,
  });

  bool get isExcluded => exclusionReason != null;
}

/// domain/engine/ — pure Dart, zero IO. UA-2.2/2.3.
///
/// Ranks [cards] for [context] and returns every card (excluded cards are
/// included with `exclusionReason` set and sort last — ui-spec B3.4 shows
/// them greyed, never silently drops them).
class RecommendationEngine {
  List<Recommendation> rank(
    RecommendationContext context,
    List<CardSnapshot> cards,
  ) {
    final results = cards.map((s) => _evaluate(context, s)).toList();

    results.sort((a, b) {
      // UA-2.2.6: an override always wins.
      if (a.isOverride != b.isOverride) return a.isOverride ? -1 : 1;
      // Excluded cards always sort after eligible ones.
      if (a.isExcluded != b.isExcluded) return a.isExcluded ? 1 : -1;
      if (a.isExcluded && b.isExcluded) return 0;
      final byValue = b.expectedValue.paise.compareTo(a.expectedValue.paise);
      if (byValue != 0) return byValue;
      // UA-2.2.8 deterministic tie-break: higher confidence wins first.
      final byConfidence =
          (b.confidence.isConfirmed ? 1 : 0) - (a.confidence.isConfirmed ? 1 : 0);
      if (byConfidence != 0) return byConfidence;
      // Then stable by card id so output is fully deterministic.
      return a.card.id.compareTo(b.card.id);
    });

    return results;
  }

  Recommendation _evaluate(RecommendationContext context, CardSnapshot snapshot) {
    final card = snapshot.product;
    final reasons = <String>[];

    // UA-2.2.1: RuPay/UPI exclusion gate. Never silently dropped — always
    // returned, greyed, with a reason (product-plan §4.1).
    if (context.rail == TxnRail.upiQr && !card.isUpiLinkable) {
      return Recommendation(
        card: card,
        expectedValue: const Money.zero(),
        confidence: Confidence.estimated,
        exclusionReason: 'Not usable via UPI — swipe this instead.',
        reasonLines: const [],
      );
    }

    if (context.isP2P) {
      return Recommendation(
        card: card,
        expectedValue: const Money.zero(),
        confidence: Confidence.estimated,
        exclusionReason: "Credit cards can't be used for personal transfers.",
        reasonLines: const [],
      );
    }

    // Pick the highest-priority (lowest number) matching reward rule.
    final matching = card.rewardRules
        .where((r) => r.categoryId == null || r.categoryId == context.categoryId)
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));

    if (matching.isEmpty) {
      return Recommendation(
        card: card,
        expectedValue: const Money.zero(),
        confidence: Confidence.estimated,
        exclusionReason: 'No applicable reward rule.',
        reasonLines: const [],
      );
    }

    final rule = matching.first;
    final baseRatePerRupee =
        rule.unit.effectiveRatePerRupee(rule.rate, pointValueInr: card.pointValueInr);

    // UA-2.2.3 cap blending: split spend across pre-cap and post-cap rates
    // when cap_remaining < amount.
    final capRule = card.capRules.where((c) => c.rewardRuleId == rule.id).firstOrNull;
    Money value;
    if (capRule != null) {
      final remaining = snapshot.capRemaining[capRule.id] ?? capRule.capValue;
      if (remaining >= context.amount) {
        value = context.amount * baseRatePerRupee;
        reasons.add(
            'Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on ${context.amount.format()}');
      } else if (remaining.isZero || remaining.isNegative) {
        final postRate = capRule.postCapUnit
                ?.effectiveRatePerRupee(capRule.postCapRate, pointValueInr: card.pointValueInr) ??
            0;
        value = context.amount * postRate;
        reasons.add('Cap already reached — post-cap rate '
            '${(postRate * 100).toStringAsFixed(1)}% applies to the full amount');
      } else {
        final preCapPortion = remaining;
        final postCapPortion = context.amount - remaining;
        final postRate = capRule.postCapUnit
                ?.effectiveRatePerRupee(capRule.postCapRate, pointValueInr: card.pointValueInr) ??
            0;
        final preValue = preCapPortion * baseRatePerRupee;
        final postValue = postCapPortion * postRate;
        value = preValue + postValue;
        reasons.add('${preCapPortion.format()} at ${(baseRatePerRupee * 100).toStringAsFixed(1)}% '
            '(cap headroom) + ${postCapPortion.format()} at '
            '${(postRate * 100).toStringAsFixed(1)}% (post-cap)');
      }
    } else {
      value = context.amount * baseRatePerRupee;
      reasons.add(
          'Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on ${context.amount.format()}');
    }

    // UA-2.2.5 travel mode: subtract forex markup (incl. GST on markup).
    if (context.travelMode && card.forexRule != null) {
      final markupFraction = card.forexRule!.effectiveMarkupFraction();
      final markupCost = context.amount * markupFraction;
      value -= markupCost;
      reasons.add('Less forex markup ${(markupFraction * 100).toStringAsFixed(2)}% '
          '(incl. GST): -${markupCost.format()}');
    }

    // UA-2.2.7 fuel surcharge waiver, additive.
    if (context.categoryId == 'fuel' && card.fuelRule != null) {
      final waiverFraction = card.fuelRule!.waiverPercent / 100;
      final waiverValue = context.amount * waiverFraction;
      value += waiverValue;
      reasons.add('Fuel surcharge waiver: +${waiverValue.format()}');
    }

    final isOverride = snapshot.forcedOverrideCardId == card.id;
    if (isOverride) {
      reasons.add('Manual override — always use this card here');
    }

    return Recommendation(
      card: card,
      expectedValue: value,
      confidence: Confidence.estimated,
      reasonLines: reasons,
      isOverride: isOverride,
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
