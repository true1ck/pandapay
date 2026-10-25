import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart' show AppRoute;
import 'package:pandapay/features/comparison/comparison_view_screen.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id) =>
    CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa);

void main() {
  testWidgets(
    'home spending card opens Spending from whitespace and donut center',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final report = SpendReport(
        period: SpendPeriod.month,
        periodStart: DateTime(2026, 10, 1),
        periodEnd: DateTime(2026, 11, 1),
        elapsedFraction: 0.5,
        spend: EntryKindTotals(
          total: Money.fromRupees(100),
          txnCount: 2,
          rewards: Money.fromRupees(2),
        ),
        income: EntryKindTotals(
          total: Money.fromRupees(150),
          txnCount: 1,
          rewards: const Money.zero(),
        ),
        investment: EntryKindTotals.zero,
        previousSpend: EntryKindTotals(
          total: Money.fromRupees(50),
          txnCount: 1,
          rewards: const Money.zero(),
        ),
        byCategory: [
          SpendBreakdownRow(
            label: 'Dining',
            total: Money.fromRupees(80),
            txnCount: 1,
            categoryId: 'dining',
          ),
          SpendBreakdownRow(
            label: 'Groceries',
            total: Money.fromRupees(20),
            txnCount: 1,
            categoryId: 'groceries',
          ),
        ],
        byMerchant: const [],
        byCard: const [],
        byInstrument: const [],
        series: const [],
      );

      final router = GoRouter(
        initialLocation: AppRoute.home,
        routes: [
          GoRoute(
            path: AppRoute.home,
            builder: (context, state) => const Scaffold(body: HomeScreen()),
          ),
          GoRoute(
            path: AppRoute.spendTrends,
            builder: (context, state) => const Scaffold(
              body: Center(child: Text('Spending tab opened')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            spendReportProvider.overrideWith((ref, query) async => report),
            rankedRecommendationsProvider.overrideWithValue(
              const AsyncValue.data([]),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final chart = find.byKey(const Key('spending_donut_chart'));
      await tester.scrollUntilVisible(
        chart,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Money in'), findsOneWidget);
      expect(find.text('Total spent'), findsOneWidget);
      expect(find.text('Rewards earned'), findsOneWidget);
      final projection = find.textContaining('On track for');
      expect(projection, findsOneWidget);
      expect(
        tester.getTopLeft(projection).dy,
        greaterThan(tester.getBottomRight(chart).dy),
        reason: 'the projection belongs directly below the chart',
      );

      final center = tester.getCenter(chart);
      // Target the ring itself, not the clear space just outside it (which
      // intentionally opens the full Spending screen).
      await tester.tapAt(center + const Offset(0, -52));
      await tester.pumpAndSettle();
      expect(find.text('Spending tab opened'), findsNothing);

      final selected = tester.widget<Semantics>(
        find.byKey(const Key('spending_donut_selected_detail')),
      );
      expect(selected.properties.label, contains('Dining'));
      expect(selected.properties.label, contains('80% of spending'));

      await tester.tap(find.byKey(const Key('spending_donut_center')));
      await tester.pumpAndSettle();
      expect(
        find.text('Spending tab opened'),
        findsOneWidget,
      );

      // Return to Home so the card-level tap can be verified independently
      // from the donut's center navigation.
      router.go(AppRoute.home);
      await tester.pumpAndSettle();
      final cardOrigin = tester.getTopLeft(
        find.byKey(const Key('home_spend_summary')),
      );
      await tester.tapAt(cardOrigin + const Offset(5, 55));
      await tester.pumpAndSettle();
      expect(find.text('Spending tab opened'), findsOneWidget);
    },
  );

  testWidgets('rank-0 recommendation gets the compact best-card surface', (
    tester,
  ) async {
    final recs = [
      Recommendation(
        card: _card('c1'),
        expectedValue: Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 5.0% on ₹2,400'],
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            AsyncValue.data(recs),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BEST PICK'), findsOneWidget);
    expect(find.text('Estimated rewards'), findsOneWidget);
    expect(find.text('Pay with this card'), findsOneWidget);
  });

  testWidgets('Home quick actions open the tools hub and wallet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: AppRoute.home,
      routes: [
        GoRoute(
          path: AppRoute.home,
          builder: (_, _) => const Scaffold(body: HomeScreen()),
        ),
        GoRoute(
          path: AppRoute.cards,
          builder: (_, _) => const Scaffold(body: Text('Wallet opened')),
        ),
        GoRoute(
          path: AppRoute.toolsHub,
          builder: (_, _) => const Scaffold(body: Text('Tools opened')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            const AsyncValue.data([]),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Quick actions'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final quickActionsRect = tester.getRect(
      find.byKey(const ValueKey('home-quick-actions-layout')),
    );
    final dividerRect = tester.getRect(
      find.byKey(const ValueKey('home-quick-actions-divider')),
    );
    final spendingPromptRect = tester.getRect(
      find.text('What are you paying for?'),
    );
    expect(dividerRect.top - quickActionsRect.bottom, greaterThanOrEqualTo(24));
    expect(
      spendingPromptRect.top - dividerRect.bottom,
      greaterThanOrEqualTo(16),
    );

    expect(find.text('Quick add'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Scan & pay'), findsOneWidget);
    expect(find.text('View cards'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('See all'));
    await tester.pumpAndSettle();
    expect(find.text('Tools opened'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View cards'));
    await tester.tap(find.text('View cards'));
    await tester.pumpAndSettle();
    expect(find.text('Wallet opened'), findsOneWidget);
  });

  test('rent is available as a first-class spending category', () {
    expect(HomeScreen.categoryLabelFor('rent'), 'Rent');
  });

  testWidgets('compact header shows all-time rewards below greeting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeSummaryProvider.overrideWith(
            (ref) async => HomeSummary(
              rewardsThisMonth: Money.fromRupees(547.20),
              rewardsAllTime: Money.fromRupees(547.20),
              transactionCount: 1,
              streakDays: 18,
            ),
          ),
          rankedRecommendationsProvider.overrideWithValue(
            const AsyncValue.data([]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    final greeting = find.textContaining('Good ');
    final allTimeFinder = find.byKey(const ValueKey('home-all-time-rewards'));
    final allTime = tester.getTopLeft(allTimeFinder);
    final streak = tester.getTopLeft(find.text('18-day streak'));
    expect(allTime.dy, greaterThan(tester.getBottomRight(greeting).dy));
    expect(streak.dy, lessThan(allTime.dy));
    expect(find.byKey(const ValueKey('home-monthly-rewards')), findsNothing);
  });

  testWidgets('an override pill navigates to Manual Overrides on tap', (
    tester,
  ) async {
    final recs = [
      Recommendation(
        card: _card('c1'),
        expectedValue: Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 5.0%'],
        isOverride: true,
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            AsyncValue.data(recs),
          ),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Override active'));
    await tester.tap(find.text('Override active'));
    await tester.pumpAndSettle();

    expect(find.text('Manual overrides'), findsOneWidget);
  });

  testWidgets('more wallet cards expand inside the best-pick card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recs = [
      Recommendation(
        card: _card('card-a'),
        expectedValue: Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['A reason one'],
      ),
      Recommendation(
        card: _card('card-b'),
        expectedValue: Money.fromRupees(90),
        confidence: Confidence.estimated,
        reasonLines: const ['B reason one'],
      ),
      Recommendation(
        card: _card('card-c'),
        expectedValue: Money.fromRupees(60),
        confidence: Confidence.estimated,
        reasonLines: const ['C reason one'],
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            AsyncValue.data(recs),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Best from your wallet'), findsOneWidget);
    expect(find.text('Alternative'), findsOneWidget);
    expect(find.textContaining('Card card-b'), findsOneWidget);
    expect(find.textContaining('Card card-c'), findsNothing);

    final showMore = find.text('Show 1 more card');
    await tester.tap(showMore);
    await tester.pumpAndSettle();

    expect(find.textContaining('Card card-c'), findsOneWidget);
  });

  testWidgets('shows a backup-card row for the runner-up when one exists', (
    tester,
  ) async {
    final recs = [
      Recommendation(
        card: _card('c1'),
        expectedValue: Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 5.0%'],
      ),
      Recommendation(
        card: _card('c2'),
        expectedValue: Money.fromRupees(80),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 2.0%'],
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            AsyncValue.data(recs),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alternative'), findsOneWidget);
    expect(find.textContaining('Card c2'), findsWidgets);
  });

  testWidgets(
    'backup row skips an excluded runner-up and shows the next eligible card',
    (tester) async {
      // Regression coverage: the backup row must pick the first ELIGIBLE
      // (non-excluded) lower-ranked card, not literally rank index 1 — if
      // rank 1 is excluded (e.g. cap reached), rank 2 should show instead.
      final recs = [
        Recommendation(
          card: _card('c1'),
          expectedValue: Money.fromRupees(120),
          confidence: Confidence.estimated,
          reasonLines: const ['Base rate 5.0%'],
        ),
        Recommendation(
          card: _card('c2'),
          expectedValue: Money.fromRupees(80),
          confidence: Confidence.estimated,
          reasonLines: const ['Base rate 2.0%'],
          exclusionReason: 'Monthly cap reached',
        ),
        Recommendation(
          card: _card('c3'),
          expectedValue: Money.fromRupees(60),
          confidence: Confidence.estimated,
          reasonLines: const ['Base rate 1.5%'],
        ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rankedRecommendationsProvider.overrideWithValue(
              AsyncValue.data(recs),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: HomeScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alternative'), findsOneWidget);
      expect(find.textContaining('Card c3'), findsWidgets);
    },
  );

  testWidgets('no backup row when every lower-ranked card is excluded', (
    tester,
  ) async {
    final recs = [
      Recommendation(
        card: _card('c1'),
        expectedValue: Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 5.0%'],
      ),
      Recommendation(
        card: _card('c2'),
        expectedValue: Money.fromRupees(80),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 2.0%'],
        exclusionReason: 'Monthly cap reached',
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            AsyncValue.data(recs),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alternative'), findsNothing);
  });

  testWidgets('hero card\'s Details link opens the B4 comparison screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recs = [
      Recommendation(
        card: _card('c1'),
        expectedValue: Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 5.0%'],
      ),
      Recommendation(
        card: _card('c2'),
        expectedValue: Money.fromRupees(80),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 2.0%'],
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            AsyncValue.data(recs),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    // Only the hero (rank 0) card gets the entry point, not every row.
    expect(find.text('Details ↗'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Details ↗'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Details ↗'));
    await tester.pumpAndSettle();

    expect(find.byType(ComparisonViewScreen), findsOneWidget);
    expect(find.text('Compare cards'), findsOneWidget);
  });

  testWidgets(
    'hero card\'s "Pay with this card" button opens Quick Add prefilled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final recs = [
        Recommendation(
          card: _card('c1'),
          expectedValue: Money.fromRupees(120),
          confidence: Confidence.estimated,
          reasonLines: const ['Base rate 5.0%'],
        ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rankedRecommendationsProvider.overrideWithValue(
              AsyncValue.data(recs),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: HomeScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pay with this card'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Pay with this card'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Pay with this card'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(QuickAddScreen), findsOneWidget);
    },
  );
}
