import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// UA-2.5.1: a single consolidated fixture file covering >=30 rule-
/// interaction scenarios in one place, as the plan asks for — distinct from
/// engine_test.dart's per-feature unit tests (cap blending, forex, overrides,
/// tie-break, ...), which stay where they are as focused regression tests
/// for the bugs that motivated them (see PROGRESS.md Chunk 9). This file is
/// the "does the whole engine behave sanely across every rule interaction"
/// sweep: cap boundary x3 measures, milestone flip, override, P2P, travel,
/// fuel, no-limit card, zero cards, category mismatch, rule priority.
///
/// Every scenario is a single `test()` with an inline, self-contained
/// card/context — no shared mutable fixtures — so a failure names exactly
/// which of the 30+ scenarios broke.
void main() {
  final engine = RecommendationEngine();

  CardProduct baseCard({
    required String id,
    double rate = 5,
    RewardUnit unit = RewardUnit.cashbackPercent,
    String? categoryId,
    bool upiLinkable = true,
    List<CapRule> caps = const [],
    List<MilestoneRule> milestones = const [],
    ForexRule? forex,
    FuelSurchargeRule? fuel,
  }) {
    return CardProduct(
      id: id,
      name: id,
      network: CardNetwork.rupay,
      isUpiLinkable: upiLinkable,
      rewardRules: [
        RewardRule(id: '$id-rule', categoryId: categoryId, unit: unit, rate: rate),
      ],
      capRules: caps,
      milestoneRules: milestones,
      forexRule: forex,
      fuelRule: fuel,
    );
  }

  group('UA-2.5.1 golden fixture set', () {
    // --- Cap boundary: spend_amount measure (4 scenarios) -----------------
    test('1. spend_amount cap: fully within headroom uses base rate only', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(5000),
        measure: CapMeasure.spendAmount,
        period: CapPeriod.calendarMonth,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': Money.fromRupees(5000)});
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(50));
    });

    test('2. spend_amount cap: exact boundary (remaining == amount) uses base rate', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(5000),
        measure: CapMeasure.spendAmount,
        period: CapPeriod.calendarMonth,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': Money.fromRupees(1000)});
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(50));
    });

    test('3. spend_amount cap: exceeding by 1 paisa blends pre/post rates', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(5000),
        measure: CapMeasure.spendAmount,
        period: CapPeriod.calendarMonth,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': Money.fromPaise(100)});
      final ctx = RecommendationContext(amount: Money.fromPaise(101), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromPaise(100) * 0.05 + Money.fromPaise(1) * 0.01);
    });

    test('4. spend_amount cap: already exhausted applies post-cap rate to the full amount', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(5000),
        measure: CapMeasure.spendAmount,
        period: CapPeriod.calendarMonth,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': const Money.zero()});
      final ctx = RecommendationContext(amount: Money.fromRupees(2000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(2000) * 0.01);
    });

    // --- Cap boundary: reward_value measure (3 scenarios) ------------------
    test('5. reward_value cap: spend whose reward stays within headroom uses base rate', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(1000),
        measure: CapMeasure.rewardValue,
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': Money.fromRupees(1000)});
      final ctx = RecommendationContext(amount: Money.fromRupees(5000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(5000) * 0.05);
    });

    test('6. reward_value cap: spend whose reward exceeds headroom blends correctly', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(1000),
        measure: CapMeasure.rewardValue,
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': Money.fromRupees(800)});
      final ctx = RecommendationContext(amount: Money.fromRupees(20000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(840)); // 16000@5%=800 + 4000@1%=40
    });

    test('7. reward_value cap: already exhausted applies post-cap rate to full amount', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(1000),
        measure: CapMeasure.rewardValue,
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': const Money.zero()});
      final ctx = RecommendationContext(amount: Money.fromRupees(3000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(3000) * 0.01);
    });

    // --- Cap boundary: txn_count measure (2 scenarios) ----------------------
    test('8. txn_count cap: transaction within remaining count gets full base rate', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(3),
        measure: CapMeasure.txnCount,
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': Money.fromRupees(1)});
      final ctx = RecommendationContext(amount: Money.fromRupees(10000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(10000) * 0.05);
    });

    test('9. txn_count cap: exhausted count gets full post-cap rate, never blended', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(3),
        measure: CapMeasure.txnCount,
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final card = baseCard(id: 'card', caps: [cap]);
      final snap = CardSnapshot(product: card, capRemaining: {'c': const Money.zero()});
      final ctx = RecommendationContext(amount: Money.fromRupees(10000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(10000) * 0.01);
    });

    // --- Milestone flip (4 scenarios) ---------------------------------------
    test('10. milestone: a spend covering less than the material fraction adds no bonus', () {
      final milestone = MilestoneRule(
        id: 'm',
        label: 'Spend ₹1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(1000),
      );
      final card = baseCard(id: 'card', milestones: [milestone]);
      final snap = CardSnapshot(product: card, milestoneProgress: {'m': Money.fromRupees(10000)});
      // Remaining = 90000; a 1000 spend covers ~1.1%, well under the 50% default bar.
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(1000) * 0.05); // base rate only, no bonus
    });

    test('11. milestone: a spend materially advancing but not completing it adds a pro-rated bonus', () {
      final milestone = MilestoneRule(
        id: 'm',
        label: 'Spend ₹1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(1000),
      );
      final card = baseCard(id: 'card', milestones: [milestone]);
      // Remaining = 60000; a 40000 spend covers 66%, over the 50% bar, but doesn't complete it.
      final snap = CardSnapshot(product: card, milestoneProgress: {'m': Money.fromRupees(40000)});
      final ctx = RecommendationContext(amount: Money.fromRupees(40000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      final base = Money.fromRupees(40000) * 0.05;
      final bonus = Money.fromRupees(1000) * (40000 / 100000);
      expect(r.expectedValue, base + bonus);
      expect(r.reasonLines.any((l) => l.contains('materially advances')), isTrue);
    });

    test('12. milestone: a spend that exactly completes it claims a bonus pro-rated to this txn\'s share', () {
      final milestone = MilestoneRule(
        id: 'm',
        label: 'Spend ₹1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(1000),
      );
      final card = baseCard(id: 'card', milestones: [milestone]);
      final snap = CardSnapshot(product: card, milestoneProgress: {'m': Money.fromRupees(70000)});
      final ctx = RecommendationContext(amount: Money.fromRupees(30000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      final base = Money.fromRupees(30000) * 0.05;
      // Bonus is pro-rated to closedPortion/thresholdSpend (this txn's own 30% share of the
      // total milestone), not the whole remaining reward — the first 70% was already
      // credited to whichever earlier transactions built up milestoneProgress.
      final bonus = Money.fromRupees(1000) * (30000 / 100000);
      expect(r.expectedValue, base + bonus);
      expect(r.reasonLines.any((l) => l.contains('completes')), isTrue);
    });

    test('13. milestone: already fully achieved adds no further bonus', () {
      final milestone = MilestoneRule(
        id: 'm',
        label: 'Spend ₹1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(1000),
      );
      final card = baseCard(id: 'card', milestones: [milestone]);
      final snap = CardSnapshot(product: card, milestoneProgress: {'m': Money.fromRupees(150000)});
      final ctx = RecommendationContext(amount: Money.fromRupees(5000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.expectedValue, Money.fromRupees(5000) * 0.05); // base only
    });

    // --- Override (2 scenarios) ---------------------------------------------
    test('14. override forces a card to the top even when its value is lower', () {
      final winner = baseCard(id: 'high-rate', rate: 10);
      final overridden = baseCard(id: 'low-rate', rate: 1);
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final results = engine.rank(ctx, [
        CardSnapshot(product: winner),
        CardSnapshot(product: overridden, forcedOverrideCardId: 'low-rate'),
      ]);
      expect(results.first.card.id, 'low-rate');
      expect(results.first.isOverride, isTrue);
      expect(results.first.reasonLines.any((l) => l.contains('override')), isTrue);
    });

    test('15. a card is never marked as its own override unless forcedOverrideCardId matches it', () {
      final card = baseCard(id: 'card-x', rate: 5);
      final other = baseCard(id: 'card-y', rate: 5);
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final results = engine.rank(ctx, [
        CardSnapshot(product: card, forcedOverrideCardId: 'card-y'), // targets the OTHER card
        CardSnapshot(product: other, forcedOverrideCardId: 'card-y'),
      ]);
      final cardX = results.firstWhere((r) => r.card.id == 'card-x');
      final cardY = results.firstWhere((r) => r.card.id == 'card-y');
      expect(cardX.isOverride, isFalse);
      expect(cardY.isOverride, isTrue);
    });

    // --- P2P / UPI exclusion gate (4 scenarios) ------------------------------
    test('16. P2P transfers exclude every card, even on swipe rail', () {
      final card = baseCard(id: 'card');
      final ctx = RecommendationContext(amount: Money.fromRupees(500), rail: TxnRail.swipe, isP2P: true);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.isExcluded, isTrue);
      expect(r.exclusionReason, contains('personal transfers'));
    });

    test('17. P2P transfers exclude every card on the UPI-QR rail too', () {
      final card = baseCard(id: 'card');
      final ctx = RecommendationContext(amount: Money.fromRupees(500), rail: TxnRail.upiQr, isP2P: true);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.isExcluded, isTrue);
    });

    test('18. a non-RuPay/UPI-linkable card is excluded on the UPI-QR rail', () {
      final card = baseCard(id: 'card', upiLinkable: false);
      final ctx = RecommendationContext(amount: Money.fromRupees(500), rail: TxnRail.upiQr);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.isExcluded, isTrue);
      expect(r.exclusionReason, contains('UPI'));
    });

    test('19. the same non-UPI-linkable card is fully eligible on the swipe rail', () {
      final card = baseCard(id: 'card', upiLinkable: false);
      final ctx = RecommendationContext(amount: Money.fromRupees(500), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.isExcluded, isFalse);
      expect(r.expectedValue, Money.fromRupees(25));
    });

    // --- Travel / forex (2 scenarios) ----------------------------------------
    test('20. travel mode subtracts forex markup including GST from the reward value', () {
      final card = baseCard(id: 'card', forex: const ForexRule(markupPercent: 2, gstOnMarkup: true));
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe, travelMode: true);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      final reward = Money.fromRupees(1000) * 0.05;
      final markup = Money.fromRupees(1000) * (0.02 * 1.18);
      expect(r.expectedValue, reward - markup);
    });

    test('21. forex markup is not applied when travelMode is false, even if the card has a forex rule', () {
      final card = baseCard(id: 'card', forex: const ForexRule(markupPercent: 2, gstOnMarkup: true));
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe, travelMode: false);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.expectedValue, Money.fromRupees(1000) * 0.05);
    });

    // --- Fuel surcharge waiver (2 scenarios) ---------------------------------
    test('22. fuel surcharge waiver adds value for a fuel-category spend', () {
      final card = baseCard(
        id: 'card',
        categoryId: 'fuel',
        fuel: const FuelSurchargeRule(surchargePercent: 1, waiverPercent: 1),
      );
      final ctx = RecommendationContext(amount: Money.fromRupees(2000), categoryId: 'fuel', rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      final base = Money.fromRupees(2000) * 0.05;
      final waiver = Money.fromRupees(2000) * 0.01;
      expect(r.expectedValue, base + waiver);
    });

    test('23. fuel surcharge waiver does NOT apply outside the fuel category, even if the card has the rule', () {
      final card = baseCard(
        id: 'card',
        fuel: const FuelSurchargeRule(surchargePercent: 1, waiverPercent: 1),
      );
      final ctx = RecommendationContext(amount: Money.fromRupees(2000), categoryId: 'dining', rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.expectedValue, Money.fromRupees(2000) * 0.05); // no waiver added
    });

    // --- No-limit card / bare card / category mismatch (3 scenarios) --------
    test('24. a card with no cap rules at all gets the full base rate regardless of amount size', () {
      final card = baseCard(id: 'card'); // no caps
      final ctx = RecommendationContext(amount: Money.fromRupees(500000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.expectedValue, Money.fromRupees(500000) * 0.05);
    });

    test('25. a card with no reward rules at all is excluded, not silently zero-valued', () {
      final card = CardProduct(id: 'bare', name: 'bare', network: CardNetwork.rupay);
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.isExcluded, isTrue);
      expect(r.exclusionReason, 'No applicable reward rule.');
    });

    test('26. a category-specific rule does not match a different category, falling back to exclusion '
        'when there is no base (categoryId==null) rule to catch it', () {
      final card = baseCard(id: 'card', categoryId: 'fuel');
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), categoryId: 'dining', rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.isExcluded, isTrue);
    });

    test("26b. a card whose category rule doesn't match still earns its own base rate, "
        'rather than being excluded as if it earned nothing', () {
      final card = CardProduct(
        id: 'card',
        name: 'card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1,
        rewardRules: [
          RewardRule(id: 'r', unit: RewardUnit.cashbackPercent, rate: 5, categoryId: 'fuel'),
        ],
      );
      final ctx =
          RecommendationContext(amount: Money.fromRupees(1000), categoryId: 'dining', rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.isExcluded, isFalse);
      expect(r.expectedValue, Money.fromRupees(10)); // 1% of ₹1,000
      expect(r.reasonLines.single, contains('Base rate 1.0%'));
    });

    test('26c. a flatPoints base rate is still an exclusion — it is a fixed bonus, not a '
        'per-rupee rate, so it must not be advertised as "Base rate 0.0%"', () {
      final card = CardProduct(
        id: 'card',
        name: 'card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        baseRewardUnit: RewardUnit.flatPoints,
        baseRewardRate: 500,
        pointValueInr: 1,
      );
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.isExcluded, isTrue);
      expect(r.exclusionReason, 'No applicable reward rule.');
    });

    // --- Rule priority (1 scenario) ------------------------------------------
    test('27. of two matching reward rules, the lower-numbered priority wins', () {
      final card = CardProduct(
        id: 'card',
        name: 'card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        rewardRules: [
          RewardRule(id: 'r-low-priority', unit: RewardUnit.cashbackPercent, rate: 1, priority: 100),
          RewardRule(id: 'r-high-priority', unit: RewardUnit.cashbackPercent, rate: 9, priority: 1),
        ],
      );
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final r = engine.rank(ctx, [CardSnapshot(product: card)]).first;
      expect(r.expectedValue, Money.fromRupees(90)); // the 9% rule (priority 1) wins, not the 1% one
    });

    // --- Tie-break and totality (4 scenarios) --------------------------------
    test('28. three cards tied on expected value break the tie deterministically by card id', () {
      final cards = ['card-c', 'card-a', 'card-b'].map((id) => baseCard(id: id, rate: 5)).toList();
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final results = engine.rank(ctx, cards.map((c) => CardSnapshot(product: c)).toList());
      expect(results.map((r) => r.card.id).toList(), ['card-a', 'card-b', 'card-c']);
    });

    test('29. excluded cards always sort after every eligible card, regardless of relative value', () {
      final excluded = baseCard(id: 'excluded', rate: 100, upiLinkable: false); // huge nominal rate
      final eligible = baseCard(id: 'eligible', rate: 1);
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.upiQr);
      final results = engine.rank(ctx, [
        CardSnapshot(product: excluded),
        CardSnapshot(product: eligible),
      ]);
      expect(results.first.card.id, 'eligible');
      expect(results.last.card.id, 'excluded');
    });

    test('30. zero cards in the wallet returns an empty ranking, not an error', () {
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final results = engine.rank(ctx, const []);
      expect(results, isEmpty);
    });

    test('31. ranking is total: every input card appears exactly once in the output, none dropped', () {
      final cards = List.generate(12, (i) => baseCard(id: 'card-$i', rate: (i % 4) + 1.0));
      final ctx = RecommendationContext(amount: Money.fromRupees(1000), rail: TxnRail.swipe);
      final results = engine.rank(ctx, cards.map((c) => CardSnapshot(product: c)).toList());
      expect(results, hasLength(12));
      expect(results.map((r) => r.card.id).toSet(), cards.map((c) => c.id).toSet());
    });

    // --- Kitchen sink: everything interacting on one card (2 scenarios) -----
    test('32. cap blending + fuel waiver + milestone bonus all combine correctly on one transaction', () {
      final cap = CapRule(
        id: 'c',
        rewardRuleId: 'card-rule',
        label: 'cap',
        capValue: Money.fromRupees(3000),
        measure: CapMeasure.spendAmount,
        period: CapPeriod.calendarMonth,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final milestone = MilestoneRule(
        id: 'm',
        label: 'Spend ₹1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(1000),
      );
      final card = baseCard(
        id: 'card',
        categoryId: 'fuel',
        caps: [cap],
        milestones: [milestone],
        fuel: const FuelSurchargeRule(surchargePercent: 1, waiverPercent: 1),
      );
      final snap = CardSnapshot(
        product: card,
        capRemaining: {'c': Money.fromRupees(2000)}, // will blend
        milestoneProgress: {'m': Money.fromRupees(90000)}, // will complete
      );
      final ctx = RecommendationContext(amount: Money.fromRupees(5000), categoryId: 'fuel', rail: TxnRail.swipe);
      final r = engine.rank(ctx, [snap]).first;

      final capValue = Money.fromRupees(2000) * 0.05 + Money.fromRupees(3000) * 0.01; // 100 + 30 = 130
      final waiver = Money.fromRupees(5000) * 0.01; // 50
      // Milestone bonus is pro-rated to this txn's own share (5000/100000), same rule as #12.
      final milestoneBonus = Money.fromRupees(1000) * (5000 / 100000); // 50
      expect(r.expectedValue, capValue + waiver + milestoneBonus);
    });

    test('33. an excluded card (P2P) never carries a milestone bonus or fuel waiver either', () {
      final milestone = MilestoneRule(
        id: 'm',
        label: 'Spend ₹1L',
        thresholdSpend: Money.fromRupees(100000),
        rewardValue: Money.fromRupees(1000),
      );
      final card = baseCard(
        id: 'card',
        categoryId: 'fuel',
        milestones: [milestone],
        fuel: const FuelSurchargeRule(surchargePercent: 1, waiverPercent: 1),
      );
      final snap = CardSnapshot(product: card, milestoneProgress: {'m': Money.fromRupees(99000)});
      final ctx = RecommendationContext(amount: Money.fromRupees(5000), categoryId: 'fuel', rail: TxnRail.swipe, isP2P: true);
      final r = engine.rank(ctx, [snap]).first;
      expect(r.isExcluded, isTrue);
      expect(r.expectedValue, const Money.zero());
    });
  });
}
