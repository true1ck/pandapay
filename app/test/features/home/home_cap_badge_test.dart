import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Home is where the app makes its promise, so it is where a spent cap has
/// to be visible.
///
/// Before this, the verdict card printed the card's HEADLINE rate beside
/// BEST PICK regardless of cap state: a "10% on Online" card whose ₹3,000
/// monthly cap was already spent still read "10% on Online" while actually
/// paying its 1% base rate. Nothing on screen warned the user, and they'd
/// follow the recommendation and earn a fifth of what the badge implied.
CardProduct _card(String id) => CardProduct(id: id, name: 'Card $id', network: CardNetwork.visa);

Future<void> _pumpHome(WidgetTester tester, List<Recommendation> recs) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [rankedRecommendationsProvider.overrideWithValue(AsyncValue.data(recs))],
      child: const MaterialApp(home: Scaffold(body: HomeScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

/// A 10%-headline card that actually paid its 1% base rate because the cap
/// is gone — expectedValue and the breakdown agree on ₹10 of ₹1,000.
Recommendation _capReached() => Recommendation(
      card: _card('capped'),
      expectedValue: Money.fromRupees(10),
      confidence: Confidence.estimated,
      reasonLines: const ['Cap already reached — this card now earns its base rate of 1.0% here'],
      effectiveRatePerRupee: 0.10,
      breakdown: RecommendationBreakdown(
        baseRatePerRupee: 0.10,
        baseValue: Money.fromRupees(100),
        capStatus: CapStatus.reached,
        effectiveRatePerRupee: 0.01,
        capHeadroom: const Money.zero(),
        capNote: 'Cap reached',
      ),
    );

void main() {
  testWidgets('a spent cap is called out on the verdict card', (tester) async {
    await _pumpHome(tester, [_capReached()]);

    expect(find.text('BEST PICK'), findsOneWidget);
    expect(find.textContaining('Cap spent'), findsOneWidget);
  });

  testWidgets('the rate beside BEST PICK is what the card pays, not what it advertises', (tester) async {
    await _pumpHome(tester, [_capReached()]);

    expect(
      find.textContaining('1%'),
      findsWidgets,
      reason: 'the card pays its 1% base rate once the cap is spent',
    );
    expect(
      find.textContaining('10%'),
      findsNothing,
      reason: 'printing the headline 10% here is a promise the card will not keep',
    );
  });

  testWidgets('a card whose cap is partly left says how much is left', (tester) async {
    final rec = Recommendation(
      card: _card('partial'),
      expectedValue: Money.fromRupees(55),
      confidence: Confidence.estimated,
      reasonLines: const ['₹500 at 10.0% (cap headroom) + ₹500 at 1.0% (post-cap)'],
      effectiveRatePerRupee: 0.10,
      breakdown: RecommendationBreakdown(
        baseRatePerRupee: 0.10,
        baseValue: Money.fromRupees(100),
        capStatus: CapStatus.partiallyConsumed,
        effectiveRatePerRupee: 0.055,
        capHeadroom: Money.fromRupees(500),
        capNote: 'Only ₹500.00 of cap left',
      ),
    );
    await _pumpHome(tester, [rec]);

    expect(find.textContaining('of cap left'), findsOneWidget);
  });

  testWidgets('an uncapped card shows its headline rate and no cap note', (tester) async {
    // The common case must be untouched — no badge, no rate rewriting.
    final rec = Recommendation(
      card: _card('plain'),
      expectedValue: Money.fromRupees(50),
      confidence: Confidence.estimated,
      reasonLines: const ['Base rate 5.0% on ₹1,000'],
      effectiveRatePerRupee: 0.05,
      breakdown: RecommendationBreakdown(
        baseRatePerRupee: 0.05,
        baseValue: Money.fromRupees(50),
        capStatus: CapStatus.none,
        effectiveRatePerRupee: 0.05,
      ),
    );
    await _pumpHome(tester, [rec]);

    expect(find.textContaining('Cap spent'), findsNothing);
    expect(find.textContaining('of cap left'), findsNothing);
    expect(find.textContaining('5%'), findsWidgets);
  });
}
