import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/credit_utilization_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// E3 Credit Utilization (Chunk 36) — creditUtilization()/creditUtilizationProvider
/// already existed with zero callers before this pass; this is the first
/// coverage of the screen that actually renders them.
class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

Future<void> _pump(WidgetTester tester, {required List<CardProduct> catalogue, required List<UserCard> owned}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
      ],
      child: const MaterialApp(home: Scaffold(body: CreditUtilizationScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when the wallet has no cards', (tester) async {
    await _pump(tester, catalogue: const [], owned: const []);
    expect(find.text('No cards yet'), findsOneWidget);
  });

  testWidgets('shows the "add a credit limit" prompt when no owned card has one set', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false);

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('Add a credit limit to see utilization'), findsOneWidget);
  });

  testWidgets('always shows the informational disclaimer banner, even with data present', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      creditLimit: Money.fromRupees(10000),
      capConsumed: {'cap1': Money.fromRupees(2000)},
    );

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.textContaining('does not guarantee how any'), findsOneWidget);
  });

  testWidgets('renders utilization under the 30% threshold without a warning', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      creditLimit: Money.fromRupees(10000),
      capConsumed: {'cap1': Money.fromRupees(1000)}, // 10%
    );

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('10%'), findsOneWidget);
    expect(find.textContaining('Above the 30% guideline'), findsNothing);
  });

  testWidgets('renders a warning and the over-threshold copy above 30%', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay);
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      creditLimit: Money.fromRupees(10000),
      capConsumed: {'cap1': Money.fromRupees(5000)}, // 50%
    );

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('50%'), findsOneWidget);
    expect(find.textContaining('Above the 30% guideline'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });
}
