import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

CardProduct _card(String id, double rate, {List<CapRule> caps = const []}) {
  return CardProduct(
    id: id,
    name: id,
    network: CardNetwork.rupay,
    isUpiLinkable: true,
    rewardRules: [
      RewardRule(id: '$id-rule', unit: RewardUnit.cashbackPercent, rate: rate),
    ],
    capRules: caps,
  );
}

void main() {
  group('UA-2.4.1 credit utilization', () {
    test('under threshold reports no split recommendation', () {
      final result = creditUtilization(
        Money.fromRupees(2000),
        Money.fromRupees(10000),
      );
      expect(result.ratio, closeTo(0.2, 0.001));
      expect(result.overThreshold, isFalse);
      expect(result.splitRecommendationAmount, isNull);
    });

    test('over the 30% threshold recommends moving the excess', () {
      final result = creditUtilization(
        Money.fromRupees(5000),
        Money.fromRupees(10000),
      );
      expect(result.overThreshold, isTrue);
      expect(result.splitRecommendationAmount, Money.fromRupees(2000));
    });

    test('a zero limit never divides by zero', () {
      final result = creditUtilization(
        Money.fromRupees(100),
        const Money.zero(),
      );
      expect(result.ratio, 0);
      expect(result.overThreshold, isFalse);
    });
  });

  group('UA-2.2.4 milestone bonus', () {
    final engine = RecommendationEngine(milestoneMaterialFraction: 0.5);

    test('a spend below the material fraction adds no bonus', () {
      final card = CardProduct(
        id: 'card',
        name: 'card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        rewardRules: [
          RewardRule(id: 'r', unit: RewardUnit.cashbackPercent, rate: 1),
        ],
        milestoneRules: [
          MilestoneRule(
            id: 'm1',
            label: 'Annual spend bonus',
            thresholdSpend: Money.fromRupees(100000),
            rewardValue: Money.fromRupees(1000),
          ),
        ],
      );
      final snapshot = CardSnapshot(
        product: card,
        milestoneProgress: {'m1': Money.fromRupees(50000)}, // 50k remaining
      );
      final ctx = RecommendationContext(
        amount: Money.fromRupees(1000),
        rail: TxnRail.swipe,
      ); // 2% of remaining

      final result = engine.rank(ctx, [snapshot]).first;
      // Only the 1% base rate, no milestone line.
      expect(result.expectedValue, Money.fromRupees(10));
      expect(result.reasonLines.any((l) => l.contains('milestone')), isFalse);
    });

    test(
      'a spend covering >= 50% of the remaining threshold adds a pro-rated bonus',
      () {
        final card = CardProduct(
          id: 'card',
          name: 'card',
          network: CardNetwork.rupay,
          isUpiLinkable: true,
          rewardRules: [
            RewardRule(id: 'r', unit: RewardUnit.cashbackPercent, rate: 1),
          ],
          milestoneRules: [
            MilestoneRule(
              id: 'm1',
              label: 'Annual spend bonus',
              thresholdSpend: Money.fromRupees(1000),
              rewardValue: Money.fromRupees(100),
            ),
          ],
        );
        // Remaining = 1000 - 400 = 600. Spend 500 -> covers 500/600 = 83% >= 50%.
        final snapshot = CardSnapshot(
          product: card,
          milestoneProgress: {'m1': Money.fromRupees(400)},
        );
        final ctx = RecommendationContext(
          amount: Money.fromRupees(500),
          rail: TxnRail.swipe,
        );

        final result = engine.rank(ctx, [snapshot]).first;
        final base = Money.fromRupees(5); // 1% of 500
        final bonus =
            Money.fromRupees(100) * (500 / 1000); // closedPortion/threshold
        expect(result.expectedValue, base + bonus);
        expect(
          result.reasonLines.any((l) => l.contains('materially advances')),
          isTrue,
        );
      },
    );

    test(
      'a spend that completes the milestone says "completes" and caps the bonus at the remaining gap',
      () {
        final card = CardProduct(
          id: 'card',
          name: 'card',
          network: CardNetwork.rupay,
          isUpiLinkable: true,
          rewardRules: [
            RewardRule(id: 'r', unit: RewardUnit.cashbackPercent, rate: 1),
          ],
          milestoneRules: [
            MilestoneRule(
              id: 'm1',
              label: 'Annual spend bonus',
              thresholdSpend: Money.fromRupees(1000),
              rewardValue: Money.fromRupees(100),
            ),
          ],
        );
        // Remaining = 200. Spend 5000, way over -> closedPortion is capped at 200.
        final snapshot = CardSnapshot(
          product: card,
          milestoneProgress: {'m1': Money.fromRupees(800)},
        );
        final ctx = RecommendationContext(
          amount: Money.fromRupees(5000),
          rail: TxnRail.swipe,
        );

        final result = engine.rank(ctx, [snapshot]).first;
        final base = Money.fromRupees(50); // 1% of 5000
        final bonus =
            Money.fromRupees(100) *
            (200 / 1000); // only the remaining 200 counts
        expect(result.expectedValue, base + bonus);
        expect(result.reasonLines.any((l) => l.contains('completes')), isTrue);
      },
    );

    test('an already-achieved milestone contributes nothing further', () {
      final card = CardProduct(
        id: 'card',
        name: 'card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        rewardRules: [
          RewardRule(id: 'r', unit: RewardUnit.cashbackPercent, rate: 1),
        ],
        milestoneRules: [
          MilestoneRule(
            id: 'm1',
            label: 'Annual spend bonus',
            thresholdSpend: Money.fromRupees(1000),
            rewardValue: Money.fromRupees(100),
          ),
        ],
      );
      final snapshot = CardSnapshot(
        product: card,
        milestoneProgress: {'m1': Money.fromRupees(1000)},
      );
      final ctx = RecommendationContext(
        amount: Money.fromRupees(500),
        rail: TxnRail.swipe,
      );

      final result = engine.rank(ctx, [snapshot]).first;
      expect(result.expectedValue, Money.fromRupees(5)); // 1% only, no bonus
    });
  });

  group('UA-2.4.2 split optimizer', () {
    test('keeps two owned cards of the same product independent', () {
      final product = _card('same', 2);
      final first = CardSnapshot(product: product);
      final second = CardSnapshot(product: product);
      final total = Money.fromRupees(100);
      final result = const SplitOptimizer().optimize(
        total,
        RecommendationContext(amount: total, rail: TxnRail.swipe),
        [first, second],
        snapshotCeilings: {
          first: Money.fromRupees(30),
          second: Money.fromRupees(70),
        },
      );
      expect(result.map((r) => r.amount), [
        Money.fromRupees(30),
        Money.fromRupees(70),
      ]);
    });
    test('never exceeds headroom smaller than a search step', () {
      final total = Money.fromRupees(1000);
      final result = const SplitOptimizer().optimize(
        total,
        RecommendationContext(amount: total, rail: TxnRail.swipe),
        [
          CardSnapshot(product: _card('high', 10)),
          CardSnapshot(product: _card('low', 2)),
        ],
        utilizationCeiling: {
          'high': Money.fromRupees(13.37),
          'low': Money.fromRupees(20),
        },
      );
      expect(
        result.firstWhere((r) => r.card.id == 'high').amount,
        Money.fromRupees(13.37),
      );
      expect(
        result.firstWhere((r) => r.card.id == 'low').amount,
        Money.fromRupees(20),
      );
    });

    test('places one paise and ignores negative ceilings', () {
      const total = Money.fromPaise(1);
      final result = const SplitOptimizer().optimize(
        total,
        RecommendationContext(amount: total, rail: TxnRail.swipe),
        [
          CardSnapshot(product: _card('high', 10)),
          CardSnapshot(product: _card('low', 2)),
        ],
        utilizationCeiling: {'high': const Money.fromPaise(-1)},
      );
      expect(result.single.card.id, 'low');
      expect(result.single.amount, total);
    });

    test('rejects invalid step counts', () {
      expect(
        () => const SplitOptimizer().optimize(
          const Money.fromPaise(1),
          RecommendationContext(
            amount: const Money.fromPaise(1),
            rail: TxnRail.swipe,
          ),
          [],
          stepCount: 0,
        ),
        throwsArgumentError,
      );
    });
    test('fills the higher-rate card first, then spills over to the next', () {
      final optimizer = SplitOptimizer();
      final highRateCap = CapRule(
        id: 'cap',
        rewardRuleId: 'high-rule',
        label: 'cap',
        capValue: Money.fromRupees(400),
        measure: CapMeasure.spendAmount,
        period: CapPeriod.statementCycle,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 0,
      );
      final highCard = CardProduct(
        id: 'high',
        name: 'high',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        rewardRules: [
          RewardRule(
            id: 'high-rule',
            unit: RewardUnit.cashbackPercent,
            rate: 10,
          ),
        ],
        capRules: [highRateCap],
      );
      final lowCard = _card('low', 2);

      final results = optimizer.optimize(
        Money.fromRupees(1000),
        RecommendationContext(
          amount: Money.fromRupees(1000),
          rail: TxnRail.swipe,
        ),
        [
          CardSnapshot(
            product: highCard,
            capRemaining: {'cap': Money.fromRupees(400)},
          ),
          CardSnapshot(product: lowCard),
        ],
        stepCount: 20,
      );

      expect(results, isNotEmpty);
      final highAlloc = results.firstWhere((r) => r.card.id == 'high');
      // Should fill close to the 400 cap headroom on the high-rate card first.
      expect(highAlloc.amount.rupees, greaterThan(300));
      final total = results.fold<Money>(
        const Money.zero(),
        (sum, r) => sum + r.amount,
      );
      expect(total, Money.fromRupees(1000));
    });

    test('keeps category context when valuing the final split allocations', () {
      final optimizer = SplitOptimizer();
      final fuelCard = CardProduct(
        id: 'fuel-card',
        name: 'fuel-card',
        network: CardNetwork.rupay,
        isUpiLinkable: true,
        excludedCategoryIds: const ['fuel'],
        fuelRule: const FuelSurchargeRule(
          surchargePercent: 1.0,
          waiverPercent: 1.0,
        ),
      );

      final results = optimizer.optimize(
        Money.fromRupees(1000),
        RecommendationContext(
          amount: Money.fromRupees(1000),
          categoryId: 'fuel',
          categorySlug: 'fuel',
          mcc: '5541',
          vpa: 'fuel@upi',
          rail: TxnRail.swipe,
        ),
        [CardSnapshot(product: fuelCard)],
        stepCount: 1,
      );

      expect(results, hasLength(1));
      expect(results.single.expectedValue, Money.fromRupees(10));
    });

    test('reduces reward-value caps in reward units, not spend units', () {
      final optimizer = SplitOptimizer();
      final cap = CapRule(
        id: 'reward-cap',
        rewardRuleId: 'high-rule',
        label: 'cap',
        capValue: Money.fromRupees(100),
        measure: CapMeasure.rewardValue,
        period: CapPeriod.calendarMonth,
        postCapUnit: RewardUnit.cashbackPercent,
        postCapRate: 1,
      );
      final highCard = CardProduct(
        id: 'high-reward-card',
        name: 'high-reward-card',
        network: CardNetwork.visa,
        isUpiLinkable: true,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1,
        rewardRules: [
          const RewardRule(
            id: 'high-rule',
            unit: RewardUnit.cashbackPercent,
            rate: 10,
          ),
        ],
        capRules: [cap],
      );
      final lowCard = _card('low-reward-card', 2);

      final results = optimizer.optimize(
        Money.fromRupees(2000),
        RecommendationContext(
          amount: Money.fromRupees(2000),
          rail: TxnRail.swipe,
        ),
        [
          CardSnapshot(
            product: highCard,
            capRemaining: {'reward-cap': Money.fromRupees(100)},
          ),
          CardSnapshot(product: lowCard),
        ],
        stepCount: 20,
      );

      final highAllocation = results.firstWhere(
        (r) => r.card.id == 'high-reward-card',
      );
      // ₹100 of reward headroom at 10% covers ₹1,000 of spend.
      expect(highAllocation.amount.rupees, closeTo(1000, 100));
      expect(highAllocation.expectedValue, Money.fromRupees(100));
    });
  });

  group('UA-2.4.3 billing cycle float', () {
    test('computes days until next statement plus grace period', () {
      final clock = TestClock(DateTime(2026, 3, 10));
      final result = billingCycleFloat(
        statementDay: 20,
        gracePeriodDays: 20,
        clock: clock,
      );
      expect(result.daysUntilStatement, 10);
      expect(result.totalInterestFreeDays, 30);
    });

    test('rolls over to next month when statement day already passed', () {
      final clock = TestClock(DateTime(2026, 3, 25));
      final result = billingCycleFloat(
        statementDay: 20,
        gracePeriodDays: 20,
        clock: clock,
      );
      // Next statement is April 20 -> 26 days away (Mar 25 -> Apr 20).
      expect(result.daysUntilStatement, 26);
    });
  });

  group('UA-2.4.4 EMI advisor', () {
    test('zero-interest EMI has no cost beyond forgone rewards', () {
      final advice = adviseEmi(
        principal: Money.fromRupees(12000),
        annualInterestRatePercent: 0,
        tenureMonths: 12,
        forgoneRewardValue: Money.fromRupees(120),
      );
      expect(advice.totalInterest, const Money.zero());
      expect(advice.effectiveCost, Money.fromRupees(120));
      expect(advice.verdictLine, contains('more than paying in full'));
    });

    test(
      'non-zero interest produces a positive effective cost and warns against it',
      () {
        final advice = adviseEmi(
          principal: Money.fromRupees(50000),
          annualInterestRatePercent: 15,
          tenureMonths: 6,
          forgoneRewardValue: Money.fromRupees(500),
        );
        expect(advice.totalInterest.paise, greaterThan(0));
        expect(
          advice.effectiveCost.paise,
          greaterThan(advice.totalInterest.paise),
        );
        expect(advice.verdictLine, contains('avoid it'));
      },
    );
  });

  group('UA-2.4.5 UPI-vs-swipe comparison', () {
    test('surfaces the delta between the best card on each rail', () {
      final engine = RecommendationEngine();
      final rupayCard = _card('rupay-card', 5);
      final nonRupayHigherRate = CardProduct(
        id: 'visa-card',
        name: 'visa-card',
        network: CardNetwork.visa,
        isUpiLinkable: false,
        rewardRules: [
          RewardRule(id: 'v-rule', unit: RewardUnit.cashbackPercent, rate: 10),
        ],
      );
      final ctx = RecommendationContext(
        amount: Money.fromRupees(1000),
        rail: TxnRail.upiQr,
      );

      final comparison = compareRails(engine, ctx, [
        CardSnapshot(product: rupayCard),
        CardSnapshot(product: nonRupayHigherRate),
      ]);

      // On UPI only the RuPay card is eligible (5%); on swipe the Visa card
      // wins at 10% -> swipe pays more here.
      expect(comparison.upiTop.card.id, 'rupay-card');
      expect(comparison.swipeTop.card.id, 'visa-card');
      expect(comparison.delta.paise, greaterThan(0));
    });
  });
}
