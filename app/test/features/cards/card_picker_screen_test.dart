import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/cards/card_picker_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

List<CardProduct> _catalogue() => [
      CardProduct(id: 'p1', name: 'Ace', network: CardNetwork.rupay, issuerName: 'Axis Bank'),
      CardProduct(id: 'p2', name: 'Millennia', network: CardNetwork.visa, issuerName: 'HDFC Bank'),
      CardProduct(id: 'p3', name: 'Cashback', network: CardNetwork.mastercard, issuerName: 'HDFC Bank'),
    ];

Future<void> _pumpAndPick(WidgetTester tester, {required List<CardProduct> catalogue}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue))],
      child: MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push<List<CardProduct>>(
              MaterialPageRoute(builder: (_) => const CardPickerScreen()),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('groups cards by issuer and shows all three by default', (tester) async {
    await _pumpAndPick(tester, catalogue: _catalogue());
    expect(find.text('Axis Bank'), findsOneWidget);
    expect(find.text('HDFC Bank'), findsOneWidget);
    expect(find.text('Ace'), findsOneWidget);
    expect(find.text('Millennia'), findsOneWidget);
    expect(find.text('Cashback'), findsOneWidget);
  });

  testWidgets('search filters by card name', (tester) async {
    await _pumpAndPick(tester, catalogue: _catalogue());
    await tester.enterText(find.byType(TextField), 'Millennia');
    await tester.pumpAndSettle();
    // findsNWidgets(2): the typed search text renders in the TextField
    // itself AND in the matching list row — find.text matches both.
    expect(find.text('Millennia'), findsNWidgets(2));
    expect(find.text('Ace'), findsNothing);
    expect(find.text('Cashback'), findsNothing);
  });

  testWidgets('network filter chip narrows results to that network', (tester) async {
    await _pumpAndPick(tester, catalogue: _catalogue());
    await tester.tap(find.widgetWithText(FilterChip, 'Visa'));
    await tester.pumpAndSettle();
    expect(find.text('Millennia'), findsOneWidget);
    expect(find.text('Ace'), findsNothing);
  });

  testWidgets('multi-select shows a running count and returns all picks on Add', (tester) async {
    List<CardProduct>? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(_catalogue()))],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<List<CardProduct>>(
                  MaterialPageRoute(builder: (_) => const CardPickerScreen()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Millennia'));
    await tester.pumpAndSettle();

    expect(find.text('Add (2)'), findsOneWidget);
    await tester.tap(find.text('Add (2)'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.map((c) => c.name).toSet(), {'Ace', 'Millennia'});
  });
}
