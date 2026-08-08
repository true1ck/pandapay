import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/missed_opportunities_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _FakeUserCardsRepository implements UserCardsRepository {
  final List<TransactionEntry> transactions;
  _FakeUserCardsRepository(this.transactions);

  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? source,
  }) async =>
      transactions;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final diningCard = CardProduct(
  id: 'dining',
  name: 'Dining Card',
  network: CardNetwork.rupay,
  rewardRules: const [
    RewardRule(id: 'r1', categoryId: 'dining', unit: RewardUnit.cashbackPercent, rate: 5),
    RewardRule(id: 'r2', unit: RewardUnit.cashbackPercent, rate: 1, priority: 200),
  ],
);
final flatCard = CardProduct(
  id: 'flat',
  name: 'Flat Card',
  network: CardNetwork.visa,
  rewardRules: const [RewardRule(id: 'r3', unit: RewardUnit.cashbackPercent, rate: 2, priority: 200)],
);

Future<void> _pump(
  WidgetTester tester, {
  required List<CardProduct> catalogue,
  required List<UserCard> owned,
  required List<TransactionEntry> transactions,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(catalogue)),
        userCardsProvider.overrideWith((ref) async => owned),
        userCardsRepositoryProvider.overrideWithValue(_FakeUserCardsRepository(transactions)),
      ],
      child: const MaterialApp(home: MissedOpportunitiesScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an empty state when nothing is sub-optimal', (tester) async {
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'dining', cardName: 'Dining Card', isDefault: false),
    ];
    await _pump(tester, catalogue: [diningCard], owned: owned, transactions: const []);
    expect(find.text('No missed opportunities in the last 90 days'), findsOneWidget);
  });

  testWidgets('flags a transaction on the flat card in the dining category as sub-optimal', (tester) async {
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'dining', cardName: 'Dining Card', isDefault: false),
      const UserCard(id: 'uc2', cardProductId: 'flat', cardName: 'Flat Card', isDefault: false),
    ];
    final transactions = [
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime.now(),
        merchantName: 'Dinner Spot',
        categoryId: 'dining',
        cardDisplayName: 'Flat Card',
        userCardId: 'uc2',
        source: 'manual',
        status: 'active',
      ),
    ];
    await _pump(tester, catalogue: [diningCard, flatCard], owned: owned, transactions: transactions);

    expect(find.text('Dinner Spot'), findsOneWidget);
    expect(find.textContaining('Dining Card would have earned'), findsOneWidget);
  });

  testWidgets('a transaction already on the best card is not flagged', (tester) async {
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'dining', cardName: 'Dining Card', isDefault: false),
      const UserCard(id: 'uc2', cardProductId: 'flat', cardName: 'Flat Card', isDefault: false),
    ];
    final transactions = [
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime.now(),
        merchantName: 'Dinner Spot',
        categoryId: 'dining',
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    ];
    await _pump(tester, catalogue: [diningCard, flatCard], owned: owned, transactions: transactions);

    expect(find.text('No missed opportunities in the last 90 days'), findsOneWidget);
  });

  testWidgets('an ignored transaction is never flagged', (tester) async {
    final owned = [
      const UserCard(id: 'uc1', cardProductId: 'dining', cardName: 'Dining Card', isDefault: false),
      const UserCard(id: 'uc2', cardProductId: 'flat', cardName: 'Flat Card', isDefault: false),
    ];
    final transactions = [
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime.now(),
        merchantName: 'Dinner Spot',
        categoryId: 'dining',
        userCardId: 'uc2',
        source: 'manual',
        status: 'ignored',
      ),
    ];
    await _pump(tester, catalogue: [diningCard, flatCard], owned: owned, transactions: transactions);

    expect(find.text('No missed opportunities in the last 90 days'), findsOneWidget);
  });
}
