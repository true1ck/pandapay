import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/comparison/comparison_view_screen.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id) => CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa);

void main() {
  testWidgets('rank-0 recommendation gets hero styling and a "Why this card?" toggle', (tester) async {
    final recs = [
      Recommendation(
        card: _card('c1'),
        expectedValue: Money.fromRupees(120),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 5.0% on ₹2,400', 'Cap headroom: ₹8,600 remaining'],
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BEST'), findsOneWidget);
    expect(find.text('Why this card?'), findsOneWidget);
    expect(find.textContaining('Cap headroom'), findsNothing);

    await tester.tap(find.text('Why this card?'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Cap headroom'), findsOneWidget);
    expect(find.text('Hide the full breakdown'), findsOneWidget);
  });

  testWidgets('an override pill navigates to Manual Overrides on tap', (tester) async {
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
          rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs)),
          cardOverridesProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Override active'));
    await tester.pumpAndSettle();

    expect(find.text('Manual overrides'), findsOneWidget);
  });

  testWidgets('expand state does not leak across cards when the ranking reorders', (tester) async {
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

    final recsProvider = StateProvider<List<Recommendation>>((ref) => [cardA, cardB]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rankedRecommendationsProvider.overrideWith((ref) => AsyncValue.data(ref.watch(recsProvider))),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    // Expand card A (currently at rank 0) — both cards have a toggle, so
    // scope to the first one found (rank order == visual top-to-bottom
    // order, so this is card A's).
    await tester.tap(find.text('Why this card?').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('A reason two'), findsOneWidget);

    // Reorder: card B now occupies rank 0 (previously held by card A).
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
    container.read(recsProvider.notifier).state = [cardB, cardA];
    await tester.pumpAndSettle();

    // Card B (new rank 0) must render collapsed, not inherit the expanded
    // state that used to belong to whatever card was previously at that
    // index — its own second reason line must stay hidden until tapped.
    expect(find.textContaining('B reason two'), findsNothing);
    expect(find.text('Why this card?'), findsWidgets);
  });

  testWidgets('shows a backup-card row for the runner-up when one exists', (tester) async {
    final recs = [
      Recommendation(card: _card('c1'), expectedValue: Money.fromRupees(120), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0%']),
      Recommendation(card: _card('c2'), expectedValue: Money.fromRupees(80), confidence: Confidence.estimated, reasonLines: const ['Base rate 2.0%']),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('If not accepted:'), findsOneWidget);
    expect(find.textContaining('Card c2'), findsWidgets);
  });

  testWidgets('backup row skips an excluded runner-up and shows the next eligible card', (tester) async {
    // Regression coverage: the backup row must pick the first ELIGIBLE
    // (non-excluded) lower-ranked card, not literally rank index 1 — if
    // rank 1 is excluded (e.g. cap reached), rank 2 should show instead.
    final recs = [
      Recommendation(card: _card('c1'), expectedValue: Money.fromRupees(120), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0%']),
      Recommendation(
        card: _card('c2'),
        expectedValue: Money.fromRupees(80),
        confidence: Confidence.estimated,
        reasonLines: const ['Base rate 2.0%'],
        exclusionReason: 'Monthly cap reached',
      ),
      Recommendation(card: _card('c3'), expectedValue: Money.fromRupees(60), confidence: Confidence.estimated, reasonLines: const ['Base rate 1.5%']),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('If not accepted:'), findsOneWidget);
    expect(find.textContaining('Card c3'), findsWidgets);
  });

  testWidgets('no backup row when every lower-ranked card is excluded', (tester) async {
    final recs = [
      Recommendation(card: _card('c1'), expectedValue: Money.fromRupees(120), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0%']),
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
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('If not accepted:'), findsNothing);
  });

  testWidgets('hero card\'s "Compare all cards" button opens the B4 comparison screen', (tester) async {
    final recs = [
      Recommendation(card: _card('c1'), expectedValue: Money.fromRupees(120), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0%']),
      Recommendation(card: _card('c2'), expectedValue: Money.fromRupees(80), confidence: Confidence.estimated, reasonLines: const ['Base rate 2.0%']),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    // Only the hero (rank 0) card gets the entry point, not every row.
    expect(find.text('Compare all cards'), findsOneWidget);

    await tester.tap(find.text('Compare all cards'));
    await tester.pumpAndSettle();

    expect(find.byType(ComparisonViewScreen), findsOneWidget);
    expect(find.text('Compare cards'), findsOneWidget);
  });
}
