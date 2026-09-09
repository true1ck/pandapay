import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _MockCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  const _MockCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _MockCategoryRepository implements CategoryRepository {
  final List<SpendCategory> categories;
  const _MockCategoryRepository(this.categories);
  @override
  Future<List<SpendCategory>> fetchCategories() async => categories;
}

void main() {
  testWidgets('signed-in user selecting Fuel category displays fuel surcharge waiver amount not 0', (tester) async {
    const fuelCatId = 'uuid-fuel-category';
    final categories = [
      const SpendCategory(id: fuelCatId, slug: 'fuel', name: 'Fuel'),
      const SpendCategory(id: 'uuid-dining-category', slug: 'dining', name: 'Dining'),
    ];

    final moneybackCard = CardProduct(
      id: 'hdfc-moneyback',
      name: 'MoneyBack+ Credit Card',
      network: CardNetwork.visa,
      pointValueInr: 0.25,
      excludedCategoryIds: const [fuelCatId],
      fuelRule: const FuelSurchargeRule(
        surchargePercent: 1.0,
        waiverPercent: 1.0,
        minTxn: Money.fromPaise(40000),
        maxTxn: Money.fromPaise(500000),
      ),
      rewardRules: const [
        RewardRule(
          id: 'dining-rule',
          categoryId: 'uuid-dining-category',
          unit: RewardUnit.cashbackPercent,
          rate: 2.0,
        ),
      ],
    );

    final ownedCard = const UserCard(
      id: 'user-card-1',
      cardProductId: 'hdfc-moneyback',
      cardName: 'MoneyBack+ Credit Card',
      isDefault: true,
    );

    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'mock-token'),
        sessionInitProvider.overrideWith((ref) async {}),
        cardOverridesProvider.overrideWith((ref) async => const []),
        catalogueRepositoryProvider.overrideWithValue(_MockCatalogueRepository([moneybackCard])),
        categoryRepositoryProvider.overrideWithValue(_MockCategoryRepository(categories)),
        userCardsProvider.overrideWith((ref) async => [ownedCard]),
        enteredAmountProvider.overrideWith((ref) => Money.fromRupees(1500)),
        selectedCategoryProvider.overrideWith((ref) => 'dining'),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    // In dining mode, 2% on 1500 = ₹30
    expect(find.text('MoneyBack+ Credit Card'), findsOneWidget);
    expect(find.text('₹30'), findsOneWidget);

    // Switch to Fuel
    await tester.tap(find.text('Fuel'));
    await tester.pumpAndSettle();

    // Verify recommendations provider
    final recsAsync = container.read(rankedRecommendationsProvider);
    expect(recsAsync.hasValue, isTrue);
    final recs = recsAsync.requireValue;
    expect(recs, isNotEmpty);
    expect(recs.first.isExcluded, isFalse);
    expect(recs.first.expectedValue, Money.fromRupees(15));
    expect(recs.first.reasonLines.any((r) => r.contains('Fuel surcharge waiver')), isTrue);

    // On screen: expected value should be ₹15, NOT ₹0
    expect(find.text('₹15'), findsOneWidget);
    expect(find.text('1% on Fuel'), findsOneWidget);
  });
}
