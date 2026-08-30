import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/insights_hub_screen.dart';
import 'package:pandapay/features/insights/insights_overview.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Feeds the Insights tab dummy spend and checks the numbers it computes and
/// renders — the "does the logic actually work when data shows up" test the
/// emulator can't give without a full backend + Postgres.

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
    String? query,
  }) async =>
      transactions.where((t) {
        if (from != null && t.occurredAt.isBefore(from)) return false;
        if (to != null && !t.occurredAt.isBefore(to)) return false;
        return true;
      }).toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// A 5% dining card and a 1% flat card — enough for a real "wrong card" miss.
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
  rewardRules: const [RewardRule(id: 'r3', unit: RewardUnit.cashbackPercent, rate: 1, priority: 200)],
);

final _owned = [
  const UserCard(id: 'uc-dining', cardProductId: 'dining', cardName: 'Dining Card', isDefault: true),
  const UserCard(id: 'uc-flat', cardProductId: 'flat', cardName: 'Flat Card', isDefault: false),
];

TransactionEntry _txn({
  required String id,
  required String card,
  required num amount,
  required num reward,
  required String categoryId,
  required String categoryName,
  required DateTime on,
}) =>
    TransactionEntry(
      id: id,
      amount: Money.fromRupees(amount),
      occurredAt: on,
      merchantName: '$categoryName merchant',
      categoryId: categoryId,
      categoryName: categoryName,
      cardDisplayName: card == 'uc-dining' ? 'Dining Card' : 'Flat Card',
      userCardId: card,
      source: 'sms',
      status: 'active',
      rewardValue: Money.fromRupees(reward),
    );

// "This month" per the fixed clock below (2026-08-15).
final _thisMonth = [
  _txn(id: 't1', card: 'uc-dining', amount: 2000, reward: 100, categoryId: 'dining', categoryName: 'Dining', on: DateTime(2026, 8, 3)),
  _txn(id: 't2', card: 'uc-dining', amount: 5000, reward: 250, categoryId: 'dining', categoryName: 'Dining', on: DateTime(2026, 8, 8)),
  _txn(id: 't3', card: 'uc-flat', amount: 4000, reward: 40, categoryId: 'groceries', categoryName: 'Groceries', on: DateTime(2026, 8, 10)),
  // Dining spend put on the flat card — the comparator should flag this.
  _txn(id: 't4', card: 'uc-flat', amount: 3000, reward: 30, categoryId: 'dining', categoryName: 'Dining', on: DateTime(2026, 8, 12)),
];

Future<ProviderContainer> _container(List<TransactionEntry> txns) async {
  final c = ProviderContainer(
    overrides: [
      catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([diningCard, flatCard])),
      userCardsProvider.overrideWith((ref) async => _owned),
      userCardsRepositoryProvider.overrideWithValue(_FakeUserCardsRepository(txns)),
      clockProvider.overrideWithValue(TestClock(DateTime(2026, 8, 15))),
    ],
  );
  addTearDown(c.dispose);
  // Warm the async deps the overview watches.
  await c.read(userCardsProvider.future);
  await c.read(catalogueProvider.future);
  return c;
}

void main() {
  test('empty period -> InsightsOverview.empty, transactionCount 0', () async {
    final c = await _container(const []);
    final o = await c.read(insightsOverviewProvider(InsightsPeriod.thisMonth).future);
    expect(o.transactionCount, 0);
    expect(o.earned, const Money.zero());
  });

  test('aggregates dummy spend: earned, spend, effective rate, category split', () async {
    final c = await _container(_thisMonth);
    final o = await c.read(insightsOverviewProvider(InsightsPeriod.thisMonth).future);

    expect(o.transactionCount, 4);
    expect(o.spend, Money.fromRupees(14000)); // 2000+5000+4000+3000
    expect(o.earned, Money.fromRupees(420)); // 100+250+40+30
    // 420 / 14000 * 100 = 3.0%
    expect(o.effectiveRatePct, closeTo(3.0, 0.001));

    // Dining (100+250+30 = 380) outranks Groceries (40).
    expect(o.byCategory.first.label, 'Dining');
    expect(o.byCategory.first.earned, Money.fromRupees(380));
    expect(o.bestCategory?.label, 'Dining');

    // Per-card split, highest first.
    expect(o.byCard.first.label, 'Dining Card');
    expect(o.byCard.first.earned, Money.fromRupees(350));
  });

  test('flags the dining swipe made on the 1% flat card as money left on the table', () async {
    final c = await _container(_thisMonth);
    final o = await c.read(insightsOverviewProvider(InsightsPeriod.thisMonth).future);

    expect(o.missedCount, greaterThanOrEqualTo(1));
    expect(o.missed.paise, greaterThan(0));
    expect(o.missedIsEstimate, isTrue);
    expect(o.topMissed.first.betterCard.id, 'dining');
  });

  test('last-month period excludes this-month rows', () async {
    final c = await _container(_thisMonth);
    final o = await c.read(insightsOverviewProvider(InsightsPeriod.lastMonth).future);
    expect(o.transactionCount, 0);
  });

  testWidgets('Insights tab renders the earned hero and category bar from dummy data', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository([diningCard, flatCard])),
          userCardsProvider.overrideWith((ref) async => _owned),
          userCardsRepositoryProvider.overrideWithValue(_FakeUserCardsRepository(_thisMonth)),
          clockProvider.overrideWithValue(TestClock(DateTime(2026, 8, 15))),
        ],
        child: const MaterialApp(home: Scaffold(body: InsightsHubScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('REWARDS EARNED'), findsOneWidget);
    expect(find.text('Where it came from'), findsOneWidget);
    expect(find.textContaining('effective'), findsOneWidget);
    expect(find.text('Left on the table'), findsOneWidget);
    expect(find.text('Nothing to report yet'), findsNothing);
  });
}
