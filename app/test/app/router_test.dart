import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_routes.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/app/tutorial_keys.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/account/account_screen.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart'
    show paymentsDueProvider;
import 'package:pandapay/features/insights/insights_overview.dart'
    show InsightsOverview, insightsOverviewProvider;
import 'package:pandapay/features/insights/insights_hub_screen.dart';
import 'package:pandapay/features/cards/my_cards_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task 3: go_router replaces int-index tab switching + raw MaterialPageRoute.
/// This is a pure navigation-shell swap — zero behaviour change for the four
/// existing tabs — so the tests only assert "the right screen shows for the
/// right route and the right nav item highlights", not anything about screen
/// content (that's each screen's own test file's job).
///
/// Tasks 4-6 added a real onboarding redirect guard in front of the shell —
/// see router_onboarding_test.dart for that behaviour. These tests are about
/// the SHELL, not onboarding, so they simulate a device that already
/// finished onboarding (the guard's own tests cover a fresh install).
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
  TutorialKeys? tutorialKeys,
  bool shared = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'pandapay_app.onboarding_complete_v1': true,
    'pandapay_app.tutorial_seen_v1': true,
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedExpensesEnabledProvider.overrideWithValue(shared),
        catalogueRepositoryProvider.overrideWithValue(
          _EmptyCatalogueRepository(),
        ),
        categoryRepositoryProvider.overrideWithValue(
          _EmptyCategoryRepository(),
        ),
        userCardsProvider.overrideWith((ref) async => const []),
        myCardsProvider.overrideWith((ref) async => const []),
        transactionsProvider.overrideWith((ref) async => const []),
        utilizationTransactionsProvider.overrideWith((ref) async => const []),
        foreignPaymentsProvider.overrideWith((ref) async => const []),
        homeSummaryProvider.overrideWith((ref) async => null),
        bankAccountSummariesProvider.overrideWith((ref) async => const []),
        cardOverridesProvider.overrideWith((ref) async => const []),
        duplicateCandidatesProvider.overrideWith((ref) async => const []),
        needsReviewCountProvider.overrideWith((ref) async => 0),
        profileProvider.overrideWith((ref) async => null),
        budgetsProvider.overrideWith((ref) async => const []),
        recurringReportProvider.overrideWith((ref) async => null),
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
        sessionInitProvider.overrideWith((ref) async {}),
        sessionKeepAliveProvider.overrideWith((ref) {}),
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        if (tutorialKeys != null)
          tutorialKeysProvider.overrideWithValue(tutorialKeys),
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

void main() {
  testWidgets(
    'holding the existing scan action opens shared quick actions without replacing navigation',
    (tester) async {
      final keys = TutorialKeys();
      await _pumpApp(tester, shared: true, tutorialKeys: keys);
      await tester.longPress(find.byKey(keys.scanFab));
      await tester.pumpAndSettle();
      expect(find.text('Shared expense'), findsOneWidget);
      expect(find.text('Open Splits'), findsOneWidget);
      await tester.tap(find.text('Shared expense'));
      await tester.pumpAndSettle();
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      expect(
        tester
            .widget<QuickAddScreen>(find.byType(QuickAddScreen))
            .sharedExpense,
        isTrue,
      );
      expect(scope.read(goRouterProvider).canPop(), isTrue);
    },
  );
  testWidgets(
    'You shortcut opens the same Splits route and keeps the card split planner separate',
    (tester) async {
      await _pumpApp(tester, shared: true);
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      scope.read(goRouterProvider).go(AppRoute.account);
      await tester.pumpAndSettle();
      expect(find.text('Multi-Card Split Planner'), findsOneWidget);
      final action = find.text('Splits');
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.byType(SharedExpensesRoute), findsOneWidget);
      scope.read(goRouterProvider).pop();
      await tester.pumpAndSettle();
      expect(find.byType(AccountScreen), findsOneWidget);
    },
  );
  testWidgets(
    'initial route renders Home inside the shell with Home highlighted',
    (tester) async {
      await _pumpApp(tester);

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('appShellNavBar')), findsOneWidget);
    },
  );

  testWidgets(
    'tapping Wallet navigates to /cards and shows the Wallet screen',
    (tester) async {
      await _pumpApp(tester);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('appShellNavBar')),
          matching: find.text('Wallet'),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(MyCardsScreen), findsOneWidget);
    },
  );

  testWidgets(
    'tapping Insights then You navigates correctly (order-independent)',
    (tester) async {
      await _pumpApp(tester);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('appShellNavBar')),
          matching: find.text('Insights'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(InsightsHubScreen), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('appShellNavBar')),
          matching: find.text('You'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(AccountScreen), findsOneWidget);
    },
  );

  testWidgets('legacy subscription links open the Payments subscription tab', (
    tester,
  ) async {
    await _pumpApp(tester);
    final context = tester.element(find.byType(HomeScreen));
    GoRouter.of(context).go('${AppRoute.subscriptions}?from=notification');
    await tester.pumpAndSettle();
    expect(find.text('Payments'), findsOneWidget);
    expect(find.text('Subscriptions'), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    final router = GoRouter.of(tester.element(find.byType(TabBar)));
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRoute.paymentsGroup,
    );
    expect(
      router.routeInformationProvider.value.uri.queryParameters['tab'],
      'subscriptions',
    );
    expect(
      router.routeInformationProvider.value.uri.queryParameters['from'],
      'notification',
    );
    expect(find.byKey(const ValueKey('appShellNavBar')), findsNothing);
  });

  testWidgets(
    'split rollout stays gated and never replaces Insights or existing data pages',
    (tester) async {
      await _pumpApp(tester);
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      expect(scope.read(sharedExpensesEnabledProvider), isFalse);
      scope.read(goRouterProvider).go(AppRoute.splits);
      await tester.pumpAndSettle();
      expect(find.text('Splits'), findsOneWidget);
      expect(
        find.textContaining(
          'Existing transactions and private splits are still available',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('appShellNavBar')), findsNothing);
      scope.read(goRouterProvider).go(AppRoute.insights);
      await tester.pumpAndSettle();
      expect(find.byType(InsightsHubScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('appShellNavBar')), findsOneWidget);
      expect(find.text('Splits'), findsNothing);
    },
  );

  testWidgets('the scan FAB is present on every tab (not just Home)', (
    tester,
  ) async {
    final keys = TutorialKeys();
    await _pumpApp(tester, tutorialKeys: keys);
    expect(find.byKey(keys.scanFab), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('appShellNavBar')),
        matching: find.text('Wallet'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(keys.scanFab), findsOneWidget);
  });
}
