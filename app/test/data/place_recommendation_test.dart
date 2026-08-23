import 'package:test/test.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/place_recommendation.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id, {required double rate, String? categoryId}) {
  return CardProduct(
    id: id,
    name: id,
    network: CardNetwork.visa,
    isUpiLinkable: true,
    rewardRules: [
      RewardRule(
        id: '$id-rule',
        unit: RewardUnit.cashbackPercent,
        rate: rate,
        categoryId: categoryId,
      ),
    ],
  );
}

UserCard _owned(String id) => UserCard(
  id: 'uc-$id',
  cardProductId: id,
  cardName: id,
  isDefault: false,
);

void main() {
  test('picks different best cards for different place categories from the same wallet', () {
    final catalogue = [
      _card('general-card', rate: 12),
      _card('fuel-card', rate: 18, categoryId: 'fuel'),
      _card('dining-card', rate: 20, categoryId: 'dining'),
      _card('entertainment-card', rate: 15, categoryId: 'entertainment'),
    ];
    final wallet = catalogue.map((card) => _owned(card.id)).toList();

    final dining = bestCardForCategory(
      engine: const RecommendationEngine(),
      catalogue: catalogue,
      wallet: wallet,
      overrides: const [],
      categoryId: 'dining',
    );
    final fuel = bestCardForCategory(
      engine: const RecommendationEngine(),
      catalogue: catalogue,
      wallet: wallet,
      overrides: const [],
      categoryId: 'fuel',
    );
    final entertainment = bestCardForCategory(
      engine: const RecommendationEngine(),
      catalogue: catalogue,
      wallet: wallet,
      overrides: const [],
      categoryId: 'entertainment',
    );
    final overall = bestCardForCategory(
      engine: const RecommendationEngine(),
      catalogue: catalogue,
      wallet: wallet,
      overrides: const [],
      categoryId: null,
    );

    expect(dining?.card.id, 'dining-card');
    expect(dining?.expectedValue, Money.fromRupees(200));

    expect(fuel?.card.id, 'fuel-card');
    expect(fuel?.expectedValue, Money.fromRupees(180));

    expect(entertainment?.card.id, 'entertainment-card');
    expect(entertainment?.expectedValue, Money.fromRupees(150));

    expect(overall?.card.id, 'dining-card');
  });

  test('category overrides still force the owned card that matches the active place', () {
    final catalogue = [
      _card('fuel-card', rate: 8, categoryId: 'fuel'),
      _card('dining-card', rate: 20, categoryId: 'dining'),
    ];
    final wallet = catalogue.map((card) => _owned(card.id)).toList();
    final overrides = [
      CardOverride(
        id: 'override-1',
        userCardId: 'uc-fuel-card',
        scope: OverrideScope.category,
        categoryId: 'fuel',
        isEnabled: true,
        createdAt: DateTime(2026, 8, 20),
        cardName: 'fuel-card',
      ),
    ];

    final result = bestCardForCategory(
      engine: const RecommendationEngine(),
      catalogue: catalogue,
      wallet: wallet,
      overrides: overrides,
      categoryId: 'fuel',
    );

    expect(result?.card.id, 'fuel-card');
    expect(result?.isOverride, isTrue);
  });

  test('merchant-name overrides win over the broader category when both match the same place', () {
    final catalogue = [
      _card('fuel-card', rate: 8, categoryId: 'fuel'),
      _card('dining-card', rate: 20, categoryId: 'dining'),
    ];
    final wallet = catalogue.map((card) => _owned(card.id)).toList();
    final overrides = [
      CardOverride(
        id: 'override-merchant',
        userCardId: 'uc-dining-card',
        scope: OverrideScope.merchantName,
        merchantName: "Domino's",
        isEnabled: true,
        createdAt: DateTime(2026, 8, 20),
        cardName: 'dining-card',
      ),
      CardOverride(
        id: 'override-category',
        userCardId: 'uc-fuel-card',
        scope: OverrideScope.category,
        categoryId: 'dining',
        isEnabled: true,
        createdAt: DateTime(2026, 8, 20),
        cardName: 'fuel-card',
      ),
    ];

    final result = bestCardForPlace(
      engine: const RecommendationEngine(),
      catalogue: catalogue,
      wallet: wallet,
      overrides: overrides,
      categoryId: 'dining',
      merchantName: "Domino's",
    );

    expect(result?.card.id, 'dining-card');
    expect(result?.isOverride, isTrue);
  });

  test('an empty wallet still falls back to the full catalogue and returns the best match', () {
    final catalogue = [
      _card('fuel-card', rate: 8, categoryId: 'fuel'),
      _card('dining-card', rate: 20, categoryId: 'dining'),
    ];

    final result = bestCardForPlace(
      engine: const RecommendationEngine(),
      catalogue: catalogue,
      wallet: const [],
      overrides: const [],
      categoryId: 'dining',
      merchantName: 'Some Restaurant',
    );

    expect(result?.card.id, 'dining-card');
    expect(result?.expectedValue, Money.fromRupees(200));
  });
}
