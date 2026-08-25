import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/insights/caps_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task 7. Insights Hub is the single entry point to Caps, Milestones,
/// Billing Float and Activity — no Utilization tile yet (Task 9's
/// credit_limit_inr migration hasn't landed, and a tile pointing at a
/// screen that can't render anything real would be worse than no tile).
class _FakeCatalogueRepository implements CatalogueRepository {
  final List<CardProduct> cards;
  _FakeCatalogueRepository(this.cards);
  @override
  Future<List<CardProduct>> fetchCatalogue() async => cards;
}

class _EmptyCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [];
}

Future<void> _pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'pandapay_app.onboarding_complete_v1': true});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_FakeCatalogueRepository(const [])),
        categoryRepositoryProvider.overrideWithValue(_EmptyCategoryRepository()),
        userCardsProvider.overrideWith((ref) async => const []),
        sessionInitProvider.overrideWith((ref) async {}),
      ],
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: ref.watch(goRouterProvider),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// `ensureVisible`, not `scrollUntilVisible`.
///
/// The tile grid is a `shrinkWrap: true` `GridView` nested in the tab's
/// scroll view, so every tile is built and findable from first pump no
/// matter where the viewport is. `scrollUntilVisible` sees the finder match
/// immediately and returns without scrolling anything, leaving the tile at
/// y≈718 in a 600pt-tall test surface — where the tap silently misses.
/// `ensureVisible` actually walks up to the scrollable ancestor and brings
/// the element on screen.
Future<void> _reveal(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _openInsights(WidgetTester tester) async {
  await _pumpApp(tester);
  await tester.tap(
    find.descendant(of: find.byKey(const ValueKey('appShellNavBar')), matching: find.text('Insights')),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the grid offers six grouped insights, not eighteen', (tester) async {
    // The grid had grown one tile per shipped screen and most of them
    // answered slices of the same few questions. These six are the whole
    // list now; anything that used to be its own tile is a tab behind one
    // of them (see GroupedInsightScreen).
    await _openInsights(tester);

    // Every tile needs a scroll, not just the later ones: design 04's
    // content (earned hero, category bars, missed/best pair) sits above the
    // grid, so no tile is in the initial viewport any more.
    for (final label in const [
      'Limits & perks',
      'Spending',
      'Budgets',
      'Rewards',
      'Payments',
      'Subscriptions',
    ]) {
      await _reveal(tester, label);
      expect(find.text(label), findsOneWidget, reason: '$label tile should be reachable by scrolling');
    }
  });

  testWidgets('the tiles that were merged away are gone from the grid', (tester) async {
    // Guards the consolidation itself: if one of these reappears as its own
    // tile, the grid has started regrowing and the merge has been undone.
    await _openInsights(tester);
    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await tester.pumpAndSettle();

    for (final gone in const [
      'Caps & Limits',
      'Milestones',
      'Fee Waivers',
      'Credit Utilization',
      'Billing Float',
      'Due Dates',
      'Lounge Access',
      'Savings Report',
      'Portfolio Audit',
      'Missed Opportunities',
      'Spending Overview',
      'All Activity',
      'My Contributions',
    ]) {
      expect(find.text(gone), findsNothing, reason: '$gone should live behind a grouped tile now');
    }
  });

  testWidgets('leads with the earned figure, not the tile grid', (tester) async {
    await _openInsights(tester);

    // The point of the rebuild: the tab answers "what did I earn" on
    // arrival. With no transactions that is the empty state, but it is
    // still content rather than a wall of navigation tiles.
    expect(find.text('Insights'), findsWidgets);
    expect(find.text('This month'), findsOneWidget);
    expect(find.text('Nothing to report yet'), findsOneWidget);
  });

  testWidgets('Limits & perks opens the grouped screen, landing on Caps', (tester) async {
    // Caps is still one tap away — it is the first tab of the group, so the
    // merge cost no depth for the most-used view while putting milestones,
    // fee waivers and lounge quotas one tap from it instead of three.
    await _openInsights(tester);

    await _reveal(tester, 'Limits & perks');
    await tester.tap(find.text('Limits & perks'));
    await tester.pumpAndSettle();

    expect(find.byType(CapsScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    for (final tab in const ['Caps', 'Milestones', 'Fee waivers', 'Lounge']) {
      expect(find.text(tab), findsWidgets, reason: 'the group must expose its siblings as tabs');
    }
  });
}
