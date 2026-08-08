import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/caps_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Task 8 (E2 Caps & Limits). CapRule (definition) and
/// UserCard.capConsumed (this period's consumption) were both already
/// fetched by Chunk 17 — this screen is the first thing to display them.
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
      child: const MaterialApp(home: Scaffold(body: CapsScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when the wallet is empty', (tester) async {
    await _pump(tester, catalogue: const [], owned: const []);
    expect(find.text('No caps to track'), findsOneWidget);
  });

  testWidgets('renders a cap with low consumption in the success colour band', (tester) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
      capRules: const [
        CapRule(
          id: 'cap1',
          label: 'Monthly cashback cap',
          capValue: Money.fromPaise(500000), // ₹5,000
          measure: CapMeasure.rewardValue,
          period: CapPeriod.calendarMonth,
        ),
      ],
    );
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      capConsumed: const {'cap1': Money.fromPaise(50000)}, // ₹500 of ₹5,000 = 10%
    );

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('Monthly cashback cap'), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget);
  });

  testWidgets('shows a warning icon when consumption crosses 90%', (tester) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
      capRules: const [
        CapRule(
          id: 'cap1',
          label: 'Fuel surcharge waiver cap',
          capValue: Money.fromPaise(100000), // ₹1,000
          measure: CapMeasure.spendAmount,
          period: CapPeriod.calendarMonth,
        ),
      ],
    );
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      capConsumed: const {'cap1': Money.fromPaise(95000)}, // 95%
    );

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('a txn_count cap renders as a transaction count, not money', (tester) async {
    final product = CardProduct(
      id: 'p1',
      name: 'Test Card',
      network: CardNetwork.rupay,
      capRules: const [
        CapRule(
          id: 'cap1',
          label: 'Lounge visits',
          capValue: Money.fromPaise(400), // 4 visits, as a count
          measure: CapMeasure.txnCount,
          period: CapPeriod.quarter,
        ),
      ],
    );
    final owned = UserCard(
      id: 'uc1',
      cardProductId: 'p1',
      cardName: 'Test Card',
      isDefault: false,
      capConsumed: const {'cap1': Money.fromPaise(100)}, // 1 of 4
    );

    await _pump(tester, catalogue: [product], owned: [owned]);

    expect(find.text('3 transactions left'), findsOneWidget);
    expect(find.text('1 / 4'), findsOneWidget);
  });
}
