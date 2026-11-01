import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/auth/product_activation_screen.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/insights/insights_overview.dart'
    show InsightsOverview, insightsOverviewProvider;
import 'package:pandapay/features/insights/payments_due_screen.dart'
    show paymentsDueProvider;
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
  bool sessionLoading = false,
  bool sessionHint = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'pandapay_app.onboarding_complete_v1': onboardingComplete,
    'pandapay_app.session_presence_hint_v1': sessionHint,
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
        sessionInitProvider.overrideWith(
          (ref) =>
              sessionLoading ? Completer<void>().future : Future<void>.value(),
        ),
        userCardsProvider.overrideWith((ref) async => const []),
        myCardsProvider.overrideWith((ref) async => const []),
        transactionsProvider.overrideWith((ref) async => const []),
        utilizationTransactionsProvider.overrideWith((ref) async => const []),
        cardOverridesProvider.overrideWith((ref) async => const []),
        homeSummaryProvider.overrideWith((ref) async => null),
        bankAccountSummariesProvider.overrideWith((ref) async => const []),
        rankedRecommendationsProvider.overrideWith(
          (ref) => const AsyncValue.data(<Recommendation>[]),
        ),
        spendReportProvider.overrideWith((ref, query) async => null),
        insightsOverviewProvider.overrideWith(
          (ref, period) async => InsightsOverview.empty,
        ),
        paymentsDueProvider.overrideWith((ref) async => const []),
        homeEngagementCheckInProvider.overrideWith((ref, day) async {}),
        homeDataRefreshProvider.overrideWith((ref) async {}),
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
  // The signed-in setup route has an indeterminate progress animation, so
  // pump a bounded amount of time for startup/redirects instead of waiting
  // for every frame to settle forever.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
    'fresh install (onboarding incomplete) lands on Welcome, not Home',
    (tester) async {
      await _pumpApp(tester, onboardingComplete: false, signedIn: false);

      expect(find.text('A little less\ncard chaos.'), findsOneWidget);
      expect(find.text('Create account'), findsNothing);
      expect(find.byType(HomeScreen), findsNothing);
    },
  );

  testWidgets(
    'a completed device without a session is sent to the account gate',
    (tester) async {
      await _pumpApp(tester, onboardingComplete: true, signedIn: false);

      expect(find.text('A little less\ncard chaos.'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    },
  );

  testWidgets(
    'a persisted session hint mounts Home while secure storage restores',
    (tester) async {
      await _pumpApp(
        tester,
        onboardingComplete: true,
        signedIn: false,
        sessionLoading: true,
        sessionHint: true,
      );

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('A little less\ncard chaos.'), findsNothing);
    },
  );

  testWidgets('welcome exposes direct sign-up and sign-in, never guest mode', (
    tester,
  ) async {
    await _pumpApp(tester, onboardingComplete: false, signedIn: false);

    await tester.pump(const Duration(milliseconds: 4850));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 6600));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.text('Make every\ncard count.'), findsOneWidget);
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('How do you want to start?'), findsNothing);
    expect(find.text('Use without an account'), findsNothing);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets(
    'a signed-in completed account goes Home and cannot return to Welcome',
    (tester) async {
      await _pumpApp(tester, onboardingComplete: true, signedIn: true);

      // Simulate something trying to send the user back to onboarding — e.g.
      // a stale deep link. The guard must bounce it straight back to Home.
      final context = tester.element(find.byType(Scaffold).first);
      GoRouter.of(context).go(AppRoute.welcome);
      // Home owns an indeterminate progress animation in some deferred
      // sections, so settling every frame can never complete. The redirect
      // itself is synchronous; a bounded pump is the relevant assertion.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Make every\ncard count.'), findsNothing);
    },
  );

  testWidgets(
    'a signed-in new account must pass server activation before setup',
    (tester) async {
      await _pumpApp(tester, onboardingComplete: false, signedIn: true);

      expect(find.byType(ProductActivationScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    },
  );
}
