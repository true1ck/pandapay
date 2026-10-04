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
/// screens (Welcome and direct auth entry) didn't exist yet. Covers ui-spec.md
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

Future<void> _pumpApp(
  WidgetTester tester, {
  required bool onboardingComplete,
  required bool signedIn,
}) async {
  SharedPreferences.setMockInitialValues({
    'pandapay_app.onboarding_complete_v1': onboardingComplete,
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
        sessionInitProvider.overrideWith((ref) async {}),
        accessTokenProvider.overrideWith(
          (ref) => signedIn ? 'test-token' : null,
        ),
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
  testWidgets(
    'fresh install (onboarding incomplete) lands on Welcome, not Home',
    (tester) async {
      await _pumpApp(tester, onboardingComplete: false, signedIn: false);

      expect(
        find.text('Know which card to use — before you pay.'),
        findsOneWidget,
      );
      expect(find.byType(HomeScreen), findsNothing);
    },
  );

  testWidgets(
    'a completed device without a session is sent to the account gate',
    (tester) async {
      await _pumpApp(tester, onboardingComplete: true, signedIn: false);

      expect(
        find.text('Know which card to use — before you pay.'),
        findsOneWidget,
      );
      expect(find.byType(HomeScreen), findsNothing);
    },
  );

  testWidgets(
    'welcome exposes direct sign-up and sign-in, never guest mode',
    (tester) async {
      await _pumpApp(tester, onboardingComplete: false, signedIn: false);

      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('How do you want to start?'), findsNothing);
      expect(find.text('Use without an account'), findsNothing);
      expect(find.byType(HomeScreen), findsNothing);
    },
  );

  testWidgets(
    'a signed-in completed account goes Home and cannot return to Welcome',
    (tester) async {
      await _pumpApp(tester, onboardingComplete: true, signedIn: true);

      // Simulate something trying to send the user back to onboarding — e.g.
      // a stale deep link. The guard must bounce it straight back to Home.
      final context = tester.element(find.byType(Scaffold).first);
      GoRouter.of(context).go(AppRoute.welcome);
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(
        find.text('Know which card to use — before you pay.'),
        findsNothing,
      );
    },
  );

  testWidgets('a signed-in new account starts required setup', (tester) async {
    await _pumpApp(tester, onboardingComplete: false, signedIn: true);

    expect(find.text('Set up a few permissions'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
