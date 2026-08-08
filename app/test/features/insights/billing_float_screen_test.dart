import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/billing_float_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Task 11 (E7 Billing Cycle / Float). billingCycleFloat() was fully built
/// and tested in the engine with zero callers before this screen.
class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

Future<void> _pump(
  WidgetTester tester, {
  required List<CardProduct> catalogue,
  required List<UserCard> owned,
  DateTime? now,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
        if (now != null) clockProvider.overrideWithValue(TestClock(now)),
      ],
      child: const MaterialApp(home: Scaffold(body: BillingFloatScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when the wallet is empty', (tester) async {
    await _pump(tester, catalogue: const [], owned: const []);
    expect(find.text('No cards yet'), findsOneWidget);
  });

  testWidgets('a card with no statement day set shows a prompt, not a fabricated date', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false);

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('Set a statement day to see this card\'s float.'), findsOneWidget);
  });

  testWidgets('a card with a statement day shows the interest-free-days headline', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      statementDay: 15,
    );

    await _pump(
      tester,
      catalogue: [product],
      owned: [owned],
      now: DateTime(2026, 3, 1),
    );

    // Statement cuts 2026-03-15, 14 days from 2026-03-01; +20 day assumed
    // grace = 34 total interest-free days.
    expect(find.textContaining('34 interest-free days'), findsOneWidget);
    expect(find.textContaining('Statement cuts in 14 day'), findsOneWidget);
  });
}
