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

/// The itemised arithmetic behind one [Recommendation] — design 09
/// "Why this card?" reads this row by row.
///
/// Exists because that screen previously had to *keyword-match the engine's
/// own prose*: [Recommendation.reasonLines] is written for humans, and
/// deriving "was there a cap in the way" from a string like "₹380 at 5%
/// (cap headroom)" is a parser that silently breaks the day the wording
/// changes. Design 09 is the trust screen — the one place the app owes the
/// user the actual calculation — so the numbers it shows are now carried
/// as numbers.
///
/// Every field is what it says at the point the engine computed it. Nulls
/// mean "not applicable to this card", never zero: a card with no cap has
/// `capHeadroom == null`, which design 09 renders as "None", while a card
/// whose cap is exhausted has `Money.zero()` and renders as "₹0 free".
class RecommendationBreakdown {
  /// The matched rule's nominal rate as a fraction of spend (0.05 == 5%).
  final double baseRatePerRupee;

  /// What the base rate alone would pay on this amount, before any cap
  /// blending, forex deduction, fuel waiver or milestone bonus. Design 09's
  /// "Base rate 5% on ₹2,500 → +₹125" row.
  final Money baseValue;

  /// Spend headroom left under the matched rule's cap.
  ///
  /// Only populated for [CapMeasure.spendAmount] caps: those are the only
  /// ones whose remaining headroom is a rupee figure a user can read as
  /// "₹380 free". Reward-value and transaction-count caps are real, and
  /// still affect [Recommendation.expectedValue] — they surface through
  /// [capNote] instead of being mis-rendered as spend.
  final Money? capHeadroom;

  /// A short human note for cap situations [capHeadroom] can't express —
  /// "₹1,000 of reward value left", "3 transactions left", "cap reached".
  /// Null when the card has no cap on the matched rule.
  final String? capNote;

  /// The matched rule's merchant pattern, if it only applies at specific
  /// merchants. Null means unrestricted — design 09's "Merchant
  /// restriction: None".
  final String? merchantRestriction;

  /// ₹ per point, but only for rules that actually earn points. Null for
  /// cashback rules, where "points value used" is a meaningless row rather
  /// than a zero.
  final double? pointValueInr;

  /// Forex markup deducted under travel mode; zero when it didn't apply.
  final Money forexCost;

  /// Fuel surcharge waiver added; zero when it didn't apply.
  final Money fuelWaiver;

  /// Pro-rated milestone bonus added; zero when no milestone was
  /// materially advanced.
  final Money milestoneBonus;

  const RecommendationBreakdown({
    required this.baseRatePerRupee,
    required this.baseValue,
    this.capHeadroom,
    this.capNote,
    this.merchantRestriction,
    this.pointValueInr,
    this.forexCost = const Money.zero(),
    this.fuelWaiver = const Money.zero(),
    this.milestoneBonus = const Money.zero(),
  });

  /// Whether anything beyond the plain base rate moved the number. Design
  /// 09 hides the adjustment rows entirely for the common case where the
  /// answer is just "5% of ₹2,500".
  bool get hasAdjustments =>
      !forexCost.isZero || !fuelWaiver.isZero || !milestoneBonus.isZero || capNote != null;
}

/// UA-2.1.3. `reasonLines` is required — "Why this card?" is not optional.
class Recommendation {
  final CardProduct card;
  final Money expectedValue;
  final Confidence confidence;
  final String? exclusionReason;
  final List<String> reasonLines;
  final bool isOverride;

  /// The headline earn rate this recommendation was computed at, as a
  /// fraction of spend (0.05 == 5%). Design 01's verdict card sets it
  /// beside the BEST PICK badge ("5% on Online"), which previously had to
  /// be scraped back out of [reasonLines] prose. Null when the card is
  /// excluded, or when the rate isn't a per-rupee one (flat point bonuses).
  final double? effectiveRatePerRupee;

  /// The itemised calculation, for design 09. Null on excluded cards and on
  /// the base-rate fallback path, where there is no matched rule to break
  /// down.
  final RecommendationBreakdown? breakdown;

  const Recommendation({
    required this.card,
    required this.expectedValue,
    required this.confidence,
    this.exclusionReason,
    required this.reasonLines,
    this.isOverride = false,
    this.effectiveRatePerRupee,
    this.breakdown,
  });

  bool get isExcluded => exclusionReason != null;
}

/// domain/engine/ — pure Dart, zero IO. UA-2.2/2.3.
///
/// Ranks [cards] for [context] and returns every card (excluded cards are
/// included with `exclusionReason` set and sort last — ui-spec B3.4 shows
/// them greyed, never silently drops them).
class RecommendationEngine {
  /// UA-2.2.4: fraction of a milestone's remaining threshold a transaction
  /// must cover to count as "materially" advancing it. Configurable per the
  /// plan's wording ("define 'materially' as a configurable fraction").
  final double milestoneMaterialFraction;

