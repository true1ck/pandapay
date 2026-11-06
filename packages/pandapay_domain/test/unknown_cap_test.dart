import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C8/D32c: an UNKNOWN cap (no native consumption figure yet) is
/// evaluated both ways, fresh and used up, and the lower value is kept. A
/// used-up cap is only the conservative reading when the rate after the limit
/// is not higher than the rate inside it. Axis Magnus pays 12 pts/₹200 inside
/// its ₹1.5 lakh limit and 35 above it: ₹10,000 fresh is ₹120, used up ₹350,
/// so feeding "unknown" as "used up" promised ₹350.
const _snapshotDir = '../../db/fixtures/catalogue_v2_cards';

Map<String, dynamic> _fixture(String slug) =>
    (jsonDecode(File('$_snapshotDir/$slug.json').readAsStringSync())
            as Map<String, dynamic>)['card']
        as Map<String, dynamic>;

Money _value(CardSnapshot snapshot, {double amount = 10000}) =>
    const RecommendationEngine()
        .rank(
          RecommendationContext(
            amount: Money.fromRupees(amount),
            rail: TxnRail.swipe,
            now: DateTime(2026, 11, 6),
          ),
          [snapshot],
        )
        .single
        .expectedValue;

/// 5 pts/₹100 with a 1,500-point bonus cap; base 1 pt/₹100; ₹0.25 a point.
/// Past the cap the bonus is lost, so used up is the LOWER reading.
CardProduct _bonusCard({List<CapRule>? caps}) => CardProduct(
  id: 'bonus',
  name: 'bonus',
  network: CardNetwork.visa,
  pointValueInr: 0.25,
  baseRewardUnit: RewardUnit.pointsPer100,
  baseRewardRate: 1,
  accrualRounding: AccrualRounding.floor,
  rewardRules: const [
    RewardRule(
      id: 'bonus-rule',
      unit: RewardUnit.pointsPer100,
      rate: 5,
      priority: 10,
    ),
  ],
  capRules:
      caps ??
      [
        CapRule(
          id: 'bonus-cap',
          label: 'Bonus cap',
          capValue: Money.fromRupees(375),
          measure: CapMeasure.rewardValue,
          period: CapPeriod.calendarMonth,
          capKind: CapKind.bonusPoints,
          capAmount: 1500,
          targets: const ['bonus-rule'],
        ),
      ],
);

