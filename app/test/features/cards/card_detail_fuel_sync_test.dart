import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/card_detail_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _FakeCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [
    SpendCategory(id: 'cat-fuel', slug: 'fuel', name: 'Fuel'),
  ];
}

CardProduct _cardWithFuelRule({
  bool includeFuelInRewards = false,
  bool includeBaseReward = false,
}) {
  return CardProduct(
    id: 'p1',
    name: 'Fuel Card',
    network: CardNetwork.visa,
    pointValueInr: 1,
    verifiedAt: DateTime(2026, 3, 1),
    rewardRules: [
      if (includeFuelInRewards)
        const RewardRule(
          id: 'r1',
          categoryId: 'cat-fuel',
          unit: RewardUnit.cashbackPercent,
          rate: 0,
        ),
      if (includeBaseReward)
        const RewardRule(id: 'base', unit: RewardUnit.cashbackPercent, rate: 1),
    ],
    capRules: const [],
    fuelRule: FuelSurchargeRule(
      surchargePercent: 1.0,
      waiverPercent: 1.0,
      minTxn: Money.fromRupees(400),
      maxTxn: Money.fromRupees(4000),
    ),
    benefits: const [],
  );
}

UserCard _ownedCard() => const UserCard(
  id: 'uc1',
  cardProductId: 'p1',
  nickname: 'My Fuel Card',
  cardName: 'Fuel Card',
  isDefault: false,
  capConsumed: {},
);

