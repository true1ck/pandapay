import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// A card shaped like the live v2 catalogue's Swiggy HDFC card: priority-0
/// exclusion rows with NO category (a "no rewards under ₹100" row and an EMI
/// row) sit in front of the real earning rules. The first version of
/// [baseRatePerRupee] took the lowest-priority rule with no category, which on
/// this shape is an exclusion paying 0, so every real card read as 0%.
CardProduct v2Card() => CardProduct(
  id: 'v2',
  name: 'V2 Card',
  network: CardNetwork.visa,
  baseRewardUnit: RewardUnit.cashbackPercent,
  baseRewardRate: 1,
  rewardRules: [
    RewardRule(
      id: 'x-under-100',
      unit: RewardUnit.cashbackPercent,
      rate: 0,
      priority: 0,
      role: RuleRole.exclusion,
      maxTxn: Money.fromRupees(100),
      minEngineVersion: 2,
    ),
    const RewardRule(
      id: 'x-emi',
      unit: RewardUnit.cashbackPercent,
      rate: 0,
      priority: 0,
      role: RuleRole.exclusion,
      rail: TxnRail.emi,
      minEngineVersion: 2,
    ),
    RewardRule(
      id: 'e-swiggy',
      unit: RewardUnit.cashbackPercent,
      rate: 10,
      priority: 1,
      role: RuleRole.earn,
      merchantSlugs: const ['swiggy'],
      minTxn: Money.fromRupees(249),
    ),
    const RewardRule(
      id: 'i-online',
      categoryId: 'online',
      unit: RewardUnit.cashbackPercent,
      rate: 5,
      priority: 2,
      role: RuleRole.info,
      rail: TxnRail.online,
      minEngineVersion: 2,
    ),
    RewardRule(
      id: 'b-base',
      unit: RewardUnit.cashbackPercent,
      rate: 1,
      priority: 3,
      role: RuleRole.earn,
      minTxn: Money.fromRupees(100),
    ),
    const RewardRule(
      id: 'x-rent',
      categoryId: 'rent',
      unit: RewardUnit.cashbackPercent,
      rate: 0,
      priority: 11,
      role: RuleRole.exclusion,
      minEngineVersion: 2,
    ),
  ],
);

void main() {
  final diningCard = CardProduct(
    id: 'dining',
    name: 'Dining Card',
    network: CardNetwork.rupay,
    pointValueInr: 1,
    rewardRules: const [
      RewardRule(
        id: 'r1',
        categoryId: 'dining',
        unit: RewardUnit.cashbackPercent,
        rate: 5,
      ),
      RewardRule(
        id: 'r2',
        unit: RewardUnit.cashbackPercent,
        rate: 1,
        priority: 200,
      ), // base rate
    ],
  );

  group('baseRatePerRupee', () {
    test('a category rule beats the all-other-spends rule, which covers the rest', () {
      expect(baseRatePerRupee(product: diningCard, categoryId: 'dining'), 0.05);
      expect(baseRatePerRupee(product: diningCard, categoryId: 'travel'), 0.01);
      expect(baseRatePerRupee(product: diningCard), 0.01);
      expect(
        baseRateValueFor(
          product: diningCard,
          amount: Money.fromRupees(1000),
          categoryId: 'dining',
        ),
        Money.fromRupees(50),
      );
    });

    test('exclusion rows with no category are not the card\'s base rate (the v2 catalogue shape)', () {
      final card = v2Card();
      // 1%, not the 0% of the priority-0 exclusion rows.
      expect(baseRatePerRupee(product: card, categoryId: 'dining'), 0.01);
      expect(baseRatePerRupee(product: card), 0.01);
      expect(
        baseRateValueFor(product: card, amount: Money.fromRupees(2000)),
        Money.fromRupees(20),
      );
    });

    test('a merchant-only rule is not what the card pays in general', () {
      // The 10% Swiggy row has no category and a lower priority number than the
      // 1% base rule; it must not become the card's everyday rate.
      expect(baseRatePerRupee(product: v2Card(), categoryId: 'dining'), 0.01);
    });

    test('info rows are never picked, even at the best priority', () {
      final card = CardProduct(
        id: 'info-first',
        name: 'Info First',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 2,
        rewardRules: const [
          RewardRule(
            id: 'i',
            unit: RewardUnit.cashbackPercent,
            rate: 9,
            priority: 0,
            role: RuleRole.info,
            minEngineVersion: 2,
          ),
        ],
      );
      // Only an info row: the card's own stated base rate answers.
      expect(baseRatePerRupee(product: card), 0.02);
    });

    test('a category the card leaves out of rewards pays nothing', () {
      expect(baseRatePerRupee(product: v2Card(), categoryId: 'rent'), 0);
      final card = CardProduct(
        id: 'excl',
        name: 'Excludes Fuel',
        network: CardNetwork.visa,
        baseRewardUnit: RewardUnit.cashbackPercent,
        baseRewardRate: 1,
        excludedCategoryIds: const ['fuel'],
      );
      expect(baseRatePerRupee(product: card, categoryId: 'fuel'), 0);
      expect(baseRatePerRupee(product: card, categoryId: 'dining'), 0.01);
    });

    test('a card with no rule and no stated base rate contributes zero, never throws', () {
      final noRules = CardProduct(
        id: 'norules',
        name: 'No Rules',
        network: CardNetwork.mastercard,
      );
      expect(baseRatePerRupee(product: noRules, categoryId: 'dining'), 0);
      expect(
        baseRateValueFor(
          product: noRules,
          amount: Money.fromRupees(1000),
          categoryId: 'dining',
        ),
        const Money.zero(),
      );
    });

    test('flat_points rules never count as comparable value', () {
      final flatPoints = CardProduct(
        id: 'flatpoints',
        name: 'Flat Points',
        network: CardNetwork.rupay,
        rewardRules: const [
          RewardRule(
            id: 'r4',
            unit: RewardUnit.flatPoints,
            rate: 500,
            priority: 200,
          ),
        ],
      );
      expect(baseRatePerRupee(product: flatPoints, categoryId: 'dining'), 0);
    });

    test('values are never negative or larger than the spend', () {
      final malformed = CardProduct(
        id: 'malformed',
        name: 'Malformed rate card',
        network: CardNetwork.visa,
        rewardRules: const [
          RewardRule(
            id: 'r-malformed',
            unit: RewardUnit.cashbackPercent,
            rate: 500,
          ),
        ],
      );
      expect(
        baseRateValueFor(product: malformed, amount: Money.fromRupees(100)),
        Money.fromRupees(100),
      );
      expect(
        baseRateValueFor(product: malformed, amount: Money.fromRupees(-100)),
        const Money.zero(),
      );
      final negative = CardProduct(
        id: 'neg',
        name: 'Negative',
        network: CardNetwork.visa,
        rewardRules: const [
          RewardRule(id: 'n', unit: RewardUnit.cashbackPercent, rate: -3),
        ],
      );
      expect(baseRatePerRupee(product: negative), 0);
    });
  });
}
