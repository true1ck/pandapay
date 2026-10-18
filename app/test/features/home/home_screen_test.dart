import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/comparison/comparison_view_screen.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id) =>
    CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa);

void main() {
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

  // Merchant Search moved off Home to You -> Tools when Home was rebuilt to
  // design 01, which has no action-icon row (see ToolsHubScreen). Home's own
  // contract is now that it does NOT carry those icons; the destination
  // itself is covered by the Tools hub's tests.
  testWidgets('Home carries no secondary action icons — design 01 has none', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWithValue(
            const AsyncValue.data([]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Search merchants'), findsNothing);
    expect(find.byTooltip('Quick add a transaction'), findsNothing);
    expect(find.byTooltip('Big-purchase calculator'), findsNothing);
    expect(find.text('What are you paying for?'), findsOneWidget);
  });

  test('rent is available as a first-class spending category', () {
    expect(HomeScreen.categoryLabelFor('rent'), 'Rent');
  });

  testWidgets('rewards header keeps the streak on the greeting row', (
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

    final monthly = tester.getTopLeft(
      find.byKey(const ValueKey('home-monthly-rewards')),
    );
    final allTime = tester.getTopLeft(
      find.byKey(const ValueKey('home-all-time-rewards')),
    );
    final streak = tester.getTopLeft(find.text('18-day streak'));
    expect(allTime.dy, greaterThan(monthly.dy));
    expect(streak.dy, lessThan(monthly.dy));
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

  testWidgets(
    'expand state does not leak across cards when the ranking reorders',
    (tester) async {
      // Regression test: _RecommendationCard is a StatefulWidget holding its
      // own "Why this card?" expand flag. If _RankedList doesn't key each
      // card by a stable identity, ListView.builder reuses the Element at a
      // given index across a reorder and the new occupant inherits the old
      // one's expanded state.
      final cardA = Recommendation(
        card: _card('card-a'),
        expectedValue: Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['A reason one', 'A reason two'],
      );
      final cardB = Recommendation(
        card: _card('card-b'),
        expectedValue: Money.fromRupees(90),
        confidence: Confidence.estimated,
        reasonLines: const ['B reason one', 'B reason two'],
      );

      final recsProvider = StateProvider<List<Recommendation>>(
        (ref) => [cardA, cardB],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            rankedRecommendationsProvider.overrideWith(
              (ref) => AsyncValue.data(ref.watch(recsProvider)),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: HomeScreen())),
        ),
      );
      await tester.pumpAndSettle();

      // The ranked list is collapsed by default. Open it before exercising
      // the per-card expansion state.
      await tester.ensureVisible(find.text('Show 1 more card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show 1 more card'));
      await tester.pumpAndSettle();

      // The compact hero has no per-card disclosure. Expand the detail-rich
      // runner-up and then reorder it into the hero position.
      final cardBWhy = find.byKey(const ValueKey('why-card-b'));
      await tester.ensureVisible(cardBWhy);
      await tester.tap(cardBWhy);
      await tester.pumpAndSettle();
      expect(find.textContaining('B reason two'), findsOneWidget);

      // Reorder: card B now occupies the compact hero position and card A
      // moves to the detail-rich runner-up position.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      container.read(recsProvider.notifier).state = [cardB, cardA];
      await tester.pumpAndSettle();

      // Card A must not inherit card B's expanded disclosure state.
      expect(find.textContaining('A reason two'), findsNothing);
    },
  );

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

    await tester.ensureVisible(find.text('Details ↗'));
    await tester.tap(find.text('Details ↗'));
    await tester.pumpAndSettle();

    expect(find.byType(ComparisonViewScreen), findsOneWidget);
    expect(find.text('Compare cards'), findsOneWidget);
  });

  testWidgets(
    'hero card\'s "Pay with this card" button opens Quick Add prefilled',
    (tester) async {
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

      await tester.ensureVisible(find.text('Pay with this card'));
      await tester.tap(find.text('Pay with this card'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(QuickAddScreen), findsOneWidget);
    },
  );
}
