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
}
