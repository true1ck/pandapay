import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Dart-side wiring of the v2 engine into [RecommendationEngine.rank] and
/// the app-facing API. The reward maths itself is pinned by the shared
/// scenario files (reward_v2_scenarios_test.dart); this file covers what
/// those can't: the v1/v2 switch inside rank, the breakdown the UI reads,
/// cap state handed over as consumption or as remaining headroom, the
/// ranking-only adjustments (UPI gate, fuel waiver, forex), and reasons.

/// A v2 points card: 1 pt/₹100 base, 10 pts/₹100 in the PhonePe app with a
/// 1,500-point monthly bonus cap and a 2,000-point card-wide total cap.
CardProduct _pointsCard({
  ForexRule? forex,
  FuelSurchargeRule? fuel,
  List<String> excluded = const [],
}) => CardProduct(
  id: 'v2-points',
  name: 'V2 Points',
  network: CardNetwork.visa,
  pointValueInr: 0.25,
  baseRewardUnit: RewardUnit.pointsPer100,
  baseRewardRate: 1,
  accrualRounding: AccrualRounding.floor,
  excludedCategoryIds: excluded,
  forexRule: forex,
  fuelRule: fuel,
  rewardRules: const [
    RewardRule(
      id: 'app',
      unit: RewardUnit.pointsPer100,
      rate: 10,
      priority: 10,
      role: RuleRole.earn,
      platformSlugs: ['phonepe_app'],
      displayNote: '10 pts/₹100 in the PhonePe app',
    ),
    RewardRule(
      id: 'swiggy',
      unit: RewardUnit.pointsPer100,
      rate: 5,
      priority: 20,
      role: RuleRole.earn,
      merchantSlugs: ['swiggy'],
    ),
    RewardRule(
      id: 'base',
      unit: RewardUnit.pointsPer100,
      rate: 1,
      priority: 100,
      role: RuleRole.base,
    ),
  ],
  capRules: [
    CapRule(
      id: 'app-bonus',
      rewardRuleId: 'app',
      label: 'PhonePe bonus points',
      capValue: Money.fromRupees(375),
      measure: CapMeasure.rewardValue,
      period: CapPeriod.calendarMonth,
      capKind: CapKind.bonusPoints,
      capAmount: 1500,
      targets: const ['app'],
    ),
    CapRule(
      id: 'total',
      label: 'All points',
      capValue: Money.fromRupees(500),
      measure: CapMeasure.rewardValue,
      period: CapPeriod.calendarMonth,
      postCapRate: 0,
      capKind: CapKind.totalPoints,
      capAmount: 2000,
      scope: CapScope.card,
    ),
  ],
);

RecommendationContext _ctx(
  double amount, {
  String? platform,
  String? merchantName,
  String? merchantSlug,
  String? categoryId,
  String? categorySlug,
  TxnRail rail = TxnRail.online,
  bool travelMode = false,
  bool isP2P = false,
}) => RecommendationContext(
  amount: Money.fromRupees(amount),
  platform: platform,
  merchantName: merchantName,
  merchantSlug: merchantSlug,
  categoryId: categoryId,
  categorySlug: categorySlug,
  rail: rail,
  travelMode: travelMode,
  isP2P: isP2P,
);

final _directory = MerchantDirectory.fromJson({
  'merchants': [
    {
      'slug': 'swiggy',
      'name': 'Swiggy',
      'aliases': ['swiggy', 'bundl technologies'],
    },
  ],
  'platforms': const [],
});

