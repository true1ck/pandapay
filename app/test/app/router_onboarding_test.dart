import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tasks 4-6: the redirect guard deferred out of Task 3 because its target
/// screens (Welcome, Account Choice) didn't exist yet. Covers ui-spec.md
/// A3's explicit "no nagging later" requirement: onboarding, once completed,
/// must never resurface — not even by manually navigating back to /welcome.
class _EmptyCatalogueRepository implements CatalogueRepository {
  @override
  Future<List<CardProduct>> fetchCatalogue() async => const [];
}

class _EmptyCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [];
}

Future<void> _pumpApp(WidgetTester tester, {required bool onboardingComplete}) async {
  SharedPreferences.setMockInitialValues({
    'pandapay_app.onboarding_complete_v1': onboardingComplete,
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
  // Splash, then session/onboarding resolution, then the redirect settling —
  // all async and chained, so settle rather than guess a pump count.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fresh install (onboarding incomplete) lands on Welcome, not Home', (tester) async {
    await _pumpApp(tester, onboardingComplete: false);

    expect(find.text('Know which card to use — before you pay.'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('a device that already finished onboarding goes straight to Home', (tester) async {
    await _pumpApp(tester, onboardingComplete: true);

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Know which card to use — before you pay.'), findsNothing);
  });

  testWidgets(
      'choosing "use without an account" continues through Permissions + Tour to Add Your '
      'First Card, NOT Home (design 15/27-29 sit between Account Choice and A7; onboarding '
      'still only completes at the end of A10)', (tester) async {
    await _pumpApp(tester, onboardingComplete: false);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('Use without an account'), findsOneWidget);

    await tester.tap(find.text('Use without an account'));
    await tester.pumpAndSettle();

    // Design 15: permissions screen, all-optional, no grant required to
    // continue.
    expect(find.text('Set up a few permissions'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // Design 27-29: the 3-step tour, Skip available every step but this
    // walks it forward instead to also cover Next.
    expect(find.text('Your cards already pay you back.'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Point it at the QR, get an answer.'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('See what you kept, and what slipped.'), findsOneWidget);
    await tester.tap(find.text('Add my cards'));
    await tester.pumpAndSettle();

    // Lands on A7 (Add Your First Card), not Home — the empty test
    // catalogue renders its app-bar default title.
    expect(find.text('Add your cards'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    // Onboarding must NOT be marked complete yet — A10 is now the only
    // place that happens.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('pandapay_app.onboarding_complete_v1'), isNot(isTrue));
  });

  testWidgets('once onboarding is complete, Welcome is unreachable even by direct navigation',
      (tester) async {
    await _pumpApp(tester, onboardingComplete: true);

    // Simulate something trying to send the user back to onboarding — e.g.
    // a stale deep link. The guard must bounce it straight back to Home.
    final context = tester.element(find.byType(Scaffold).first);
    GoRouter.of(context).go(AppRoute.welcome);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Know which card to use — before you pay.'), findsNothing);
  });
}
