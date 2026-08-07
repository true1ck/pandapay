import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/comparison/comparison_view_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _card(String id) => CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa);

void main() {
  testWidgets('sorts rows by ₹ value descending by default, and toggles on tap', (tester) async {
    final recs = [
      Recommendation(card: _card('low'), expectedValue: Money.fromRupees(50), confidence: Confidence.estimated, reasonLines: const ['Base rate 1.0%']),
      Recommendation(card: _card('high'), expectedValue: Money.fromRupees(150), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0% — cap headroom']),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: ComparisonViewScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final cardTiles = tester.widgetList<Text>(find.textContaining('Card '));
    expect(cardTiles.first.data, 'Card high'); // higher ₹ value first by default

    await tester.tap(find.text('Card')); // sort header
    await tester.pumpAndSettle();
    final afterNameSort = tester.widgetList<Text>(find.textContaining('Card '));
    // Switching to a new sort column always starts descending (see
    // _onSort), and by plain string comparison "Card low" > "Card high"
    // (l > h), so descending name order puts "low" first.
    expect(afterNameSort.first.data, 'Card low');
  });

  testWidgets('a row expands to show every reasonLine', (tester) async {
    final recs = [
      Recommendation(card: _card('c1'), expectedValue: Money.fromRupees(100), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0%', 'Cap headroom: ₹500 remaining']),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: ComparisonViewScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Cap headroom'), findsNothing);
    await tester.tap(find.text('Card c1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cap headroom'), findsOneWidget);
  });

  testWidgets('expand state does not leak across a re-sort (stable per-row keying)', (tester) async {
    final recs = [
      Recommendation(card: _card('alpha'), expectedValue: Money.fromRupees(50), confidence: Confidence.estimated, reasonLines: const ['Base rate 1.0%', 'Alpha-only detail line']),
      Recommendation(card: _card('zeta'), expectedValue: Money.fromRupees(150), confidence: Confidence.estimated, reasonLines: const ['Base rate 5.0%', 'Zeta-only detail line']),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
        child: const MaterialApp(home: ComparisonViewScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Default sort: zeta (₹150) first, alpha (₹50) second. Expand the
    // second row (alpha).
    await tester.tap(find.text('Card alpha'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Alpha-only detail line'), findsOneWidget);
    expect(find.textContaining('Zeta-only detail line'), findsNothing);

    // Sort by name ascending: alpha < zeta, so alpha moves to the top row,
    // zeta to the bottom row. If expand state were tracked by list index
    // rather than card identity, the top row (now alpha, same as before)
    // wouldn't reveal anything new here — but if it were keyed wrong the
    // *other* direction (zeta inheriting alpha's old expanded state at the
    // index it used to occupy) would show. Assert identity, not index:
    // alpha's own detail should still be expanded, zeta's should not.
    await tester.tap(find.text('Card')); // sort by name, descending default
    await tester.pumpAndSettle();
    await tester.tap(find.text('Card')); // tap again -> ascending
    await tester.pumpAndSettle();

    expect(find.textContaining('Alpha-only detail line'), findsOneWidget);
    expect(find.textContaining('Zeta-only detail line'), findsNothing);
  });
}
