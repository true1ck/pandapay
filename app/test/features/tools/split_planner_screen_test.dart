import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/tools/split_planner_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// G2 Multi-Card Split Planner (Chunk 38) — SplitOptimizer.optimize() already
/// had unit coverage in packages/pandapay_domain/test/calculators_test.dart;
/// this exercises the screen wiring (splitPlanProvider, amount entry, empty
/// states) that Chunk 38 actually added.
class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

CardProduct _flatRateCard(String id, double ratePercent) {
  return CardProduct(
    id: id,
    name: 'Card $id',
    network: CardNetwork.rupay,
    isUpiLinkable: true,
    rewardRules: [RewardRule(id: '$id-rule', unit: RewardUnit.cashbackPercent, rate: ratePercent)],
  );
}

Future<void> _pump(WidgetTester tester, {required List<CardProduct> catalogue, required List<UserCard> owned}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
      ],
      child: const MaterialApp(home: Scaffold(body: SplitPlannerScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when the wallet has no cards', (tester) async {
    await _pump(tester, catalogue: const [], owned: const []);
    expect(find.text('No cards yet'), findsOneWidget);
  });

  testWidgets('prompts for an amount before any plan is computed', (tester) async {
    final product = _flatRateCard('p1', 2);
    final owned = UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false);

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('Enter an amount to see a split'), findsOneWidget);
  });

  testWidgets('typing an amount renders an allocation across the owned card', (tester) async {
    final product = _flatRateCard('p1', 2);
    final owned = UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false);

    await _pump(tester, catalogue: [product], owned: [owned]);

    await tester.enterText(find.byType(TextField), '1000');
    await tester.pumpAndSettle();

    expect(find.text('Enter an amount to see a split'), findsNothing);
    expect(find.text('Total expected reward value'), findsOneWidget);
    expect(find.text('Card p1'), findsOneWidget);
  });
}
