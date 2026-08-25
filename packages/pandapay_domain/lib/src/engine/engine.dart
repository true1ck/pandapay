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

  /// The merchant this spend is at, used to evaluate
  /// [RewardRule.merchantPattern]. Null means "unknown merchant", which
  /// makes merchant-restricted rules inapplicable — see
  /// [RecommendationEngine.ruleApplies].
  final String? merchantName;

  /// The moment this recommendation is for, used to evaluate a rule's
  /// [RewardRule.effectiveFrom]/[RewardRule.effectiveTo] window.
  ///
  /// Optional and defaults to "no date bound is checked" rather than to
  /// `DateTime.now()`: this package is pure and deliberately holds no
  /// clock (see `../clock/clock.dart` — callers inject one). Passing null
  /// therefore keeps the pre-existing behaviour of ignoring validity
  /// windows, so a caller that hasn't been updated degrades to the old
  /// answer rather than silently dropping every dated rule.
  final DateTime? now;

  const RecommendationContext({
    required this.amount,
    this.categoryId,
    this.mcc,
    this.vpa,
    required this.rail,
    this.isP2P = false,
    this.travelMode = false,
    this.merchantName,
    this.now,
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

/// Where a recommendation stands against the matched rule's cap.
///
/// A first-class field on [RecommendationBreakdown] rather than something
/// the UI derives by matching on [RecommendationBreakdown.capNote]'s prose
/// — which is exactly the string-parsing that class exists to replace. Home
/// badges a cap-exhausted card and shows its real rate instead of its
/// headline one, and that decision must not silently break the day the
/// wording changes.
enum CapStatus {
  /// The matched rule has no cap at all.
  none,

  /// Cap exists and this spend fits inside the remaining headroom.
  withinCap,

  /// Cap exists and this spend runs past the remaining headroom, so part of
  /// it earns the post-cap rate.
  partiallyConsumed,

  /// No headroom left — the whole spend earns the post-cap rate, which for
  /// most cards is simply the card's ordinary base rate.
  reached,
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

  /// Where this spend stands against the matched rule's cap.
  final CapStatus capStatus;

  /// What one rupee of this spend ACTUALLY earns once cap blending, the
  /// per-transaction ceiling and every adjustment are applied — i.e.
  /// `expectedValue / amount`.
  ///
  /// Distinct from [baseRatePerRupee], which is the rate the card
  /// advertises. When a cap is exhausted the two diverge sharply (a "10%
  /// online" card paying its 1% base rate), and showing only the headline
  /// there is the over-promise the cap work exists to stop.
  final double effectiveRatePerRupee;

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
    this.capStatus = CapStatus.none,
    this.effectiveRatePerRupee = 0,
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

  /// Whether [rule] is applicable to [context] at all.
  ///
  /// Public and static because this predicate is the contract the catalogue
  /// is written against, and it needs to be assertable directly in tests
  /// and reusable by callers that rank outside [rank] (the acquisition
  /// recommender, the split optimizer's marginal-rate probing).
  ///
  /// Rule matching used to be `categoryId == null || categoryId == ctx.categoryId`
  /// and nothing else, even though every constraint below already existed
  /// as a field here and as a column in Postgres. The result was an engine
  /// that paid "10% at Amazon" at every online merchant, paid a swipe-only
  /// rate over UPI, honoured a "min ₹500" rule on a ₹50 purchase, and kept
  /// recommending promo rates that expired months ago.
  ///
  /// [maxTxn] is deliberately NOT a disqualifier here — it caps how much of
  /// the transaction earns the bonus rate rather than voiding the rule, and
  /// is applied as a split inside [_evaluate].
  static bool ruleApplies(RewardRule rule, RecommendationContext context) {
    // Category: a null categoryId on the rule is the card's catch-all.
    if (rule.categoryId != null && rule.categoryId != context.categoryId) return false;

    // Per-rule exclusions (distinct from card-level ones, which are checked
    // before any rule is considered).
    if (context.categoryId != null && rule.excludedCategoryIds.contains(context.categoryId)) {
      return false;
    }

    // Merchant restriction. Substring, case-insensitive, punctuation- and
    // space-insensitive on both sides, because the merchant string reaching
    // us comes from a bank SMS ("AMAZON  PAY IND"), a UPI VPA, or a
    // hand-typed quick-add — none of which agree on formatting with a
    // catalogue pattern written as 'amazon'. An unknown merchant cannot
    // satisfy a merchant restriction, so the rule does not apply: promising
    // an Amazon-only rate at an unidentified merchant is exactly the
    // over-promise this guard exists to stop.
    final pattern = rule.merchantPattern;
    if (pattern != null && pattern.trim().isNotEmpty) {
      final merchant = context.merchantName;
      if (merchant == null) return false;
      if (!_normalizeMerchant(merchant).contains(_normalizeMerchant(pattern))) return false;
    }

    // Rail restriction.
    //
    // `TxnRail.unknown` is treated as a wildcard rather than as a mismatch.
    // It means "the rail was never captured", not "the rail was something
    // else": every SMS/email import lands with rail unknown (the parser
    // doesn't extract it), so failing the match there would silently
    // under-report the earn rate on essentially all imported spend. The
    // app's own ranking path never passes unknown — Home passes a concrete
    // rail — so this wildcard only ever loosens the recorded-history side,
    // where an under-report is as wrong as an over-report.
    if (rule.rail != null && context.rail != TxnRail.unknown && rule.rail != context.rail) {
      return false;
    }

    // Transaction floor. Strictly below the floor, the rule is off and the
    // card falls through to its base rate.
    final minTxn = rule.minTxn;
    if (minTxn != null && context.amount < minTxn) return false;

    // Catalogue validity window. Only checked when the caller supplied a
    // date — see RecommendationContext.now.
    final now = context.now;
    if (now != null) {
      final from = rule.effectiveFrom;
      if (from != null && now.isBefore(from)) return false;
      final to = rule.effectiveTo;
      // effective_to is a DATE and is inclusive of that whole day, so the
      // comparison is against the following midnight — a rule valid "to
      // 2026-03-31" must still apply at 18:00 on the 31st.
      if (to != null && !now.isBefore(DateTime(to.year, to.month, to.day + 1))) return false;
    }

    return true;
  }

  /// Lowercased, stripped of everything that isn't a letter or digit, so
  /// 'AMAZON  PAY IND*ORDER' and 'amazon' compare equal on the substring
  /// test. Mirrors the normalization `pandapay.dedupe_hash()` already
  /// applies to merchant names server-side.
  static String _normalizeMerchant(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// What one rupee earns on this card once [capRule]'s cap is spent.
  ///
  /// A null [CapRule.postCapRate] means the catalogue never stated a
  /// post-cap rate, which is the normal case — issuers word these as "5% on
  /// groceries up to ₹3,000/month" and leave "and 1% after that" implicit,
  /// because the 1% is just the card's ordinary base rate. Resolving null
  /// to the card's base rate is what makes a cap-exhausted card rank as the
  /// merely-average card it actually is.
  ///
  /// This previously resolved to 0, which reported a capped 5%-groceries
  /// card as earning nothing at all on further grocery spend and sorted it
  /// below cards that were genuinely worse than its base rate — wrong in
  /// both directions at once.
  ///
  /// An explicit `postCapRate` of 0 is preserved as 0: some cards really do
  /// stop earning past the cap, and that is a different fact from silence.
  /// A rate given without a unit is read in the matched rule's own unit,
  /// which is how a catalogue editor writing "post cap: 1" beside a
  /// cashback rule means it.
  static double resolvePostCapRate(CapRule capRule, RewardRule rule, CardProduct card) {
    final rate = capRule.postCapRate;
    if (rate == null) return card.baseRatePerRupee;
    final unit = capRule.postCapUnit ?? rule.unit;
    return unit.effectiveRatePerRupee(rate, pointValueInr: card.pointValueInr);
  }

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

    // Card-level category exclusion, checked before any rule is considered
    // — an excluded category earns nothing on this card at ANY rate, base
    // rate included, so falling through to the base-rate path below would
    // still be wrong. Rent, wallet loads, fuel, insurance premiums,
    // government payments and EMI conversions are the usual list.
    if (card.excludesCategory(context.categoryId)) {
      return Recommendation(
        card: card,
        expectedValue: const Money.zero(),
        confidence: Confidence.estimated,
        exclusionReason: "This card doesn't earn rewards on this kind of spend.",
        reasonLines: const [],
      );
    }

    // Pick the highest-priority (lowest number) APPLICABLE reward rule.
    // See [ruleApplies] — this used to filter on category alone, ignoring
    // the merchant/rail/min-txn/validity constraints the rule carried.
    final matching = card.rewardRules.where((r) => ruleApplies(r, context)).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));

    if (matching.isEmpty) {
      // No applicable rule — fall back to the card's own everything-else
      // earn rate. This is what actually happens at the till: a 1% cashback
      // card still pays 1% at a pharmacy the catalogue never enumerated.
      // Excluding it instead reported ₹0 for the card and, when no card had
      // a rule for the chosen category, left Home with no verdict at all.
      //
      // `flatPoints` deliberately normalizes to 0 (see RewardUnit's own
      // doc-comment: it's a fixed bonus, not a per-rupee rate), so checking
      // the *resolved* rate rather than the nominal one keeps such a card
      // honestly excluded instead of advertising "Base rate 0.0%".
      final ratePerRupee = card.baseRatePerRupee;
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

    // UA-2.2.6 per-transaction ceiling. A rule's maxTxn does not disqualify
    // it (that's minTxn's job) — it splits the transaction: the portion up
    // to maxTxn earns the bonus rate, the excess earns the card's ordinary
    // base rate. "5% on the first ₹5,000 per transaction" is how issuers
    // word this, and the excess very much still earns something, so paying
    // the bonus on the whole amount (the old behaviour) and paying nothing
    // on the excess are both wrong.
    //
    // Applied BEFORE cap blending, because the cap only ever sees spend
    // that was eligible for the bonus in the first place.
    final maxTxn = rule.maxTxn;
    final bonusEligible = maxTxn != null && context.amount > maxTxn ? maxTxn : context.amount;
    final overMaxPortion = context.amount - bonusEligible;
    final overMaxValue = overMaxPortion.isZero
        ? const Money.zero()
        : overMaxPortion * card.baseRatePerRupee;

    // UA-2.2.3 cap blending: split spend across pre-cap and post-cap rates,
    // measure-aware (fixed — see PROGRESS.md Chunk 9; was previously always
    // treated as spend-amount headroom regardless of CapRule.measure).
    //
    // A cap attaches either to the matched reward rule or to the
    // transaction's category. Category-scoped caps used to be invisible
    // here — only `rewardRuleId` was matched — so a cap modelled as "5% on
    // groceries, ₹3,000/month" via `category_id` rather than
    // `reward_rule_id` was never applied at all. `categoryId == null` is
    // NOT a wildcard: a cap with neither key set belongs to no rule and no
    // category, and treating it as card-wide would let an unrelated spend
    // consume it.
    final capRule = card.capRules
        .where((c) =>
            (c.rewardRuleId != null && c.rewardRuleId == rule.id) ||
            (c.categoryId != null && c.categoryId == context.categoryId))
        .firstOrNull;
    // Design 09's breakdown rows, captured as the engine goes rather than
    // reconstructed afterwards — see RecommendationBreakdown.
    final baseValue = context.amount * baseRatePerRupee;
    Money? capHeadroom;
    String? capNote;
    var capStatus = CapStatus.none;
    var forexCost = const Money.zero();
    var fuelWaiver = const Money.zero();
    var milestoneBonus = const Money.zero();
    Money value;
    if (capRule != null) {
      // Null postCapRate resolves to the card's own base rate, not to zero
      // — see [resolvePostCapRate]. This is the difference between "your
      // capped 5% card now earns its usual 1%" and the old, wrong "your
      // capped 5% card now earns nothing".
      final postRate = resolvePostCapRate(capRule, rule, card);

      switch (capRule.measure) {
        case CapMeasure.spendAmount:
          // capRemaining/capValue are literally spend headroom — blend the
          // bonus-eligible amount directly against it.
          final remaining = snapshot.capRemaining[capRule.id] ?? capRule.capValue;
          capHeadroom = remaining.isNegative ? const Money.zero() : remaining;
          if (remaining >= bonusEligible) {
            capStatus = CapStatus.withinCap;
            value = bonusEligible * baseRatePerRupee;
            reasons.add('Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on '
                '${bonusEligible.format()}');
          } else if (remaining.isZero || remaining.isNegative) {
            capStatus = CapStatus.reached;
            capNote = 'Cap reached';
            value = bonusEligible * postRate;
            reasons.add('Cap already reached — this card now earns its base rate of '
                '${(postRate * 100).toStringAsFixed(1)}% here');
          } else {
            capStatus = CapStatus.partiallyConsumed;
            final preCapPortion = remaining;
            final postCapPortion = bonusEligible - remaining;
            capNote = 'Only ${remaining.format()} of cap left';
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
            capStatus = CapStatus.reached;
            value = bonusEligible * postRate;
            reasons.add('Cap already reached — this card now earns its base rate of '
                '${(postRate * 100).toStringAsFixed(1)}% here');
          } else if (baseRatePerRupee <= 0) {
            capStatus = CapStatus.withinCap;
            // Base rate is 0 (or the rule is a flat bonus) — no spend can
            // consume reward-value headroom, so the whole amount stays at
            // whatever "base" rate that is (0), never falls through to post-cap.
            value = bonusEligible * baseRatePerRupee;
            reasons.add('Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on '
                '${bonusEligible.format()}');
          } else {
            final preCapSpend = Money.fromRupees(remaining.rupees / baseRatePerRupee);
            if (preCapSpend >= bonusEligible) {
              capStatus = CapStatus.withinCap;
              value = bonusEligible * baseRatePerRupee;
              reasons.add('Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on '
                  '${bonusEligible.format()} (within ${remaining.format()} reward-value headroom)');
            } else {
              capStatus = CapStatus.partiallyConsumed;
              final postCapPortion = bonusEligible - preCapSpend;
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
            capStatus = CapStatus.withinCap;
            capNote = '${remainingCount.toStringAsFixed(0)} transactions left';
            value = bonusEligible * baseRatePerRupee;
            reasons.add('Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on '
                '${bonusEligible.format()} (txn ${remainingCount.toStringAsFixed(0)} of cap remaining)');
          } else {
            capStatus = CapStatus.reached;
            capNote = 'Cap reached';
            value = bonusEligible * postRate;
            reasons.add('Transaction-count cap reached — this card now earns its base rate of '
                '${(postRate * 100).toStringAsFixed(1)}% here');
          }
      }
    } else {
      value = bonusEligible * baseRatePerRupee;
      reasons.add(
          'Base rate ${(baseRatePerRupee * 100).toStringAsFixed(1)}% on ${bonusEligible.format()}');
    }

    // The over-ceiling remainder, added after cap blending because it was
    // never bonus-eligible and so never touched the cap.
    if (!overMaxPortion.isZero) {
      value += overMaxValue;
      reasons.add('${overMaxPortion.format()} above this rule\'s ${maxTxn!.format()} '
          'per-transaction limit at the base rate '
          '${(card.baseRatePerRupee * 100).toStringAsFixed(1)}%');
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
        capStatus: capStatus,
        // What a rupee of THIS spend actually earned, after cap blending,
        // the per-transaction ceiling, forex, fuel and milestones. Computed
        // from the final value rather than re-derived, so it can never
        // disagree with the headline figure beside it.
        effectiveRatePerRupee: context.amount.paise == 0 ? 0 : value.paise / context.amount.paise,
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
