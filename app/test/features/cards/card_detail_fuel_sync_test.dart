import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/card_detail_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _FakeCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async =>
      const [SpendCategory(id: 'cat-fuel', slug: 'fuel', name: 'Fuel')];
}

CardProduct _cardWithFuelRule({bool includeFuelInRewards = false}) {
  return CardProduct(
    id: 'p1',
    name: 'Fuel Card',
    network: CardNetwork.visa,
    pointValueInr: 1,
    verifiedAt: DateTime(2026, 3, 1),
    rewardRules: includeFuelInRewards
        ? const [
            RewardRule(id: 'r1', categoryId: 'cat-fuel', unit: RewardUnit.cashbackPercent, rate: 0),
          ]
        : const [],
    capRules: const [],
    fuelRule: FuelSurchargeRule(
      surchargePercent: 1.0,
      waiverPercent: 1.0,
      minTxn: Money.fromRupees(400),
      maxTxn: Money.fromRupees(4000),
    ),
    benefits: const [],
  );
}

UserCard _ownedCard() => const UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      nickname: 'My Fuel Card',
      cardName: 'Fuel Card',
      isDefault: false,
      capConsumed: {},
    );

Future<void> _pump(WidgetTester tester, {required List<CardProduct> catalogue, required List<UserCard> owned, String id = 'uc1'}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        categoryRepositoryProvider.overrideWithValue(_FakeCategoryRepository()),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
      ],
      child: MaterialApp(home: CardDetailScreen(userCardId: id)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Rewards tab shows 1% waiver when fuel is not in reward rules', (tester) async {
    await _pump(tester, catalogue: [_cardWithFuelRule(includeFuelInRewards: false)], owned: [_ownedCard()]);
    expect(find.text('Fuel'), findsOneWidget);
    expect(find.text('Surcharge waiver'), findsOneWidget);
    expect(find.text('1% waiver'), findsOneWidget);
  });

  testWidgets('Rewards tab shows 1% waiver when fuel is in reward rules with 0% rate', (tester) async {
    await _pump(tester, catalogue: [_cardWithFuelRule(includeFuelInRewards: true)], owned: [_ownedCard()]);
    expect(find.text('Fuel'), findsOneWidget);
    expect(find.text('1% waiver'), findsOneWidget);
  });

  testWidgets('Caps tab shows 1% surcharge waived for fuel rule', (tester) async {
    await _pump(tester, catalogue: [_cardWithFuelRule()], owned: [_ownedCard()]);
    await tester.tap(find.text('Caps'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1% surcharge waived'), findsOneWidget);
  });

  testWidgets('Benefits tab synthesizes and shows 1% fuel surcharge waiver', (tester) async {
    await _pump(tester, catalogue: [_cardWithFuelRule()], owned: [_ownedCard()]);
    await tester.dragUntilVisible(
      find.text('Benefits'),
      find.byType(TabBar),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Benefits'));
    await tester.pumpAndSettle();
    expect(find.text('1% fuel surcharge waiver'), findsOneWidget);
  });
}