  const RecommendationEngine({this.milestoneMaterialFraction = 0.5});

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
      // No category rule — fall back to the card's own everything-else
      // earn rate. This is what actually happens at the till: a 1% cashback
      // card still pays 1% at a pharmacy the catalogue never enumerated.
      // Excluding it instead reported ₹0 for the card and, when no card had
      // a rule for the chosen category, left Home with no verdict at all.
      final baseUnit = card.baseRewardUnit;
      final baseRate = card.baseRewardRate;
      // `flatPoints` deliberately normalizes to 0 (see RewardUnit's own
      // doc-comment: it's a fixed bonus, not a per-rupee rate), so checking
      // the *resolved* rate rather than the nominal one keeps such a card
      // honestly excluded instead of advertising "Base rate 0.0%".
      final ratePerRupee = baseUnit == null || baseRate == null
          ? 0.0
          : baseUnit.effectiveRatePerRupee(baseRate, pointValueInr: card.pointValueInr);
      if (ratePerRupee <= 0) {
        return Recommendation(
          card: card,
          expectedValue: const Money.zero(),
          confidence: Confidence.estimated,
          exclusionReason: 'No applicable reward rule.',
          reasonLines: const [],
        );
      }
      return Recommendation(
        card: card,
        expectedValue: context.amount * ratePerRupee,
        confidence: Confidence.estimated,
        effectiveRatePerRupee: ratePerRupee,
        reasonLines: [
          'Base rate ${(ratePerRupee * 100).toStringAsFixed(1)}% — no category bonus on this spend',
        ],
      );
    }

    final rule = matching.first;
    final baseRatePerRupee =
        rule.unit.effectiveRatePerRupee(rule.rate, pointValueInr: card.pointValueInr);

    // UA-2.2.3 cap blending: split spend across pre-cap and post-cap rates,
    // measure-aware (fixed — see PROGRESS.md Chunk 9; was previously always
    // treated as spend-amount headroom regardless of CapRule.measure).
    final capRule = card.capRules.where((c) => c.rewardRuleId == rule.id).firstOrNull;
    // Design 09's breakdown rows, captured as the engine goes rather than
    // reconstructed afterwards — see RecommendationBreakdown.
    final baseValue = context.amount * baseRatePerRupee;
    Money? capHeadroom;
    String? capNote;
    var forexCost = const Money.zero();
    var fuelWaiver = const Money.zero();
    var milestoneBonus = const Money.zero();
    Money value;
    if (capRule != null) {
      final postRate = capRule.postCapUnit
              ?.effectiveRatePerRupee(capRule.postCapRate, pointValueInr: card.pointValueInr) ??
          0;

      switch (capRule.measure) {
        case CapMeasure.spendAmount:
          // capRemaining/capValue are literally spend headroom — blend the
          // amount directly against it, same as pre-fix behaviour.
          final remaining = snapshot.capRemaining[capRule.id] ?? capRule.capValue;
          capHeadroom = remaining.isNegative ? const Money.zero() : remaining;
          if (remaining >= context.amount) {
            value = context.amount * baseRatePerRupee;
            reasons.add('Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on '
                '${context.amount.format()}');
          } else if (remaining.isZero || remaining.isNegative) {
            capNote = 'Cap reached';
            value = context.amount * postRate;
            reasons.add('Cap already reached — post-cap rate '
                '${(postRate * 100).toStringAsFixed(1)}% applies to the full amount');
          } else {
            final preCapPortion = remaining;
            final postCapPortion = context.amount - remaining;
            value = preCapPortion * baseRatePerRupee + postCapPortion * postRate;
            reasons.add('${preCapPortion.format()} at ${(baseRatePerRupee * 100).toStringAsFixed(1)}% '
                '(cap headroom) + ${postCapPortion.format()} at '
                '${(postRate * 100).toStringAsFixed(1)}% (post-cap)');
          }

        case CapMeasure.rewardValue:
          // capRemaining/capValue are reward-VALUE headroom (e.g. "₹1,000 of
          // cashback left this cycle"), not spend headroom — a spend of ₹X
          // at baseRatePerRupee only consumes X*baseRatePerRupee of it. Find
          // the spend-equivalent of the remaining reward headroom, blend on
          // that, and let the reward-value portion be exactly `remaining`
          // (never re-derived from spend*rate, which would round differently).
          final remaining = snapshot.capRemaining[capRule.id] ?? capRule.capValue;
          capNote = remaining.isZero || remaining.isNegative
              ? 'Cap reached'
              : '${remaining.format()} of reward value left';
          if (remaining.isZero || remaining.isNegative) {
            value = context.amount * postRate;
            reasons.add('Cap already reached — post-cap rate '
                '${(postRate * 100).toStringAsFixed(1)}% applies to the full amount');
          } else if (baseRatePerRupee <= 0) {
            // Base rate is 0 (or the rule is a flat bonus) — no spend can
            // consume reward-value headroom, so the whole amount stays at
            // whatever "base" rate that is (0), never falls through to post-cap.
            value = context.amount * baseRatePerRupee;
            reasons.add('Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on '
                '${context.amount.format()}');
          } else {
            final preCapSpend = Money.fromRupees(remaining.rupees / baseRatePerRupee);
            if (preCapSpend >= context.amount) {
              value = context.amount * baseRatePerRupee;
              reasons.add('Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on '
                  '${context.amount.format()} (within ${remaining.format()} reward-value headroom)');
            } else {
              final postCapPortion = context.amount - preCapSpend;
              final postValue = postCapPortion * postRate;
              value = remaining + postValue;
              reasons.add('${remaining.format()} reward-value headroom exhausted by '
                  '${preCapSpend.format()} of this spend, remaining '
                  '${postCapPortion.format()} at ${(postRate * 100).toStringAsFixed(1)}% (post-cap)');
            }
          }

        case CapMeasure.txnCount:
          // capValue/capRemaining encode a transaction COUNT (see
          // card_rules_json.dart), not a money amount — .rupees is reused
          // purely as the numeric carrier. A single transaction can't be
          // split across pre/post-cap, unlike a spend or reward-value cap:
          // either this transaction is within the remaining count (full base
          // rate) or it isn't (full post-cap rate).
          final remainingCount =
              (snapshot.capRemaining[capRule.id] ?? capRule.capValue).rupees;
          if (remainingCount >= 1) {
            value = context.amount * baseRatePerRupee;
            reasons.add('Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on '
                '${context.amount.format()} (txn ${remainingCount.toStringAsFixed(0)} of cap remaining)');
          } else {
            value = context.amount * postRate;
            reasons.add('Transaction-count cap reached — post-cap rate '
                '${(postRate * 100).toStringAsFixed(1)}% applies to this transaction');
          }
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
      forexCost = markupCost;
      value -= markupCost;
      reasons.add('Less forex markup ${(markupFraction * 100).toStringAsFixed(2)}% '
          '(incl. GST): -${markupCost.format()}');
    }

    // UA-2.2.7 fuel surcharge waiver, additive.
    if (context.categoryId == 'fuel' && card.fuelRule != null) {
      final waiverFraction = card.fuelRule!.waiverPercent / 100;
      final waiverValue = context.amount * waiverFraction;
      fuelWaiver = waiverValue;
      value += waiverValue;
      reasons.add('Fuel surcharge waiver: +${waiverValue.format()}');
    }

    // UA-2.2.4 milestone bonus: add value only when this spend *materially*
    // advances a milestone. "Materially" = the spend covers at least
    // [milestoneMaterialFraction] of the remaining threshold. Value added is
    // pro-rated to how much of the remaining gap this transaction closes, so
    // a transaction that just barely clears the bar doesn't claim the whole
    // milestone reward, and a transaction that completes it claims exactly
    // the reward once (never more, never double-counted across scenarios).
    for (final milestone in card.milestoneRules) {
      final progress = snapshot.milestoneProgress[milestone.id] ?? const Money.zero();
      final remaining = milestone.thresholdSpend - progress;
      if (remaining.isZero || remaining.isNegative) continue; // already achieved
      final coversFraction = context.amount.paise / remaining.paise;
      if (coversFraction < milestoneMaterialFraction) continue; // not material

      final closedPortion = context.amount < remaining ? context.amount : remaining;
      final bonus = milestone.rewardValue * (closedPortion.paise / milestone.thresholdSpend.paise);
      value += bonus;
      milestoneBonus += bonus;
      final verb = context.amount >= remaining ? 'completes' : 'materially advances';
      reasons.add('$verb "${milestone.label}" milestone: +${bonus.format()}');
    }

    final isOverride = snapshot.forcedOverrideCardId == card.id;
    if (isOverride) {
      reasons.add('Manual override — always use this card here');
    }

    return Recommendation(
      card: card,
      expectedValue: value,
      confidence: Confidence.estimated,
      // The matched rule's nominal rate, not `value / amount` — the latter
      // would be diluted by cap blending and milestone bonuses, so a card
      // advertised as "5% on Online" would read as e.g. 3.2% once its cap
      // ran low. This is the rate the headline badge is naming.
      effectiveRatePerRupee: baseRatePerRupee > 0 ? baseRatePerRupee : null,
      reasonLines: reasons,
      isOverride: isOverride,
      breakdown: RecommendationBreakdown(
        baseRatePerRupee: baseRatePerRupee,
        baseValue: baseValue,
        capHeadroom: capHeadroom,
        capNote: capNote,
        merchantRestriction: rule.merchantPattern,
        // Only meaningful for rules that earn points — a ₹/point row on a
        // cashback card is a zero pretending to be information.
        pointValueInr: rule.unit == RewardUnit.cashbackPercent ||
                rule.unit == RewardUnit.discountPercent
            ? null
            : card.pointValueInr,
        forexCost: forexCost,
        fuelWaiver: fuelWaiver,
        milestoneBonus: milestoneBonus,
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
