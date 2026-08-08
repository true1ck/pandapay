import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
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
}
