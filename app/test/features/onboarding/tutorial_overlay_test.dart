import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/cards/my_cards_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task 5 (A11): the first-run tutorial overlay. Deliberately its OWN flag
/// (tutorialSeenProvider), not a reuse of onboardingCompleteProvider — that
/// one already gates Welcome and direct auth entry and is shipped/tested; Settings'
/// future "Replay tutorial" (Task 21) must be able to reset just the coach
/// marks without sending a returning user back through account choice.
class _EmptyCatalogueRepository implements CatalogueRepository {
  @override
  Future<List<CardProduct>> fetchCatalogue() async => const [];
}

class _EmptyCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [];
}

Future<void> _pumpApp(WidgetTester tester, {required bool tutorialSeen}) async {
  SharedPreferences.setMockInitialValues({
    'pandapay_app.onboarding_complete_v1': true,
    'pandapay_app.tutorial_seen_v1': tutorialSeen,
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(
          _EmptyCatalogueRepository(),
        ),
        categoryRepositoryProvider.overrideWithValue(
          _EmptyCategoryRepository(),
        ),
        userCardsProvider.overrideWith((ref) async => const []),
        sessionInitProvider.overrideWith((ref) async {}),
        sessionKeepAliveProvider.overrideWith((ref) {}),
        accessTokenProvider.overrideWith((ref) => 'test-token'),
      ],
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: ref.watch(goRouterProvider),
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpBriefly(WidgetTester tester) async {
  // Step changes include shell navigation and target measurement; give those
  // async transitions time to finish before looking for the enabled action.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpUntilTourAction(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    if (find.text('Next').evaluate().isNotEmpty ||
        find.text('Explore Insights').evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('a first-time user sees the first coach-mark on Home', (
    tester,
  ) async {
    await _pumpApp(tester, tutorialSeen: false);

    expect(find.text('Make every card count.'), findsOneWidget);
  });

  testWidgets('a returning user (tutorial already seen) sees no overlay', (
    tester,
  ) async {
    await _pumpApp(tester, tutorialSeen: true);

    expect(find.text('Make every card count.'), findsNothing);
  });

  testWidgets('"Skip tour" dismisses the overlay and persists the flag', (
    tester,
  ) async {
    await _pumpApp(tester, tutorialSeen: false);

    await tester.tap(find.text('Skip tour'));
    await _pumpBriefly(tester);

    expect(find.text('Type what you\'re about to spend'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('pandapay_app.tutorial_seen_v1'), isTrue);
  });

  testWidgets(
    'tapping through all five steps completes the tour and persists the flag',
    (tester) async {
      await _pumpApp(tester, tutorialSeen: false);

      for (var i = 0; i < 4; i++) {
        await _pumpUntilTourAction(tester);
        if (find.text('Explore Insights').evaluate().isNotEmpty) break;
        expect(find.text('Next'), findsOneWidget);
        await tester.tap(find.text('Next'));
        await _pumpBriefly(tester);
        expect(find.text('${i + 2} of 5'), findsOneWidget);
      }
      // The fifth and final step offers an Insights hand-off.
      await _pumpUntilTourAction(tester);
      expect(find.text('Explore Insights'), findsOneWidget);
      await tester.tap(find.text('Explore Insights'));
      await _pumpBriefly(tester);

      expect(find.text('Make every card count.'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('pandapay_app.tutorial_seen_v1'), isTrue);
    },
  );

  testWidgets('the modal tutorial keeps navigation blocked until dismissed', (
    tester,
  ) async {
    await _pumpApp(tester, tutorialSeen: false);

    // Tutorial steps are modal: a highlighted control or nav destination
    // cannot change routes behind the active coach mark.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('appShellNavBar')),
        matching: find.text('Wallet'),
      ),
    );
    await _pumpBriefly(tester);

    expect(find.byType(MyCardsScreen), findsNothing);
    expect(find.text('Make every card count.'), findsOneWidget);
  });
}
