import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/points_expiry_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

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
  Map<String, List<PointsLedgerEntry>> ledgers = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
        for (final entry in ledgers.entries)
          pointsLedgerProvider(entry.key).overrideWith((ref) async => entry.value),
      ],
      child: const MaterialApp(home: PointsExpiryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state with no owned cards', (tester) async {
    await _pump(tester, catalogue: const [], owned: const []);
    expect(find.text('No points to track yet'), findsOneWidget);
  });

  testWidgets('shows the points balance and ₹ estimate for an owned card', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay, pointValueInr: 0.25);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', nickname: 'My Card', cardName: 'Test Card', isDefault: false, totalPointsEarned: 4000),
    ];
    await _pump(tester, catalogue: [product], owned: owned, ledgers: {'uc1': const []});

    expect(find.text('My Card'), findsOneWidget);
    expect(find.text('4000'), findsOneWidget);
    expect(find.textContaining('₹1,000'), findsOneWidget);
  });

  testWidgets('shows an urgency chip when a ledger row has a near expiry', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay, pointValueInr: 0.25);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false, totalPointsEarned: 1000),
    ];
    final soonExpiry = DateTime.now().add(const Duration(days: 10));
    await _pump(
      tester,
      catalogue: [product],
      owned: owned,
      ledgers: {
        'uc1': [
          PointsLedgerEntry(
            id: 'l1',
            deltaPoints: 1000,
            reason: 'manual correction',
            state: Confidence.estimated,
            expiresOn: soonExpiry,
            occurredAt: DateTime.now(),
          ),
        ],
      },
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('expire in'), findsOneWidget);
  });

  testWidgets('Correct balance opens a sheet and calls adjustPointsBalance', (tester) async {
    final product = CardProduct(id: 'p1', name: 'Test Card', network: CardNetwork.rupay, pointValueInr: 0.25);
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'p1', cardName: 'Test Card', isDefault: false, totalPointsEarned: 1000),
    ];
    await _pump(tester, catalogue: [product], owned: owned, ledgers: {'uc1': const []});

    await tester.tap(find.text('Correct balance'));
    await tester.pumpAndSettle();
    expect(find.text('Correct points balance'), findsOneWidget);
  });
}
