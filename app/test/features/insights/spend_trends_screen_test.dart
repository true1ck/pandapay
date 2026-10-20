import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/cards/card_summary.dart';
import 'package:pandapay/features/insights/spend_trends_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// The Trends screen's contract: it reports, it compares, and it never
/// blends figures that mean different things.
SpendReport _report({
  double spend = 42000,
  double previousSpend = 35000,
  double income = 0,
  double investment = 0,
  double rewards = 0,
  double elapsed = 0.5,
  List<SpendBreakdownRow> byCategory = const [],
  List<SpendBreakdownRow> byMerchant = const [],
  List<CardSpendRow> byCard = const [],
  List<InstrumentSpendRow> byInstrument = const [],
  List<SpendSeriesPoint> series = const [],
}) => SpendReport(
  period: SpendPeriod.month,
  periodStart: DateTime(2026, 8, 1),
  periodEnd: DateTime(2026, 9, 1),
  elapsedFraction: elapsed,
  spend: EntryKindTotals(
    total: Money.fromRupees(spend),
    txnCount: 12,
    rewards: Money.fromRupees(rewards),
  ),
  income: EntryKindTotals(
    total: Money.fromRupees(income),
    txnCount: income > 0 ? 1 : 0,
    rewards: const Money.zero(),
  ),
  investment: EntryKindTotals(
    total: Money.fromRupees(investment),
    txnCount: investment > 0 ? 1 : 0,
    rewards: const Money.zero(),
  ),
  previousSpend: EntryKindTotals(
    total: Money.fromRupees(previousSpend),
    txnCount: 10,
    rewards: const Money.zero(),
  ),
  byCategory: byCategory,
  byMerchant: byMerchant,
  byCard: byCard,
  byInstrument: byInstrument,
  series: series,
);