void main() {
  group('Axis Magnus: a limit that pays MORE after it', () {
    final magnus = CardProductJson.fromJson(_fixture('axis-bank-magnus'));
    final cap = magnus.capRules.firstWhere(
      (c) => c.id.endsWith('base_150k_spend'),
    );

    test('fresh is ₹120 and known used-up is ₹350 (the conflict)', () {
      expect(_value(CardSnapshot(product: magnus)), Money.fromRupees(120));
      expect(
        _value(
          CardSnapshot(product: magnus, capConsumed: {cap.id: cap.capAmount!}),
        ),
        Money.fromRupees(350),
      );
    });

    test('UNKNOWN is never above fresh: ₹120, not the ₹350 of used up', () {
      final unknown = _value(
        CardSnapshot(product: magnus, unknownCapIds: {cap.id}),
      );
      expect(unknown, Money.fromRupees(120));
      expect(unknown <= _value(CardSnapshot(product: magnus)), isTrue);
    });

    test('unknown with some spend already added keeps the lower reading', () {
      // The optimizer adds the allocation's consumption on top of fresh.
      final unknown = _value(
        CardSnapshot(
          product: magnus,
          capConsumed: {cap.id: 100000},
          unknownCapIds: {cap.id},
        ),
      );
      final freshPlusSpend = _value(
        CardSnapshot(product: magnus, capConsumed: {cap.id: 100000}),
      );
      expect(unknown <= freshPlusSpend, isTrue);
    });
  });

  group('a card whose post-limit rate is lower', () {
    final card = _bonusCard();

    test('unknown gets the conservative USED-UP value (no capped bonus)', () {
      final fresh = _value(CardSnapshot(product: card));
      final usedUp = _value(
        CardSnapshot(product: card, capConsumed: const {'bonus-cap': 1500}),
      );
      final unknown = _value(
        CardSnapshot(product: card, unknownCapIds: const {'bonus-cap'}),
      );
      // ₹10,000: 500 points fresh (₹125), 100 points used up (₹25).
      expect(fresh, Money.fromRupees(125));
      expect(usedUp, Money.fromRupees(25));
      expect(unknown, usedUp);
    });

    test('a tie keeps the used-up result', () {
      // A cap nothing is attached to changes nothing, so both readings tie.
      final card = _bonusCard(
        caps: [
          CapRule(
            id: 'idle',
            label: 'Idle',
            capValue: Money.fromRupees(375),
            measure: CapMeasure.rewardValue,
            period: CapPeriod.calendarMonth,
            capKind: CapKind.bonusPoints,
            capAmount: 1500,
            targets: const ['some-other-rule'],
          ),
        ],
      );
      final unknown = _value(
        CardSnapshot(product: card, unknownCapIds: const {'idle'}),
      );
      expect(unknown, _value(CardSnapshot(product: card)));
    });
  });

  group('known caps and other cases are unchanged', () {
    final card = _bonusCard();

    test('a known partly-used cap evaluates as before', () {
      final withIds = _value(
        CardSnapshot(
          product: card,
          capConsumed: const {'bonus-cap': 1400},
          unknownCapIds: const {},
        ),
      );
      // 100 points of headroom: base 100 + bonus 100 = 200 points = ₹50.
      expect(withIds, Money.fromRupees(50));
    });

    test('an unknown id that is not a cap on the card is ignored', () {
      expect(
        _value(CardSnapshot(product: card, unknownCapIds: const {'nope'})),
        _value(CardSnapshot(product: card)),
      );
    });

    test('one cap unknown, another known: only the unknown one is evaluated '
        'both ways', () {
      final two = _bonusCard(
        caps: [
          CapRule(
            id: 'a',
            label: 'A',
            capValue: Money.fromRupees(375),
            measure: CapMeasure.rewardValue,
            period: CapPeriod.calendarMonth,
            capKind: CapKind.bonusPoints,
            capAmount: 1500,
            targets: const ['bonus-rule'],
          ),
          CapRule(
            id: 'b',
            label: 'B',
            capValue: Money.fromRupees(100),
            measure: CapMeasure.rewardValue,
            period: CapPeriod.calendarMonth,
            capKind: CapKind.bonusPoints,
            capAmount: 400,
            targets: const ['bonus-rule'],
          ),
        ],
      );
      // B is known, 380 of 400 used: 20 points of bonus headroom at most.
      final value = _value(
        CardSnapshot(
          product: two,
          capConsumed: const {'b': 380},
          unknownCapIds: const {'a'},
        ),
        amount: 10000,
      );
      // A unknown: used up gives base only (100 points = ₹25), which is lower
      // than fresh (100 base + 20 bonus = 120 points = ₹30).
      expect(value, Money.fromRupees(25));
    });

    test('a legacy cap (no cap_kind) that is unknown is evaluated used up '
        'too', () {
      final legacy = CardProduct(
        id: 'legacy',
        name: 'legacy',
        network: CardNetwork.visa,
        pointValueInr: 0.25,
        baseRewardUnit: RewardUnit.pointsPer100,
        baseRewardRate: 1,
        accrualRounding: AccrualRounding.floor,
        rewardRules: const [
          RewardRule(
            id: 'r',
            unit: RewardUnit.pointsPer100,
            rate: 5,
            priority: 10,
          ),
        ],
        capRules: [
          CapRule(
            id: 'legacy-cap',
            rewardRuleId: 'r',
            label: 'Legacy',
            capValue: Money.fromRupees(375),
            measure: CapMeasure.rewardValue,
            period: CapPeriod.calendarMonth,
          ),
        ],
      );
      final unknown = _value(
        CardSnapshot(product: legacy, unknownCapIds: const {'legacy-cap'}),
      );
      final fresh = _value(CardSnapshot(product: legacy));
      expect(unknown < fresh, isTrue);
    });
  });

  group('two or more unknown caps: every fresh/used-up combination (D35c)', () {
    // The reviewer's probe: rule 5 pts/₹100 on a card whose base is 1 pt/₹100
    // and whose points are worth ₹1, a 100-point bonus cap, and a ₹50,000
    // eligible-spend cap that pays 10 pts/₹100 ABOVE its limit.
    //   both fresh                      ₹200 (100 base + 100 bonus)
    //   both used up                    ₹1,000 (all spend above the limit)
    //   bonus used up, tier fresh       ₹100 (base only)  <- lower than both
    //   bonus fresh, tier used up       ₹1,000
    CardProduct probeCard({int extraCaps = 0}) => CardProduct(
      id: 'probe',
      name: 'probe',
      network: CardNetwork.visa,
      pointValueInr: 1,
      baseRewardUnit: RewardUnit.pointsPer100,
      baseRewardRate: 1,
      accrualRounding: AccrualRounding.floor,
      rewardRules: const [
        RewardRule(
          id: 'r',
          unit: RewardUnit.pointsPer100,
          rate: 5,
          priority: 10,
        ),
      ],
      capRules: [
        CapRule(
          id: 'bonus',
          label: 'Bonus points',
          capValue: Money.fromRupees(100),
          measure: CapMeasure.rewardValue,
          period: CapPeriod.calendarMonth,
          capKind: CapKind.bonusPoints,
          capAmount: 100,
          targets: const ['r'],
        ),
        CapRule(
          id: 'tier',
          label: 'Spend tier',
          capValue: Money.fromRupees(50000),
          measure: CapMeasure.spendAmount,
          period: CapPeriod.calendarMonth,
          capKind: CapKind.eligibleSpend,
          capAmount: 50000,
          postCapBehavior: PostCapBehavior.customRate,
          postCapUnit: RewardUnit.pointsPer100,
          postCapRate: 10,
          targets: const ['r'],
        ),
        // Extra idle unknown caps, to push k past the enumeration limit.
        for (var i = 0; i < extraCaps; i++)
          CapRule(
            id: 'idle$i',
            label: 'Idle $i',
            capValue: Money.fromRupees(1000),
            measure: CapMeasure.rewardValue,
            period: CapPeriod.calendarMonth,
            capKind: CapKind.bonusPoints,
            capAmount: 1000,
            targets: const ['other-rule'],
          ),
      ],
    );

    Money value(CardSnapshot s) => _value(s);

    test('the four extremes are as the probe says', () {
      final card = probeCard();
      Money at(Map<String, double> consumed) =>
          value(CardSnapshot(product: card, capConsumed: consumed));
      expect(at(const {}), Money.fromRupees(200));
      expect(at(const {'bonus': 100, 'tier': 50000}), Money.fromRupees(1000));
      expect(at(const {'bonus': 100}), Money.fromRupees(100));
      expect(at(const {'tier': 50000}), Money.fromRupees(1000));
    });

    test('unknown caps take the minimum over all four combinations: ₹100, '
        'not the ₹200 of "both fresh"', () {
      final unknown = value(
        CardSnapshot(
          product: probeCard(),
          unknownCapIds: const {'bonus', 'tier'},
        ),
      );
      expect(unknown, Money.fromRupees(100));
    });

    test('one unknown cap, one known: the known one stays as it is', () {
      // tier known fresh (0 used), bonus unknown: bonus used up = ₹100,
      // bonus fresh = ₹200.
      final unknown = value(
        CardSnapshot(
          product: probeCard(),
          capConsumed: const {'tier': 0},
          unknownCapIds: const {'bonus'},
        ),
      );
      expect(unknown, Money.fromRupees(100));
      // tier known used up: bonus is irrelevant (all spend is above the
      // limit): ₹1,000 either way.
      final tierUsed = value(
        CardSnapshot(
          product: probeCard(),
          capConsumed: const {'tier': 50000},
          unknownCapIds: const {'bonus'},
        ),
      );
      expect(tierUsed, Money.fromRupees(1000));
    });

    test('many unknown caps (past the limit) still find the mixed minimum '
        'through single-cap flips', () {
      // 2 real unknown caps + 8 idle ones = 10 unknown (1,024 combinations,
      // beyond the enumeration limit): the extremes plus each single flip
      // still reach "bonus used up, tier fresh".
      final card = probeCard(extraCaps: 8);
      final unknown = value(
        CardSnapshot(
          product: card,
          unknownCapIds: {
            'bonus',
            'tier',
            for (var i = 0; i < 8; i++) 'idle$i',
          },
        ),
      );
      expect(unknown, Money.fromRupees(100));
    });

    test('the result is never above fresh or above used up', () {
      final card = probeCard();
      final unknown = value(
        CardSnapshot(product: card, unknownCapIds: const {'bonus', 'tier'}),
      );
      expect(unknown <= value(CardSnapshot(product: card)), isTrue);
      expect(
        unknown <=
            value(
              CardSnapshot(
                product: card,
                capConsumed: const {'bonus': 100, 'tier': 50000},
              ),
            ),
        isTrue,
      );
    });
  });

  group('the split optimizer carries unknown caps through', () {
    final magnus = CardProductJson.fromJson(_fixture('axis-bank-magnus'));
    final cap = magnus.capRules.firstWhere(
      (c) => c.id.endsWith('base_150k_spend'),
    );
    final flat = CardProduct(
      id: 'flat',
      name: 'flat',
      network: CardNetwork.visa,
      isUpiLinkable: true,
      baseRewardUnit: RewardUnit.cashbackPercent,
      baseRewardRate: 2, // ₹200 on ₹10,000: between Magnus's ₹120 and ₹350
      accrualRounding: AccrualRounding.floor,
      cashbackRounding: CashbackRounding.paise,
    );
    final total = Money.fromRupees(10000);
    Money allocated(List<SplitAllocation> plan, String id) =>
        plan
            .where((a) => a.card.id == id)
            .map((a) => a.amount)
            .fold(const Money.zero(), (a, b) => a + b);

    List<SplitAllocation> plan(CardSnapshot magnusSnapshot) =>
        const SplitOptimizer().optimize(
          total,
          RecommendationContext(amount: total, rail: TxnRail.swipe),
          [magnusSnapshot, CardSnapshot(product: flat)],
        );

    test('an unknown Magnus cap does not out-bid a flat 2%: it is valued at '
        'its fresh ₹120, not its used-up ₹350', () {
      final result = plan(
        CardSnapshot(product: magnus, unknownCapIds: {cap.id}),
      );
      expect(allocated(result, 'flat'), total);
      expect(allocated(result, magnus.id), const Money.zero());
    });

    test('a KNOWN used-up Magnus cap really is worth ₹350 and takes the '
        'spend', () {
      final result = plan(
        CardSnapshot(product: magnus, capConsumed: {cap.id: cap.capAmount!}),
      );
      expect(allocated(result, magnus.id), isNot(const Money.zero()));
    });

    test('the rebuild in the optimizer passes unknownCapIds on', () {
      final source = File(
        'lib/src/engine/calculators.dart',
      ).readAsStringSync();
      expect(source, contains('unknownCapIds: snapshot.unknownCapIds'));
    });
  });
}