Future<void> _pump(
  WidgetTester tester, {
  required List<CardProduct> catalogue,
  required List<UserCard> owned,
  String id = 'uc1',
  SpendReport? report,
  bool categoriesAvailable = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(
          _FakeCatalogueRepository(catalogue),
        ),
        categoryRepositoryProvider.overrideWithValue(_FakeCategoryRepository()),
        categoriesProvider.overrideWith(
          (ref) async => categoriesAvailable
              ? await _FakeCategoryRepository().fetchCategories()
              : const [],
        ),
        userCardsProvider.overrideWith((ref) async => owned),
        myCardsProvider.overrideWith((ref) async => owned),
        if (report != null)
          spendReportProvider.overrideWith((ref, query) async => report),
      ],
      child: MaterialApp(home: CardDetailScreen(userCardId: id)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Rewards tab shows 1% waiver when fuel is not in reward rules', (
    tester,
  ) async {
    await _pump(
      tester,
      catalogue: [_cardWithFuelRule(includeFuelInRewards: false)],
      owned: [_ownedCard()],
    );
    expect(find.text('Fuel'), findsOneWidget);
    expect(find.textContaining('Surcharge waiver'), findsOneWidget);
    expect(find.textContaining('1% waiver'), findsOneWidget);
    expect(find.textContaining('Sign in to see actual spend'), findsOneWidget);
  });

  testWidgets(
    'Rewards tab shows 1% waiver when fuel is in reward rules with 0% rate',
    (tester) async {
      await _pump(
        tester,
        catalogue: [_cardWithFuelRule(includeFuelInRewards: true)],
        owned: [_ownedCard()],
      );
      expect(find.text('Fuel'), findsOneWidget);
      expect(find.textContaining('1% waiver'), findsOneWidget);
    },
  );

  testWidgets('Caps section shows 1% surcharge waived for fuel rule', (
    tester,
  ) async {
    await _pump(
      tester,
      catalogue: [_cardWithFuelRule()],
      owned: [_ownedCard()],
    );
    await tester.scrollUntilVisible(
      find.text('CAPS'),
      500,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('cardDetailScroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('1% surcharge waived'), findsOneWidget);
  });

  for (final categoriesAvailable in [true, false]) {
    testWidgets('reward rows split actual card spend from all other categories '
        '(categories available: $categoriesAvailable)', (tester) async {
      final now = DateTime.now();
      final report = SpendReport(
        period: SpendPeriod.month,
        periodStart: DateTime(now.year, now.month),
        periodEnd: DateTime(now.year, now.month + 1),
        elapsedFraction: 0.5,
        spend: EntryKindTotals.zero,
        income: EntryKindTotals.zero,
        investment: EntryKindTotals.zero,
        previousSpend: EntryKindTotals.zero,
        byCategory: const [],
        byMerchant: const [],
        byCard: const [],
        byInstrument: const [],
        byCardCategory: [
          CardCategorySpendRow(
            cardId: 'uc1',
            cardName: 'My Fuel Card',
            categoryId: 'cat-fuel',
            categoryName: 'Fuel',
            total: Money.fromRupees(1200),
            txnCount: 2,
          ),
          CardCategorySpendRow(
            cardId: 'uc1',
            cardName: 'My Fuel Card',
            categoryId: 'cat-food',
            categoryName: 'Food',
            total: Money.fromRupees(500),
            txnCount: 1,
          ),
          CardCategorySpendRow(
            cardId: 'other-card',
            cardName: 'Other Card',
            categoryId: 'cat-fuel',
            categoryName: 'Fuel',
            total: Money.fromRupees(9000),
            txnCount: 1,
          ),
        ],
        series: const [],
      );
      await _pump(
        tester,
        catalogue: [_cardWithFuelRule(includeBaseReward: true)],
        owned: [_ownedCard()],
        report: report,
        categoriesAvailable: categoriesAvailable,
      );

      expect(find.text('₹1.2K'), findsOneWidget);
      expect(find.textContaining('Spent this month ₹1.2K'), findsOneWidget);
      expect(find.text('All other spends'), findsOneWidget);
      expect(find.textContaining('Spent this month ₹500'), findsOneWidget);
      expect(find.textContaining('1% waiver'), findsOneWidget);
    });
  }

  testWidgets(
    'shows one card-scoped pie after the card with deduplicated expandable categories',
    (tester) async {
      final now = DateTime.now();
      CardCategorySpendRow row(
        String cardId,
        String? categoryId,
        String name,
        int rupees,
      ) => CardCategorySpendRow(
        cardId: cardId,
        cardName: 'My Fuel Card',
        categoryId: categoryId,
        categoryName: name,
        total: Money.fromRupees(rupees),
        txnCount: 1,
      );

      final report = SpendReport(
        period: SpendPeriod.month,
        periodStart: DateTime(now.year, now.month),
        periodEnd: DateTime(now.year, now.month + 1),
        elapsedFraction: 0.5,
        spend: EntryKindTotals.zero,
        income: EntryKindTotals.zero,
        investment: EntryKindTotals.zero,
        previousSpend: EntryKindTotals.zero,
        byCategory: const [],
        byMerchant: const [],
        byCard: const [],
        byInstrument: const [],
        byCardCategory: [
          row('uc1', 'cat-fuel', 'Fuel', 1200),
          row('uc1', 'cat-food', 'Food', 800),
          row('uc1', 'legacy-other', 'Uncategorized', 300),
          row('uc1', null, 'Other', 200),
          row('uc1', 'cat-travel', 'Travel', 400),
          row('uc1', 'cat-shopping', 'Shopping', 300),
          row('uc1', 'cat-zero', 'Zero category', 0),
          row('other-card', 'cat-large', 'Wrong card', 9000),
        ],
        series: const [],
      );

      await _pump(
        tester,
        catalogue: [_cardWithFuelRule()],
        owned: [_ownedCard()],
        report: report,
      );

      expect(find.byKey(const Key('card_spending_mix')), findsOneWidget);
      expect(find.byKey(const Key('spending_donut_chart')), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('Zero category'), findsNothing);
      expect(find.text('Wrong card'), findsNothing);
      expect(find.text('Show 1 more category'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(4));

      final mixTop = tester.getTopLeft(
        find.byKey(const Key('card_spending_mix')),
      );
      final rewardsTop = tester.getTopLeft(find.text('REWARDS'));
      expect(mixTop.dy, lessThan(rewardsTop.dy));

      await tester.tap(find.text('Other'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'No individual transaction records available for this period.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Benefits section synthesizes and shows 1% fuel surcharge waiver',
    (tester) async {
      await _pump(
        tester,
        catalogue: [_cardWithFuelRule()],
        owned: [_ownedCard()],
      );
      await tester.scrollUntilVisible(
        find.text('BENEFITS'),
        500,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('cardDetailScroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('1% fuel surcharge waiver'), findsOneWidget);
    },
  );
}
