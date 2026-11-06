import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

/// Plan C8/D32 review M2: the acquisition recommender projects each card with
/// its milestones removed. That copy dropped the v2 card fields, so a card
/// with `cashback_rounding = rupee_floor` was projected with paise rounding
/// (and a card whose only v2 marker was `cashback_rounding` fell back to the
/// v1 path).
CardProduct _cashbackCard(String id, {CashbackRounding? rounding}) =>
    CardProduct(
      id: id,
      name: id,
      network: CardNetwork.rupay,
      isUpiLinkable: true,
      baseRewardUnit: RewardUnit.cashbackPercent,
      baseRewardRate: 5,
      cashbackRounding: rounding,
    );

Money _projected(CardProduct candidate) {
  const recommender = CardAcquisitionRecommender();
  final owned = CardProduct(
    id: 'owned',
    name: 'owned',
    network: CardNetwork.rupay,
    isUpiLinkable: true,
    baseRewardUnit: RewardUnit.cashbackPercent,
    baseRewardRate: 1,
  );
  // ₹1,010 a year at 5% is ₹50.50.
  final results = recommender.rank(
    candidates: [candidate],
    ownedCards: [owned],
    spendProfile: SpendProfile(
      annualSpendByCategory: {null: Money.fromRupees(1010)},
    ),
  );
  return results.single.projectedAnnualValue;
}

void main() {
  test('a card with no v2 field projects as before (paise)', () {
    expect(_projected(_cashbackCard('c')), Money.fromRupees(50.5));
  });

  test('rupee_floor is kept: ₹50.50 projects as ₹50', () {
    expect(
      _projected(_cashbackCard('c', rounding: CashbackRounding.rupeeFloor)),
      Money.fromRupees(50),
    );
  });

  test('rupee_half_up is kept: ₹50.50 projects as ₹51', () {
    expect(
      _projected(_cashbackCard('c', rounding: CashbackRounding.rupeeHalfUp)),
      Money.fromRupees(51),
    );
  });

  test('an explicit paise rounding projects to the paisa', () {
    expect(
      _projected(_cashbackCard('c', rounding: CashbackRounding.paise)),
      Money.fromRupees(50.5),
    );
  });
}