void main() {
  group('rank routes by card shape (C3.2/D10)', () {
    test('a v2 card ranks through the C3 path and exposes the reward', () {
      final rec = const RecommendationEngine().rank(
        _ctx(2000, platform: 'phonepe_app'),
        [CardSnapshot(product: _pointsCard())],
      ).single;
      final reward = rec.reward!;
      expect(reward.engineVersion, 2);
      expect(reward.points, 200);
      expect(reward.cashbackInr, isNull);
      expect(reward.ruleId, 'app');
      expect(reward.capDeltas, {'app-bonus': 180, 'total': 200});
      expect(rec.expectedValue, Money.fromRupees(50));
      expect(rec.effectiveRatePerRupee, closeTo(0.025, 1e-12));
      expect(rec.reasonLines.first, '10 pts/₹100 in the PhonePe app');
    });

    test('a v1-shaped card is unchanged and carries no reward', () {
      const card = CardProduct(
        id: 'v1',
        name: 'V1',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1,
        rewardRules: [
          RewardRule(
            id: 'online',
            rail: TxnRail.online,
            unit: RewardUnit.cashbackPercent,
            rate: 5,
            priority: 10,
            // DB defaults after the v2 migration: still v1-shaped (D10).
            role: RuleRole.earn,
          ),
        ],
      );
      expect(card.isV2Shaped, isFalse);
      final rec = const RecommendationEngine().rank(
        _ctx(1000, rail: TxnRail.unknown),
        [const CardSnapshot(product: card)],
      ).single;
      // v1: an unknown rail still matches the online rule.
      expect(rec.expectedValue, Money.fromRupees(50));
      expect(rec.reward, isNull);
      expect(rec.breakdown!.baseRatePerRupee, 0.05);

      final direct = RecommendationEngine.evaluateRewardV2(
        card,
        _ctx(1000, rail: TxnRail.unknown),
      );
      expect(direct.engineVersion, 1);
      expect(direct.ruleId, 'online');
      expect(direct.valueInr, 50);
      expect(direct.cashbackInr, 50);
    });

    test('computeRewardV2 applies C3 to any card when asked directly', () {
      const card = CardProduct(
        id: 'v1',
        name: 'V1',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1,
        rewardRules: [
          RewardRule(
            id: 'online',
            rail: TxnRail.online,
            unit: RewardUnit.cashbackPercent,
            rate: 5,
          ),
        ],
      );
      final result = computeRewardV2(card, _ctx(1000, rail: TxnRail.unknown));
      expect(result.ruleId, isNull, reason: 'unknown rail misses on v2');
      expect(result.cashbackInr, 10);
    });
  });

  group('cap state', () {
    test('native consumption in capConsumed is used as is', () {
      final rec = const RecommendationEngine().rank(
        _ctx(2000, platform: 'phonepe_app'),
        [
          CardSnapshot(
            product: _pointsCard(),
            capConsumed: const {'app-bonus': 1450},
          ),
        ],
      ).single;
      expect(rec.reward!.points, 70);
      expect(rec.reward!.capDeltas, {'app-bonus': 50, 'total': 70});
    });

    test('without capConsumed, consumption is recovered from capRemaining', () {
      final card = _pointsCard();
      // The app today passes capValue − consumed; cap_states for v2 cards
      // hold native units, so capValue − capRemaining is that consumption.
      final snapshot = CardSnapshot(
        product: card,
        capRemaining: {'app-bonus': Money.fromRupees(375 - 1450)},
      );
      expect(snapshot.v2CapConsumed, {'app-bonus': 1450});
      final rec = const RecommendationEngine().rank(
        _ctx(2000, platform: 'phonepe_app'),
        [snapshot],
      ).single;
      expect(rec.reward!.points, 70);
    });

    test('capConsumed wins over capRemaining', () {
      final snapshot = CardSnapshot(
        product: _pointsCard(),
        capRemaining: {'app-bonus': Money.fromRupees(0)},
        capConsumed: const {'app-bonus': 100},
      );
      expect(snapshot.v2CapConsumed['app-bonus'], 100);
    });
  });

  group('breakdown for the UI', () {
    test('a bonus cap in points shows as reward value at ₹/point', () {
      final rec = const RecommendationEngine().rank(
        _ctx(2000, platform: 'phonepe_app'),
        [
          CardSnapshot(
            product: _pointsCard(),
            capConsumed: const {'app-bonus': 1450},
          ),
        ],
      ).single;
      final b = rec.breakdown!;
      expect(b.capStatus, CapStatus.partiallyConsumed);
      expect(b.capMeasure, CapMeasure.rewardValue);
      expect(b.capRemaining, Money.fromRupees(12.5)); // 50 pts × ₹0.25
      expect(b.capLimit, Money.fromRupees(375)); // 1,500 pts × ₹0.25
      expect(b.capPeriod, CapPeriod.calendarMonth);
      expect(b.capNote, 'Only 50 bonus pts left');
      expect(b.pointValueInr, 0.25);
      expect(b.baseRatePerRupee, closeTo(0.025, 1e-12));
      expect(b.effectiveRatePerRupee, closeTo(17.5 / 2000, 1e-12));
    });

    test('an exhausted bonus cap reads as reached', () {
      final rec = const RecommendationEngine().rank(
        _ctx(2000, platform: 'phonepe_app'),
        [
          CardSnapshot(
            product: _pointsCard(),
            capConsumed: const {'app-bonus': 1500},
          ),
        ],
      ).single;
      expect(rec.breakdown!.capStatus, CapStatus.reached);
      expect(rec.breakdown!.capNote, 'Cap reached');
      expect(rec.expectedValue, Money.fromRupees(5));
    });

    test('merchant restriction shows the merchant slugs', () {
      final rec = RecommendationEngine(merchantDirectory: _directory).rank(
        _ctx(1000, merchantName: 'BUNDL TECHNOLOGIES'),
        [CardSnapshot(product: _pointsCard())],
      ).single;
      expect(rec.reward!.ruleId, 'swiggy');
      expect(rec.breakdown!.merchantRestriction, 'swiggy');
      expect(rec.reward!.assumptions, contains('merchant_resolved_by_alias'));
      expect(rec.reward!.merchant!.slug, 'swiggy');
    });
  });

  group('merchant directory', () {
    test('without a directory, a merchant-slug rule needs merchantSlug', () {
      final noDirectory = const RecommendationEngine().rank(
        _ctx(1000, merchantName: 'Swiggy'),
        [CardSnapshot(product: _pointsCard())],
      ).single;
      expect(noDirectory.reward!.ruleId, 'base');

      final withSlug = const RecommendationEngine().rank(
        _ctx(1000, merchantSlug: 'swiggy'),
        [CardSnapshot(product: _pointsCard())],
      ).single;
      expect(withSlug.reward!.ruleId, 'swiggy');
      expect(withSlug.reward!.points, 50);
    });

    test('ruleAppliesV2 takes the merchant lineage', () {
      final rule = _pointsCard().rewardRules[1];
      expect(
        RecommendationEngine.ruleAppliesV2(
          rule,
          _ctx(100),
          merchantLineage: const {'instamart', 'swiggy'},
        ),
        isTrue,
      );
      expect(RecommendationEngine.ruleAppliesV2(rule, _ctx(100)), isFalse);
    });
  });

  group('ranking-only adjustments on v2 cards', () {
    test('the UPI gate still excludes a non-UPI card before any maths', () {
      final rec = const RecommendationEngine().rank(
        _ctx(2000, platform: 'phonepe_app', rail: TxnRail.upiQr),
        [CardSnapshot(product: _pointsCard())],
      ).single;
      expect(rec.isExcluded, isTrue);
      expect(rec.reward, isNull);
    });

    test('personal transfers are excluded', () {
      final rec = const RecommendationEngine().rank(_ctx(500, isP2P: true), [
        CardSnapshot(product: _pointsCard()),
      ]).single;
      expect(rec.isExcluded, isTrue);
    });

    test('an excluded fuel spend still earns its surcharge waiver', () {
      final card = _pointsCard(
        excluded: const ['cat-fuel'],
        fuel: const FuelSurchargeRule(surchargePercent: 1, waiverPercent: 1),
      );
      final rec = const RecommendationEngine().rank(
        _ctx(1000, categoryId: 'cat-fuel', categorySlug: 'fuel'),
        [CardSnapshot(product: card)],
      ).single;
      expect(rec.isExcluded, isFalse);
      expect(rec.reward!.excluded, isTrue);
      expect(rec.reward!.capDeltas, isEmpty);
      expect(rec.expectedValue, Money.fromRupees(10));
      expect(rec.breakdown!.fuelWaiver, Money.fromRupees(10));
    });

    test('an excluded spend with no waiver is a greyed exclusion', () {
      final rec = const RecommendationEngine().rank(
        _ctx(1000, categoryId: 'cat-rent'),
        [
          CardSnapshot(product: _pointsCard(excluded: const ['cat-rent'])),
        ],
      ).single;
      expect(rec.isExcluded, isTrue);
      expect(rec.reward!.excluded, isTrue);
      expect(rec.reward!.reasons, ['excluded_category']);
    });

    test('travel mode deducts forex markup from the v2 value', () {
      final rec = const RecommendationEngine().rank(
        _ctx(2000, platform: 'phonepe_app', travelMode: true),
        [
          CardSnapshot(
            product: _pointsCard(
              forex: const ForexRule(markupPercent: 2, gstOnMarkup: false),
            ),
          ),
        ],
      ).single;
      expect(rec.reward!.valueInr, 50);
      expect(rec.expectedValue, Money.fromRupees(10)); // 50 − 40 markup
      expect(rec.breakdown!.forexCost, Money.fromRupees(40));
    });

    test('a v2 card ranks against a v1 card on one ₹ scale', () {
      const v1 = CardProduct(
        id: 'a-v1',
        name: 'V1 2%',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 2,
      );
      final ranked = const RecommendationEngine().rank(
        _ctx(2000, platform: 'phonepe_app'),
        [const CardSnapshot(product: v1), CardSnapshot(product: _pointsCard())],
      );
      expect(ranked.map((r) => r.card.id), ['v2-points', 'a-v1']);
    });
  });

  group('reasons (D12d)', () {
    test('a cap with no amount is skipped and reported', () {
      final card = CardProductJson.fromJson({
        'id': 'c',
        'name': 'C',
        'network': 'visa',
        'base_reward_unit': 'cashback_percent',
        'base_reward_rate': 1,
        'reward_rules': [
          {
            'id': 'r',
            'unit': 'cashback_percent',
            'rate': 5,
            'priority': 10,
            'rule_role': 'earn',
            'rail': 'online',
          },
        ],
        'cap_rules': [
          {
            'id': 'no-amount',
            'label': 'Depends on credit limit',
            'measure': 'reward_value',
            'period': 'calendar_month',
            'cap_value': 0,
            'cap_kind': 'total_cashback',
            'cap_amount': null,
            'targets': ['r'],
          },
          {
            'id': 'mystery',
            'label': 'Unknown kind',
            'measure': 'reward_value',
            'period': 'calendar_month',
            'cap_value': 0,
            'cap_kind': 'bonus_miles',
            'cap_amount': 10,
          },
        ],
      });
      final result = RecommendationEngine.evaluateRewardV2(card, _ctx(1000));
      expect(result.cashbackInr, 50);
      expect(result.capDeltas, isEmpty);
      expect(
        result.reasons,
        containsAll([
          'cap_skipped:mystery:unsupported_cap_kind',
          'cap_skipped:no-amount:cap_amount_null',
        ]),
      );
    });

    test('a legacy points cap on a card with no point value is skipped', () {
      final card = CardProduct(
        id: 'p',
        name: 'P',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.pointsPer100,
        baseRewardRate: 1,
        accrualRounding: AccrualRounding.floor,
        capRules: [
          CapRule(
            id: 'legacy',
            categoryId: 'cat-x',
            label: 'Legacy',
            capValue: Money.fromRupees(10),
            measure: CapMeasure.rewardValue,
            period: CapPeriod.calendarMonth,
          ),
        ],
      );
      final result = computeRewardV2(card, _ctx(1000, categoryId: 'cat-x'));
      expect(result.points, 10);
      expect(result.reasons, contains('cap_skipped:legacy:point_value_zero'));
      expect(result.assumptions, contains('implicit_base_rule'));
    });

    test('cap codes follow the JS engine', () {
      final result = computeRewardV2(
        _pointsCard(),
        _ctx(2000, platform: 'phonepe_app'),
        capConsumedBefore: const {'app-bonus': 1450, 'total': 1960},
      );
      expect(result.reasons, [
        '10 pts/₹100 in the PhonePe app',
        'bonus_cap_reached',
        'total_cap_reached',
      ]);
      expect(result.points, 40);
    });
  });
}
