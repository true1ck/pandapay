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
/// one already gates Welcome/Account Choice and is shipped/tested; Settings'
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
        catalogueRepositoryProvider.overrideWithValue(_EmptyCatalogueRepository()),
        categoryRepositoryProvider.overrideWithValue(_EmptyCategoryRepository()),
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

void main() {
  testWidgets('a first-time user (tutorial not seen) sees the coach-mark overlay on Home', (tester) async {
    await _pumpApp(tester, tutorialSeen: false);

    expect(find.text('Type what you\'re about to spend'), findsOneWidget);
  });

  testWidgets('a returning user (tutorial already seen) sees no overlay', (tester) async {
    await _pumpApp(tester, tutorialSeen: true);

    expect(find.text('Type what you\'re about to spend'), findsNothing);
  });

  testWidgets('"Skip tour" dismisses the overlay and persists the flag', (tester) async {
    await _pumpApp(tester, tutorialSeen: false);

    await tester.tap(find.text('Skip tour'));
    await tester.pumpAndSettle();

    expect(find.text('Type what you\'re about to spend'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('pandapay_app.tutorial_seen_v1'), isTrue);
  });

  testWidgets('tapping through all four steps completes the tour and persists the flag', (tester) async {
    await _pumpApp(tester, tutorialSeen: false);

    for (var i = 0; i < 3; i++) {
      expect(find.text('Next'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    // Fourth and final step ends the tour.
    expect(find.text('Done'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Type what you\'re about to spend'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('pandapay_app.tutorial_seen_v1'), isTrue);
  });

  testWidgets('the overlay never blocks navigation — tabs stay tappable underneath', (tester) async {
    await _pumpApp(tester, tutorialSeen: false);

    // The overlay must not intercept nav-bar taps just because it's on top;
    // a user backing out to another tab should still work while the coach
    // marks are up (they simply stop being relevant to a non-Home screen).
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('appShellNavBar')), matching: find.text('Wallet')));
    await tester.pumpAndSettle();

    expect(find.byType(MyCardsScreen), findsOneWidget);
  });
}
