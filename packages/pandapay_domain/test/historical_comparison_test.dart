import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

void main() {
  final diningCard = CardProduct(
    id: 'dining',
    name: 'Dining Card',
    network: CardNetwork.rupay,
    pointValueInr: 1,
    rewardRules: const [
      RewardRule(id: 'r1', categoryId: 'dining', unit: RewardUnit.cashbackPercent, rate: 5),
      RewardRule(id: 'r2', unit: RewardUnit.cashbackPercent, rate: 1, priority: 200), // base rate
    ],
  );
  final flatCard = CardProduct(
    id: 'flat',
    name: 'Flat Card',
    network: CardNetwork.visa,
    pointValueInr: 1,
    rewardRules: const [
      RewardRule(id: 'r3', unit: RewardUnit.cashbackPercent, rate: 2, priority: 200),
    ],
  );

  test('the card actually used, if it was the best of the owned set, reports no better option', () {
    final result = compareToOwnedCards(
      usedCard: diningCard,
      ownedCards: [diningCard, flatCard],
      amount: Money.fromRupees(1000),
      categoryId: 'dining',
    );

    expect(result.hadBetterOption, isFalse);
    expect(result.actualValue, Money.fromRupees(50)); // 5% of 1000
    expect(result.missedValue, const Money.zero());
  });

  test('a different owned card with a higher category rate is flagged as the better option', () {
    // Same dining spend, but this time flatCard was used instead of diningCard.
    final result = compareToOwnedCards(
      usedCard: flatCard,
      ownedCards: [diningCard, flatCard],
      amount: Money.fromRupees(1000),
      categoryId: 'dining',
    );

    expect(result.hadBetterOption, isTrue);
    expect(result.betterCard?.id, 'dining');
    expect(result.actualValue, Money.fromRupees(20)); // flatCard's base 2%
    expect(result.betterValue, Money.fromRupees(50)); // diningCard's 5%
    expect(result.missedValue, Money.fromRupees(30));
  });

  test('a card with no matching reward rule at all contributes zero, never throws', () {
    final noRulesCard = CardProduct(id: 'norules', name: 'No Rules', network: CardNetwork.mastercard);
    final result = compareToOwnedCards(
      usedCard: noRulesCard,
      ownedCards: [noRulesCard, diningCard],
      amount: Money.fromRupees(1000),
      categoryId: 'dining',
    );

    expect(result.actualValue, const Money.zero());
    expect(result.hadBetterOption, isTrue);
    expect(result.betterCard?.id, 'dining');
  });

  test('flat_points rules never count as comparable value, on either side', () {
    final flatPointsCard = CardProduct(
      id: 'flatpoints',
      name: 'Flat Points',
      network: CardNetwork.rupay,
      rewardRules: const [RewardRule(id: 'r4', unit: RewardUnit.flatPoints, rate: 500, priority: 200)],
    );
    final result = compareToOwnedCards(
      usedCard: flatPointsCard,
      ownedCards: [flatPointsCard],
      amount: Money.fromRupees(1000),
      categoryId: 'dining',
    );

    expect(result.actualValue, const Money.zero());
    expect(result.hadBetterOption, isFalse);
  });

  test('a single-card wallet never reports a better option (nothing else to compare against)', () {
    final result = compareToOwnedCards(
      usedCard: diningCard,
      ownedCards: [diningCard],
      amount: Money.fromRupees(1000),
      categoryId: 'dining',
    );
    expect(result.hadBetterOption, isFalse);
  });

  test('comparison values are never negative or larger than the spend', () {
    final malformed = CardProduct(
      id: 'malformed',
      name: 'Malformed rate card',
      network: CardNetwork.visa,
      rewardRules: const [
        RewardRule(id: 'r-malformed', unit: RewardUnit.cashbackPercent, rate: 500),
      ],
    );

    final result = compareToOwnedCards(
      usedCard: malformed,
      ownedCards: [malformed],
      amount: Money.fromRupees(100),
    );
    expect(result.actualValue, Money.fromRupees(100));
    expect(result.missedValue, const Money.zero());

    final negative = compareToOwnedCards(
      usedCard: malformed,
      ownedCards: [malformed],
      amount: Money.fromRupees(-100),
    );
    expect(negative.actualValue, const Money.zero());
    expect(negative.missedValue, const Money.zero());
  });

  test('BaseRateTable prices every spend exactly like baseRateValueFor', () {
    final points = CardProduct(
      id: 'points',
      name: 'Points Card',
      network: CardNetwork.visa,
      pointValueInr: 0.25,
      rewardRules: const [
        RewardRule(id: 'p1', categoryId: 'travel', unit: RewardUnit.pointsPer150, rate: 10),
        RewardRule(id: 'p2', categoryId: 'fuel', unit: RewardUnit.flatPoints, rate: 500),
        RewardRule(id: 'p3', unit: RewardUnit.pointsPer100, rate: 2, priority: 200),
      ],
    );
    // A catalogue mistake: more than 100% back, and a negative rate.
    final broken = CardProduct(
      id: 'broken',
      name: 'Broken Card',
      network: CardNetwork.visa,
      pointValueInr: 1,
      rewardRules: const [
        RewardRule(id: 'b1', categoryId: 'dining', unit: RewardUnit.cashbackPercent, rate: 250),
        RewardRule(id: 'b2', unit: RewardUnit.cashbackPercent, rate: -3, priority: 200),
      ],
    );
    final empty = CardProduct(id: 'none', name: 'No Rules', network: CardNetwork.visa);
    final table = BaseRateTable();
    for (final product in [diningCard, flatCard, points, broken, empty]) {
      for (final category in [null, 'dining', 'travel', 'fuel', 'other']) {
        for (final paise in [0, -500, 1, 99, 12345, 100000, 7654321]) {
          final amount = Money.fromPaise(paise);
          expect(
            table.valueFor(product: product, amount: amount, categoryId: category),
            baseRateValueFor(product: product, amount: amount, categoryId: category),
            reason: '${product.id} / $category / $paise',
          );
        }
      }
    }
  });

  test('compareToOwnedCards gives the same answer with or without a rate table', () {
    final table = BaseRateTable();
    for (final used in [diningCard, flatCard]) {
      for (final category in [null, 'dining', 'travel']) {
        final plain = compareToOwnedCards(
          usedCard: used,
          ownedCards: [diningCard, flatCard],
          amount: Money.fromRupees(1234.5),
          categoryId: category,
        );
        final cached = compareToOwnedCards(
          usedCard: used,
          ownedCards: [diningCard, flatCard],
          amount: Money.fromRupees(1234.5),
          categoryId: category,
          rates: table,
        );
        expect(cached.actualValue, plain.actualValue);
        expect(cached.betterCard?.id, plain.betterCard?.id);
        expect(cached.missedValue, plain.missedValue);
      }
    }
  });
}