Future<void> _pump(
  WidgetTester tester,
  SpendReport? report, {
  List<TransactionEntry> transactions = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedSpendQueryProvider.overrideWith(
          (ref) => const SpendReportQuery.preset(SpendPeriod.month),
        ),
        spendReportProvider.overrideWith((ref, period) async => report),
        spendPeriodTransactionsProvider.overrideWith(
          (ref, period) async => transactions,
        ),
      ],
      child: const MaterialApp(home: SpendTrendsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

TransactionEntry _detailEntry({
  required String id,
  required String merchant,
  required double amount,
  required String categoryId,
  required String categoryName,
  required DateTime occurredAt,
  double reward = 0,
  String? subcategoryName,
  List<TransactionTag> tags = const [],
}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(amount),
  occurredAt: occurredAt,
  merchantName: merchant,
  categoryId: categoryId,
  categoryName: categoryName,
  subcategoryName: subcategoryName,
  tags: tags,
  cardDisplayName: 'HDFC Millennia',
  userCardId: 'uc-1',
  rail: TxnRail.swipe,
  instrument: TxnInstrument.creditCard,
  source: 'sms',
  status: 'active',
  rewardValue: Money.fromRupees(reward),
);

void main() {
  testWidgets('tag rows expand into categories and open scoped activity', (
    tester,
  ) async {
    const trip = TransactionTag(id: 'trip', name: 'Thailand trip');
    final rows = [
      _detailEntry(
        id: 'meal',
        merchant: 'Bangkok Cafe',
        amount: 500,
        categoryId: 'dining',
        categoryName: 'Dining',
        occurredAt: DateTime(2026, 8, 10),
        tags: [trip],
      ),
      _detailEntry(
        id: 'taxi',
        merchant: 'Bangkok Taxi',
        amount: 1000,
        categoryId: 'travel',
        categoryName: 'Travel',
        occurredAt: DateTime(2026, 8, 11),
        tags: [trip],
      ),
    ];
    final router = GoRouter(
      initialLocation: '/spending',
      routes: [
        GoRoute(
          path: '/spending',
          builder: (context, state) => const SpendTrendsScreen(),
        ),
        GoRoute(
          path: '/activity',
          builder: (context, state) =>
              Text(state.uri.toString(), key: const ValueKey('activity-uri')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transactionTagsProvider.overrideWith((ref) => null),
          selectedSpendQueryProvider.overrideWith(
            (ref) => const SpendReportQuery.preset(SpendPeriod.month),
          ),
          spendReportProvider.overrideWith(
            (ref, query) async => _report(spend: 1500),
          ),
          spendPeriodTransactionsProvider.overrideWith(
            (ref, query) async => rows,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Tags'));
    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();
    expect(find.text('TAGS'), findsOneWidget);
    expect(find.text('Thailand trip'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const PageStorageKey<String>('spending-tag-trip')),
        matching: find.byType(CardSummaryPanel),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const PageStorageKey<String>('spending-tag-trip')),
        matching: find.text('₹1,500.00'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Thailand trip'));
    await tester.pumpAndSettle();
    expect(find.text('Dining'), findsOneWidget);
    expect(find.text('Travel'), findsOneWidget);
    expect(find.byIcon(Icons.sell_rounded), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tag-category-trip-dining')),
        matching: find.byIcon(Icons.restaurant_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tag-category-trip-travel')),
        matching: find.byIcon(Icons.flight_takeoff_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tag-category-trip-dining')),
        matching: find.text('₹500.00'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tag-category-trip-travel')),
        matching: find.text('₹1,000.00'),
      ),
      findsOneWidget,
    );

    final diningRow = find.byKey(const ValueKey('tag-category-trip-dining'));
    await tester.ensureVisible(diningRow);
    await tester.pumpAndSettle();
    await tester.tap(diningRow);
    await tester.pumpAndSettle();
    final activityUri = Uri.parse(
      tester.widget<Text>(find.byKey(const ValueKey('activity-uri'))).data!,
    );
    expect(activityUri.path, '/activity');
    expect(activityUri.queryParameters['tag'], 'trip');
    expect(activityUri.queryParameters['category'], 'dining');
    expect(activityUri.queryParameters['from'], '2026-08-01');
    expect(activityUri.queryParameters['to'], '2026-08-31');
    expect(activityUri.queryParameters['spendOnly'], 'true');
    expect(tester.takeException(), isNull);
    router.dispose();
  });

  testWidgets('tag filters, preview and donut use one deduplicated selection', (
    tester,
  ) async {
    const trip = TransactionTag(id: 'trip', name: 'Thailand trip');
    const office = TransactionTag(id: 'office', name: 'Office');
    final rows = [
      _detailEntry(
        id: 'one',
        merchant: 'Cafe',
        amount: 500,
        categoryId: 'food',
        categoryName: 'Dining',
        occurredAt: DateTime(2026, 8, 10),
        tags: [trip, office],
      ),
      _detailEntry(
        id: 'two',
        merchant: 'Taxi',
        amount: 1000,
        categoryId: 'travel',
        categoryName: 'Travel',
        occurredAt: DateTime(2026, 8, 11),
        tags: [trip],
      ),
      _detailEntry(
        id: 'three',
        merchant: 'Shop',
        amount: 250,
        categoryId: 'online',
        categoryName: 'Shopping',
        occurredAt: DateTime(2026, 8, 12),
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transactionTagsProvider.overrideWith((ref) => null),
          selectedSpendQueryProvider.overrideWith(
            (ref) => const SpendReportQuery.preset(SpendPeriod.month),
          ),
          spendReportProvider.overrideWith(
            (ref, query) async => _report(spend: 1750),
          ),
          spendPeriodTransactionsProvider.overrideWith(
            (ref, query) async => rows,
          ),
        ],
        child: const MaterialApp(
          home: SpendTrendsScreen(initialTagIds: {'trip', 'office'}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('1,500'), findsWidgets);
    expect(find.textContaining('1,750'), findsNothing);
    await tester.tap(find.text('Filters ·'));
    await tester.pumpAndSettle();
    final preview = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText())
        .join('\n');
    expect(preview, contains('2 matching transactions'));
    expect(preview, contains('₹1,500'));
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Untagged'));
    await tester.tap(find.widgetWithText(FilterChip, 'Untagged'));
    await tester.pumpAndSettle();
    final untagged = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText())
        .join('\n');
    expect(untagged, contains('1 matching transaction'));
    expect(untagged, contains('₹250'));
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1,500'), findsNothing);
    expect(find.textContaining('250'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'shows the period total and comparison in the spending mix card',
    (tester) async {
      await _pump(
        tester,
        _report(
          spend: 42000,
          previousSpend: 35000,
          byCategory: [
            SpendBreakdownRow(
              label: 'Dining',
              total: Money.fromRupees(42000),
              txnCount: 12,
              categoryId: 'dining',
            ),
          ],
        ),
      );

      expect(find.textContaining('42,000'), findsWidgets);
      expect(find.text('20%'), findsOneWidget);
      expect(find.text('vs last month'), findsOneWidget);
      expect(find.text('TOTAL SPENT'), findsNothing);
      expect(find.textContaining('On track for'), findsNothing);
      final chartTitle = tester.getRect(find.text('Spending mix'));
      final comparison = tester.getRect(
        find.byKey(const ValueKey('spending_mix_comparison')),
      );
      final metrics = tester.getRect(
        find.byKey(const ValueKey('spending_summary_card')),
      );
      expect(comparison.left, greaterThan(chartTitle.right));
      expect(comparison.top, lessThan(metrics.top));
    },
  );

  testWidgets('a drop is reported as less, not as a negative increase', (
    tester,
  ) async {
    await _pump(
      tester,
      _report(
        spend: 28000,
        previousSpend: 35000,
        byCategory: [
          SpendBreakdownRow(
            label: 'Dining',
            total: Money.fromRupees(28000),
            txnCount: 8,
            categoryId: 'dining',
          ),
        ],
      ),
    );
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('vs last month'), findsOneWidget);
  });

  testWidgets('no comparison is shown when the previous period had no spend', (
    tester,
  ) async {
    await _pump(
      tester,
      _report(
        spend: 42000,
        previousSpend: 0,
        byCategory: [
          SpendBreakdownRow(
            label: 'Dining',
            total: Money.fromRupees(42000),
            txnCount: 12,
            categoryId: 'dining',
          ),
        ],
      ),
    );
    expect(find.text('20%'), findsNothing);
    expect(find.text('vs last month'), findsNothing);
  });

  testWidgets(
    'compact summary shows money in and net balance without investment',
    (tester) async {
      await _pump(
        tester,
        _report(spend: 42000, income: 90000, investment: 15000),
      );

      expect(find.text('Money in'), findsOneWidget);
      expect(find.text('Spent'), findsOneWidget);
      expect(find.text('Surplus'), findsOneWidget);
      expect(find.text('Invested'), findsNothing);
      expect(find.text('Left over'), findsNothing);
      expect(find.textContaining('42,000'), findsWidgets);
    },
  );

  testWidgets('negative net flow is shown as short by in the compact summary', (
    tester,
  ) async {
    await _pump(tester, _report(spend: 90000, income: 40000));
    expect(find.text('Short by'), findsOneWidget);
    expect(find.text('Left over'), findsNothing);
  });

  testWidgets(
    'compact summary keeps all four metrics when income and rewards are zero',
    (tester) async {
      await _pump(tester, _report(spend: 42000));
      expect(find.text('Money in'), findsOneWidget);
      expect(find.text('Spent'), findsOneWidget);
      expect(find.text('Short by'), findsOneWidget);
      expect(find.text('Rewards earned'), findsOneWidget);
      expect(find.textContaining('₹0.00'), findsWidgets);
    },
  );

  testWidgets(
    'category chart stays above compact two-column spending summary',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(
        tester,
        _report(
          spend: 42000,
          previousSpend: 35000,
          income: 12000,
          rewards: 420,
          byCategory: [
            SpendBreakdownRow(
              label: 'Dining',
              total: Money.fromRupees(28000),
              txnCount: 8,
              categoryId: 'dining',
            ),
            SpendBreakdownRow(
              label: 'Shopping',
              total: Money.fromRupees(14000),
              txnCount: 4,
              categoryId: 'shopping',
            ),
          ],
        ),
      );

      final chartTitle = tester.getTopLeft(find.text('Spending mix'));
      final summaryRect = tester.getRect(
        find.byKey(const ValueKey('spending_summary_card')),
      );
      expect(chartTitle.dy, lessThan(summaryRect.top));
      expect(find.text('TOTAL SPENT'), findsNothing);
      expect(find.textContaining('On track for'), findsNothing);
      expect(find.text('20%'), findsOneWidget);
      expect(summaryRect.height, lessThan(180));

      final moneyIn = tester.getRect(find.text('Money in'));
      final spent = tester.getRect(find.text('Spent'));
      final shortBy = tester.getRect(find.text('Short by'));
      final rewards = tester.getRect(find.text('Rewards earned'));
      expect(spent.left, greaterThan(moneyIn.left));
      expect(rewards.left, greaterThan(shortBy.left));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact summary stacks metrics on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(
      tester,
      _report(
        spend: 42000,
        income: 12000,
        rewards: 420,
        byCategory: [
          SpendBreakdownRow(
            label: 'Dining',
            total: Money.fromRupees(28000),
            txnCount: 8,
            categoryId: 'dining',
          ),
          SpendBreakdownRow(
            label: 'Shopping',
            total: Money.fromRupees(14000),
            txnCount: 4,
            categoryId: 'shopping',
          ),
        ],
      ),
    );

    final moneyIn = tester.getTopLeft(find.text('Money in'));
    final spent = tester.getTopLeft(find.text('Spent'));
    final shortBy = tester.getTopLeft(find.text('Short by'));
    final rewards = tester.getTopLeft(find.text('Rewards earned'));
    expect(moneyIn.dy, lessThan(spent.dy));
    expect(spent.dy, lessThan(shortBy.dy));
    expect(shortBy.dy, lessThan(rewards.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('view all in a multi-month mix opens the full categories list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSpendQueryProvider.overrideWith(
            (ref) => SpendReportQuery.custom(
              from: DateTime(2026, 8, 1),
              to: DateTime(2026, 10, 31),
            ),
          ),
          spendReportProvider.overrideWith(
            (ref, query) async => _report(
              spend: 2100,
              byCategory: [
                for (var index = 1; index <= 6; index++)
                  SpendBreakdownRow(
                    label: 'Category $index',
                    total: Money.fromRupees(100 * index),
                    txnCount: index,
                    categoryId: 'category-$index',
                  ),
              ],
            ),
          ),
          spendPeriodTransactionsProvider.overrideWith(
            (ref, query) async => const [],
          ),
        ],
        child: const MaterialApp(home: SpendTrendsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final viewAll = find.byKey(const ValueKey('spending_mix_view_all'));
    expect(viewAll, findsOneWidget);
    await tester.tap(viewAll);
    await tester.pumpAndSettle();

    expect(find.text('CATEGORIES'), findsOneWidget);
    expect(find.text('Category 6'), findsOneWidget);
  });

  testWidgets(
    'a card row reports the rate it actually paid, not its headline rate',
    (tester) async {
      await _pump(
        tester,
        _report(
          spend: 40000,
          rewards: 400,
          byCard: [
            CardSpendRow(
              cardId: 'uc1',
              cardName: 'Axis Magnus',
              total: Money.fromRupees(40000),
              rewards: Money.fromRupees(400),
              txnCount: 8,
              effectiveRatePerRupee: 0.01,
            ),
          ],
        ),
      );
      expect(
        find.textContaining('1.00% back on what you spent here'),
        findsOneWidget,
      );
    },
  );

  testWidgets('shows each credit card as its own spend row', (tester) async {
    await _pump(
      tester,
      _report(
        spend: 1800,
        byCard: [
          CardSpendRow(
            cardId: 'uc-1',
            cardName: 'HDFC Millennia',
            total: Money.fromRupees(1200),
            rewards: Money.zero(),
            txnCount: 2,
          ),
          CardSpendRow(
            cardId: 'uc-2',
            cardName: 'Axis Ace',
            total: Money.fromRupees(600),
            rewards: Money.zero(),
            txnCount: 1,
          ),
        ],
      ),
    );
    expect(find.text('HDFC Millennia'), findsOneWidget);
    expect(find.text('Axis Ace'), findsOneWidget);
    expect(find.text('2 transactions'), findsOneWidget);
    expect(find.text('1 transaction'), findsOneWidget);
  });

  testWidgets('expands a category into merchants and transaction details', (
    tester,
  ) async {
    final transactions = [
      _detailEntry(
        id: 'txn-1',
        merchant: 'Swiggy',
        amount: 200,
        categoryId: 'dining',
        categoryName: 'Dining',
        subcategoryName: 'Dinner',
        occurredAt: DateTime(2026, 8, 12),
        reward: 10,
      ),
      _detailEntry(
        id: 'txn-2',
        merchant: 'Cafe Central',
        amount: 50,
        categoryId: 'dining',
        categoryName: 'Dining',
        occurredAt: DateTime(2026, 8, 11),
        reward: 2.5,
      ),
    ];
    await _pump(
      tester,
      _report(
        spend: 250,
        byCategory: [
          SpendBreakdownRow(
            label: 'Dining',
            total: Money.fromRupees(250),
            txnCount: 2,
            categoryId: 'dining',
          ),
        ],
      ),
      transactions: transactions,
    );

    // The category list follows the headline/mix cards and may be lazily
    // built below the initial viewport.
    await tester.scrollUntilVisible(
      find.text('Dining'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Dining'), findsOneWidget);
    expect(find.text('Swiggy'), findsNothing);

    await tester.ensureVisible(find.text('Dining'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dining'));
    await tester.pumpAndSettle();

    expect(find.text('Swiggy'), findsOneWidget);
    expect(find.text('Cafe Central'), findsOneWidget);
    expect(find.textContaining('Rewards earned ₹'), findsNWidgets(2));
    expect(find.textContaining('12/08/2026'), findsOneWidget);
    expect(find.text('Dining · Dinner\nHDFC Millennia'), findsOneWidget);
  });

  testWidgets(
    'combined category and merchant filters match despite merchant casing',
    (tester) async {
      await _pump(
        tester,
        _report(
          spend: 6749,
          byCategory: [
            SpendBreakdownRow(
              label: 'Online Shopping',
              total: Money.fromRupees(6749),
              txnCount: 2,
              categoryId: 'online',
            ),
          ],
          // The report may still carry a differently-cased cached merchant.
          byMerchant: [
            SpendBreakdownRow(
              label: 'Amazon',
              total: Money.fromRupees(5299),
              txnCount: 1,
            ),
          ],
        ),
        transactions: [
          _detailEntry(
            id: 'txn-amazon',
            merchant: 'AMAZON',
            amount: 5299,
            categoryId: 'online',
            categoryName: 'Online Shopping',
            occurredAt: DateTime(2026, 8, 12),
          ),
          _detailEntry(
            id: 'txn-flipkart',
            merchant: 'FLIPKART',
            amount: 1450,
            categoryId: 'online',
            categoryName: 'Online Shopping',
            occurredAt: DateTime(2026, 8, 17),
          ),
        ],
      );

      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Online Shopping').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('All merchants'));
      await tester.tap(find.text('All merchants'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amazon').last);
      await tester.pumpAndSettle();

      final footerTexts = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((widget) => widget.text.toPlainText())
          .join('\n');
      expect(footerTexts, contains('1 matching transaction'));
      expect(footerTexts, contains('₹5,299'));

      await tester.tap(find.text('Show results'));
      await tester.pumpAndSettle();
      expect(find.textContaining('5,299'), findsWidgets);
      expect(find.textContaining('1,450'), findsNothing);
      expect(find.textContaining('6,749'), findsNothing);
      expect(find.text('Filters ·'), findsOneWidget);
    },
  );

  testWidgets('transaction detail load errors are visible and retryable', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSpendQueryProvider.overrideWith(
            (ref) => const SpendReportQuery.preset(SpendPeriod.month),
          ),
          spendReportProvider.overrideWith(
            (ref, query) async => _report(spend: 5299),
          ),
          spendPeriodTransactionsProvider.overrideWith(
            (ref, query) async => throw StateError('details unavailable'),
          ),
        ],
        child: const MaterialApp(home: SpendTrendsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('tapping a spending-mix slice shows its details in the donut', (
    tester,
  ) async {
    await _pump(
      tester,
      _report(
        spend: 500,
        byCategory: [
          SpendBreakdownRow(
            label: 'Dining',
            total: Money.fromRupees(250),
            txnCount: 2,
            categoryId: 'dining',
          ),
          SpendBreakdownRow(
            label: 'Online Shopping',
            total: Money.fromRupees(250),
            txnCount: 1,
            categoryId: 'online',
          ),
        ],
      ),
    );

    final chart = find.byKey(const Key('spending_donut_chart'));
    await tester.ensureVisible(chart);
    await tester.pumpAndSettle();
    final center = tester.getCenter(chart);
    await tester.tapAt(center + const Offset(45, 0));
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: 'selecting a slice should animate its highlight/details',
    );
    await tester.pumpAndSettle();

    final selectedDetail = find.byKey(
      const Key('spending_donut_selected_detail'),
    );
    expect(selectedDetail, findsOneWidget);
    expect(
      tester.widget<Semantics>(selectedDetail).properties.label,
      contains('Dining'),
    );
    expect(
      tester.widget<Semantics>(selectedDetail).properties.label,
      contains('50% of spending'),
    );

    await tester.tap(find.byKey(const Key('spending_donut_center')));
    await tester.pumpAndSettle();
    expect(selectedDetail, findsNothing);
  });

  testWidgets('shows detected payment methods separately from card rows', (
    tester,
  ) async {
    await _pump(
      tester,
      _report(
        spend: 1500,
        byInstrument: [
          InstrumentSpendRow(
            instrument: 'credit_card',
            total: Money.fromRupees(1000),
            txnCount: 1,
          ),
          InstrumentSpendRow(
            instrument: 'upi_bank',
            total: Money.fromRupees(500),
            txnCount: 1,
          ),
        ],
      ),
    );

    expect(find.text('PAYMENT METHOD'), findsOneWidget);
    expect(find.text('Credit cards'), findsOneWidget);
    expect(find.text('UPI from bank account'), findsOneWidget);
  });

  testWidgets('omits the long trend chart from the spending summary', (
    tester,
  ) async {
    await _pump(
      tester,
      _report(
        series: [
          SpendSeriesPoint(
            periodStart: DateTime(2026, 9, 1),
            spend: Money.fromRupees(100),
            rewards: Money.zero(),
            txnCount: 1,
          ),
          SpendSeriesPoint(
            periodStart: DateTime(2026, 10, 1),
            spend: Money.fromRupees(200),
            rewards: Money.zero(),
            txnCount: 1,
          ),
        ],
      ),
    );

    expect(find.text('Sep 26'), findsNothing);
    expect(find.text('Oct 26'), findsNothing);
  });

  testWidgets('gives the monthly comparison chart the available card width', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSpendQueryProvider.overrideWith(
            (ref) => SpendReportQuery.custom(
              from: DateTime(2026, 8, 1),
              to: DateTime(2026, 10, 31),
            ),
          ),
          spendReportProvider.overrideWith((ref, query) async => _report()),
          spendPeriodTransactionsProvider.overrideWith(
            (ref, query) async => const [],
          ),
        ],
        child: const MaterialApp(home: SpendTrendsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final chart = find.descendant(
      of: find.ancestor(
        of: find.text('Monthly comparison'),
        matching: find.byType(CardSummaryPanel),
      ),
      matching: find.byType(CustomPaint),
    );
    expect(chart, findsOneWidget);
    expect(tester.getSize(chart).width, greaterThan(0));
  });

  testWidgets('an empty period shows an explicit zero-spending state', (
    tester,
  ) async {
    await _pump(
      tester,
      SpendReport(
        period: SpendPeriod.month,
        periodStart: DateTime(2026, 8, 1),
        periodEnd: DateTime(2026, 9, 1),
        elapsedFraction: 0.5,
        spend: EntryKindTotals.zero,
        income: EntryKindTotals.zero,
        investment: EntryKindTotals.zero,
        previousSpend: EntryKindTotals.zero,
        byCategory: const [],
        byMerchant: const [],
        byCard: const [],
        byInstrument: const [],
        series: const [],
      ),
    );
    expect(find.text('No spending recorded'), findsOneWidget);
    expect(find.text('₹0.00'), findsOneWidget);
  });

  testWidgets(
    'guest mode says to sign in rather than showing an empty report',
    (tester) async {
      await _pump(tester, null);
      expect(find.textContaining('Sign in'), findsOneWidget);
    },
  );

  testWidgets('switching period refetches for that period', (tester) async {
    final requested = <SpendReportQuery>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSpendQueryProvider.overrideWith(
            (ref) => const SpendReportQuery.preset(SpendPeriod.month),
          ),
          spendReportProvider.overrideWith((ref, period) async {
            requested.add(period);
            return _report();
          }),
        ],
        child: const MaterialApp(home: SpendTrendsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(requested, [
      const SpendReportQuery.preset(SpendPeriod.month),
    ], reason: 'month is the default');

    await tester.tap(find.text('Oct 2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This quarter'));
    await tester.pumpAndSettle();
    // Preset selection is staged in the range sheet; the query changes only
    // after the user confirms it, so this also covers the explicit commit
    // step before expecting a new report request.
    await tester.tap(find.text('Apply range'));
    await tester.pumpAndSettle();
    expect(
      requested,
      contains(const SpendReportQuery.preset(SpendPeriod.quarter)),
    );
  });

  testWidgets('custom dates are shown as the selected range', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSpendQueryProvider.overrideWith(
            (ref) => SpendReportQuery.custom(
              from: DateTime(2026, 8, 3),
              to: DateTime(2026, 8, 14),
            ),
          ),
          spendReportProvider.overrideWith((ref, query) async => _report()),
          spendPeriodTransactionsProvider.overrideWith(
            (ref, query) async => const [],
          ),
        ],
        child: const MaterialApp(home: SpendTrendsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aug 2026'), findsOneWidget);
  });
}
