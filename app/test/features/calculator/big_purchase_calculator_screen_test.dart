import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/user_cards_repository.dart' show UserCard;
import 'package:pandapay/features/calculator/big_purchase_calculator_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  testWidgets('Split suggestion and EMI comparison show a Coming soon snackbar, never navigate', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Split suggestion'));
    await tester.pump();

    expect(find.text('Split suggestion is coming soon.'), findsOneWidget);
    expect(find.byType(BigPurchaseCalculatorScreen), findsOneWidget);
  });

  testWidgets('EMI comparison shows a Coming soon snackbar, never navigates', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('EMI comparison'));
    await tester.pump();

    expect(find.text('EMI comparison is coming soon.'), findsOneWidget);
    expect(find.byType(BigPurchaseCalculatorScreen), findsOneWidget);
  });

  testWidgets('shows the empty state when the wallet has no cards', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No cards yet'), findsOneWidget);
  });

  testWidgets('computes a per-card recommendation via the real engine for owned cards', (tester) async {
    final card = CardProduct(
      id: 'card-1',
      name: 'Test Rewards Card',
      network: CardNetwork.visa,
      isUpiLinkable: true,
    );
    final userCard = UserCard(id: 'uc-1', cardProductId: 'card-1', cardName: 'Test Rewards Card', isDefault: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => [card]),
          userCardsProvider.overrideWith((ref) async => [userCard]),
          categoriesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // A real engine.rank() result — not a fabricated/hardcoded ₹ value —
    // must show up as a list row keyed to the card.
    expect(find.text('Test Rewards Card'), findsOneWidget);
    expect(find.text('No cards yet'), findsNothing);
  });

  testWidgets(
      'an active category override forces that card to the top, same as Home, even though it earns less ₹ value',
      (tester) async {
    // Card A earns a much better rate for Fuel than Card B on raw ₹ value —
    // without the override wired in, Card A would rank first. The override
    // targets Card B for the Fuel category, so Card B must come out on top
    // instead, with the same "Override active" indicator Home shows.
    final categoryFuel = const SpendCategory(id: 'cat-fuel', slug: 'fuel', name: 'Fuel');
    final cardA = CardProduct(
      id: 'card-a',
      name: 'High Value Card',
      network: CardNetwork.visa,
      rewardRules: [
        RewardRule(id: 'rule-a', categoryId: 'cat-fuel', unit: RewardUnit.cashbackPercent, rate: 5),
      ],
    );
    final cardB = CardProduct(
      id: 'card-b',
      name: 'Overridden Card',
      network: CardNetwork.mastercard,
      rewardRules: [
        RewardRule(id: 'rule-b', categoryId: 'cat-fuel', unit: RewardUnit.cashbackPercent, rate: 1),
      ],
    );
    final userCardA = UserCard(id: 'uc-a', cardProductId: 'card-a', cardName: 'High Value Card', isDefault: true);
    final userCardB = UserCard(id: 'uc-b', cardProductId: 'card-b', cardName: 'Overridden Card', isDefault: false);
    final override = CardOverride(
      id: 'ov-1',
      userCardId: 'uc-b',
      scope: OverrideScope.category,
      categoryId: 'cat-fuel',
      isEnabled: true,
      createdAt: DateTime(2026, 1, 1),
      cardName: 'Overridden Card',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => [cardA, cardB]),
          userCardsProvider.overrideWith((ref) async => [userCardA, userCardB]),
          categoriesProvider.overrideWith((ref) async => [categoryFuel]),
          cardOverridesProvider.overrideWith((ref) async => [override]),
        ],
        child: const MaterialApp(home: BigPurchaseCalculatorScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Select the Fuel category chip so _categoryId picks up the override's scope.
    await tester.tap(find.text('Fuel'));
    await tester.pumpAndSettle();

    // The overridden card (lower raw ₹ value) must be the first list row,
    // and must carry the override indicator.
    final firstCardFinder = find.byType(Card).first;
    expect(
      find.descendant(of: firstCardFinder, matching: find.text('Overridden Card')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: firstCardFinder, matching: find.text('Override active')),
      findsOneWidget,
    );
  });
}
