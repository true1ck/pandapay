import 'dart:io';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C8/D30a: on a v2-shaped card the split optimizer carries the card's
/// NATIVE cap consumption (`capConsumed`) through every marginal step and
/// adds the native delta of what it has already allocated. It must never
/// reduce `capRemaining` (the v1 measure) on a v2 card, and must never forget
/// what the card had used: before the fix, from the second allocation step the
/// engine saw a fresh cap (plus a v1 ₹ figure read as points) and the plan
/// piled spend onto a card whose bonus was used up.
///
/// Card "bonus": 5 pts/₹100 on everything with a 1,500-point monthly bonus
/// cap, base 1 pt/₹100, ₹0.25 a point. A ₹500 step earns 25 points (5 base +
/// 20 bonus), so 20 points of headroom is exactly one step.
CardProduct _bonusCard(
  String id, {
  double baseRate = 1,
  List<CapRule>? caps,
  List<RewardRule>? rules,
}) => CardProduct(
  id: id,
  name: id,
  network: CardNetwork.visa,
  isUpiLinkable: true,
  pointValueInr: 0.25,
  baseRewardUnit: RewardUnit.pointsPer100,
  baseRewardRate: baseRate,
  accrualRounding: AccrualRounding.floor,
  rewardRules:
      rules ??
      [
        RewardRule(
          id: '$id-rule',
          unit: RewardUnit.pointsPer100,
          rate: 5,
          priority: 10,
        ),
      ],
  capRules:
      caps ??
      [
        CapRule(
          id: '$id-cap',
          label: 'Bonus cap',
          // The v1 fields of a v2 cap: a ₹ reward value, never to be read as
          // points.
          capValue: Money.fromRupees(375),
          measure: CapMeasure.rewardValue,
          period: CapPeriod.calendarMonth,
          capKind: CapKind.bonusPoints,
          capAmount: 1500,
          targets: ['$id-rule'],
        ),
      ],
);

/// A flat 2 pts/₹100 card with no bonus rule.
CardProduct _flatCard(String id, {double rate = 2}) => CardProduct(
  id: id,
  name: id,
  network: CardNetwork.visa,
  isUpiLinkable: true,
  pointValueInr: 0.25,
  baseRewardUnit: RewardUnit.pointsPer100,
  baseRewardRate: rate,
  accrualRounding: AccrualRounding.floor,
);

RecommendationContext _ctx(Money total) =>
    RecommendationContext(amount: total, rail: TxnRail.swipe);

Money _allocated(List<SplitAllocation> result, String id) {
  for (final a in result) {
    if (a.card.id == id) return a.amount;
  }
  return const Money.zero();
}

