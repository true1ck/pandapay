import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/scan/scan_result_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id, {bool isUpiLinkable = true, double rate = 0.02}) => CardProduct(
      id: id,
      name: id,
      network: CardNetwork.visa,
      isUpiLinkable: isUpiLinkable,
      rewardRules: [
        RewardRule(id: '$id-rule', priority: 1, unit: RewardUnit.cashbackPercent, rate: rate),
      ],
    );

void main() {
  testWidgets('a P2P-detected QR shows the personal-transfer notice, not a card list', (tester) async {
    const parsed = ParsedUpiQr(pa: 'friend@okaxis', pn: 'A Friend', isLikelyP2P: true);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Credit cards can't be used for personal transfers"), findsOneWidget);
  });

  testWidgets('a merchant QR pre-fills the merchant name field from pn', (tester) async {
    const parsed = ParsedUpiQr(pa: 'shop@okhdfcbank', pn: 'DMart Powai', mc: '5411', isLikelyP2P: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => const []),
          categoriesProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'DMart Powai'), findsOneWidget);
  });

  testWidgets('a RuPay-only card shows the engine exclusion reason verbatim, greyed', (tester) async {
    const parsed = ParsedUpiQr(pa: 'shop@okhdfcbank', pn: 'Local Store', isLikelyP2P: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => [_card('rupay-card', isUpiLinkable: false)]),
          categoriesProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not usable via UPI — swipe this instead.'), findsOneWidget);
    // Excluded cards never get a "Pay with" action.
    expect(find.widgetWithText(FilledButton, 'Pay with rupay-card'), findsNothing);
  });

  testWidgets('tapping "Wasn\'t accepted" removes that card from the ranked list', (tester) async {
    // A non-zero `am` so the two cards' differing reward rates actually
    // produce different expectedValue results — at ₹0 spend the engine's
    // final card-id tie-break would rank card-a first regardless of rate,
    // which would make this test pass for the wrong reason.
    final parsed = ParsedUpiQr(pa: 'shop@okhdfcbank', pn: 'Local Store', isLikelyP2P: false, am: Money.fromRupees(1000));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueProvider.overrideWith((ref) async => [_card('card-a', rate: 0.05), _card('card-b', rate: 0.01)]),
          categoriesProvider.overrideWith((ref) async => const []),
          userCardsProvider.overrideWith((ref) async => const []),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(home: ScanResultScreen(parsed: parsed)),
      ),
    );
    await tester.pumpAndSettle();

    // card-a ranks first (higher rate) and shows a "Pay with card-a" button.
    expect(find.widgetWithText(FilledButton, 'Pay with card-a'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, "Wasn't accepted").first);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Pay with card-a'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Pay with card-b'), findsOneWidget);
  });
}
