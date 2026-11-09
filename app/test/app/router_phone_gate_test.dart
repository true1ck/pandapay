import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/auth/add_phone_screen.dart';
import 'package:pandapay/features/auth/phone_gate_provider.dart';
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
  required bool phoneNeeded,
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
        foreignPaymentsProvider.overrideWith((ref) async => const []),
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
        phoneGateProvider.overrideWith((ref) {
          final controller = PhoneGateController(ref);
          if (phoneNeeded) controller.needs();
          return controller;
        }),
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
  testWidgets('a signed-in account that needs a phone is held on Add phone', (tester) async {
    await _pumpApp(tester, onboardingComplete: true, signedIn: true, phoneNeeded: true);
    expect(find.byType(AddPhoneScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('saving the phone releases the gate and the person reaches Home', (tester) async {
    await _pumpApp(tester, onboardingComplete: true, signedIn: true, phoneNeeded: true);
    expect(find.byType(AddPhoneScreen), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(AddPhoneScreen)));
    container.read(phoneGateProvider.notifier).satisfied();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AddPhoneScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('an account that does not need a phone never sees the screen', (tester) async {
    await _pumpApp(tester, onboardingComplete: true, signedIn: true, phoneNeeded: false);
    expect(find.byType(AddPhoneScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a signed-out person goes to Welcome whatever the gate says', (tester) async {
    await _pumpApp(tester, onboardingComplete: true, signedIn: false, phoneNeeded: true);
    expect(find.byType(AddPhoneScreen), findsNothing);
  });

  testWidgets('a new sign-up that needs a phone sees Add phone before product activation', (tester) async {
    await _pumpApp(tester, onboardingComplete: false, signedIn: true, phoneNeeded: true);
    expect(find.byType(AddPhoneScreen), findsOneWidget);
    expect(find.byType(ProductActivationScreen), findsNothing);
  });
}