void main() {
  const optimizer = SplitOptimizer();
  final total = Money.fromRupees(10000);

  group('v2 card, bonus cap partly used', () {
    test('takes only the headroom it has, then the plan moves on', () {
      final result = optimizer.optimize(
        total,
        _ctx(total),
        [
          // 1,480 of 1,500 used: 20 points of bonus left = one ₹500 step.
          CardSnapshot(
            product: _bonusCard('bonus'),
            capConsumed: const {'bonus-cap': 1480},
          ),
          CardSnapshot(product: _flatCard('flat')),
        ],
      );
      expect(_allocated(result, 'bonus'), Money.fromRupees(500));
      expect(_allocated(result, 'flat'), Money.fromRupees(9500));
    });

    test('plenty of headroom: the bonus card keeps the spend it can earn on',
        () {
      // The whole ₹10,000 earns 400 bonus points on it, well inside the
      // 1,500-point cap, so it keeps every step.
      final result = optimizer.optimize(
        total,
        _ctx(total),
        [
          CardSnapshot(
            product: _bonusCard('bonus'),
            capConsumed: const {'bonus-cap': 0},
          ),
          CardSnapshot(product: _flatCard('flat')),
        ],
      );
      expect(_allocated(result, 'bonus'), total);
    });

    test('headroom runs out part-way: the split follows the native cap', () {
      // 1,400 used: 100 points left = five ₹500 steps (20 bonus each).
      final result = optimizer.optimize(
        total,
        _ctx(total),
        [
          CardSnapshot(
            product: _bonusCard('bonus'),
            capConsumed: const {'bonus-cap': 1400},
          ),
          CardSnapshot(product: _flatCard('flat')),
        ],
      );
      expect(_allocated(result, 'bonus'), Money.fromRupees(2500));
      expect(_allocated(result, 'flat'), Money.fromRupees(7500));
    });

    test('the v1 measure on the snapshot is ignored: capRemaining never '
        'reduced on a v2 card', () {
      // A caller that (wrongly) also passes the v1 measure must not change
      // the plan: only native consumption counts once capConsumed is given.
      final result = optimizer.optimize(
        total,
        _ctx(total),
        [
          CardSnapshot(
            product: _bonusCard('bonus'),
            capConsumed: const {'bonus-cap': 1480},
            capRemaining: {'bonus-cap': Money.fromRupees(375)},
          ),
          CardSnapshot(product: _flatCard('flat')),
        ],
      );
      expect(_allocated(result, 'bonus'), Money.fromRupees(500));
    });
  });

  group('v2 card, bonus cap used up or unknown', () {
    // The competitor "partial" wins the first step on its own bonus, then
    // drops to base (1 pt/₹100). "late" has the used-up / unknown cap and a
    // 1.5 pts/₹100 base, so it takes over from there, and only at its BASE
    // value: its bonus is not available.
    test('a used-up card takes the spend only at its base value', () {
      final result = optimizer.optimize(
        total,
        _ctx(total),
        [
          CardSnapshot(
            product: _bonusCard('partial'),
            capConsumed: const {'partial-cap': 1480},
          ),
          CardSnapshot(
            product: _bonusCard('late', baseRate: 1.5),
            capConsumed: const {'late-cap': 1500},
          ),
        ],
      );
      expect(_allocated(result, 'partial'), Money.fromRupees(500));
      expect(_allocated(result, 'late'), Money.fromRupees(9500));
      // 95 blocks x 1.5 pts = 142.5 pts at ₹0.25: the base only, no bonus.
      final lateValue = result
          .firstWhere((a) => a.card.id == 'late')
          .expectedValue;
      expect(lateValue.rupees, closeTo(35.63, 0.011));
    });

    test('a used-up card never beats a better base', () {
      final result = optimizer.optimize(
        total,
        _ctx(total),
        [
          CardSnapshot(
            product: _bonusCard('bonus'),
            capConsumed: const {'bonus-cap': 1500},
          ),
          CardSnapshot(product: _flatCard('flat')),
        ],
      );
      expect(result.map((a) => a.card.id), ['flat']);
    });

    test('an unknown cap (fed as consumed = cap amount) never beats a better '
        'base', () {
      // What the app feeds for a null consumed_native.
      final result = optimizer.optimize(
        total,
        _ctx(total),
        [
          CardSnapshot(
            product: _bonusCard('unknown'),
            capConsumed: const {'unknown-cap': 1500},
          ),
          CardSnapshot(product: _flatCard('flat')),
        ],
      );
      expect(result.map((a) => a.card.id), ['flat']);
    });
  });

  group('v2 card, transaction-count cap', () {
    test('a split is one eventual charge: marginal steps do not count it '
        'repeatedly', () {
      final bonus = _bonusCard(
        'bonus',
        caps: [
          CapRule(
            id: 'count-cap',
            label: 'One use',
            capValue: const Money.fromPaise(100),
            measure: CapMeasure.txnCount,
            period: CapPeriod.calendarMonth,
            capKind: CapKind.txnCount,
            capAmount: 1,
            targets: const ['bonus-rule'],
          ),
        ],
      );
      final result = optimizer.optimize(
        total,
        _ctx(total),
        [CardSnapshot(product: bonus), CardSnapshot(product: _flatCard('flat'))],
      );
      expect(_allocated(result, 'bonus'), total);
    });
  });

  group('v1 card: unchanged', () {
    test('a reward-value cap is still reduced in reward units via '
        'capRemaining (₹100 of headroom at 10% covers ₹1,000 of spend)', () {
      final v1 = CardProduct(
        id: 'v1',
        name: 'v1',
        network: CardNetwork.visa,
        isUpiLinkable: true,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1,
        rewardRules: const [
          RewardRule(id: 'v1-rule', unit: RewardUnit.cashbackPercent, rate: 10),
        ],
        capRules: [
          CapRule(
            id: 'v1-cap',
            rewardRuleId: 'v1-rule',
            label: 'cap',
            capValue: Money.fromRupees(100),
            measure: CapMeasure.rewardValue,
            period: CapPeriod.calendarMonth,
            postCapUnit: RewardUnit.cashbackPercent,
            postCapRate: 1,
          ),
        ],
      );
      expect(v1.isV2Shaped, isFalse);
      final v1Total = Money.fromRupees(2000);
      final result = optimizer.optimize(
        v1Total,
        _ctx(v1Total),
        [
          CardSnapshot(
            product: v1,
            capRemaining: {'v1-cap': Money.fromRupees(100)},
          ),
          CardSnapshot(
            product: CardProduct(
              id: 'low',
              name: 'low',
              network: CardNetwork.rupay,
              isUpiLinkable: true,
              rewardRules: const [
                RewardRule(
                  id: 'low-rule',
                  unit: RewardUnit.cashbackPercent,
                  rate: 2,
                ),
              ],
            ),
          ),
        ],
      );
      final high = result.firstWhere((a) => a.card.id == 'v1');
      expect(high.amount.rupees, closeTo(1000, 100));
      expect(high.expectedValue, Money.fromRupees(100));
    });
  });

  group('source guard (D30a): no snapshot rebuild forgets native caps', () {
    String read(String path) => File(path).readAsStringSync();

    test('only the engine, the acquisition engine and the optimizer build a '
        'CardSnapshot', () {
      final builders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (RegExp(r'\bCardSnapshot\(').hasMatch(read(entity.path))) {
          builders.add(entity.path.split('/').last);
        }
      }
      builders.sort();
      expect(builders, [
        'acquisition_engine.dart',
        'calculators.dart',
        'engine.dart',
      ]);
    });

    test('the optimizer\'s v2 rebuild carries capConsumed, and its v1 rebuild '
        'is only reachable for non-v2 cards', () {
      final source = read('lib/src/engine/calculators.dart');
      final rebuilds = RegExp(r'\bCardSnapshot\(').allMatches(source).toList();
      expect(rebuilds, hasLength(2));
      final v2Guard = source.indexOf('if (snapshot.product.isV2Shaped)');
      expect(v2Guard, greaterThan(0));
      // The v1 rebuild (no capConsumed) comes after the v2 early return.
      expect(rebuilds.first.start, greaterThan(v2Guard));
      final first = source.substring(rebuilds.first.start);
      expect(first.substring(0, first.indexOf(');')), isNot(contains('capConsumed')));
      // The v2 rebuild passes capConsumed.
      final second = source.substring(rebuilds.last.start);
      expect(second.substring(0, second.indexOf(');')), contains('capConsumed: next'));
    });
  });
}
