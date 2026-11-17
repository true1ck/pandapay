import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_routes.dart';
import 'package:pandapay/features/quickadd/quick_add_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/error_handling.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_join_route.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/app/tutorial_keys.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/notification_preferences_repository.dart';
import 'package:pandapay/features/account/account_screen.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart'
    show paymentsDueProvider;
import 'package:pandapay/features/insights/insights_overview.dart'
    show InsightsOverview, insightsOverviewProvider;
import 'package:pandapay/features/insights/insights_hub_screen.dart';
import 'package:pandapay/features/account/avatar_providers.dart';
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
        // The real loader keeps an 8 s fetch timeout pending in fake time,
        // which Insights starts as soon as a test lets it settle.
        notificationPreferencesProvider.overrideWith(
          (ref) async => NotificationPreferences.defaults,
        ),
        bankAccountSummariesProvider.overrideWith((ref) async => const []),
        cardOverridesProvider.overrideWith((ref) async => const []),
        duplicateCandidatesProvider.overrideWith((ref) async => const []),
        needsReviewCountProvider.overrideWith((ref) async => 0),
        profileProvider.overrideWith((ref) async => null),
        avatarProvider.overrideWith((ref) async => null),
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
  testWidgets('system back on Wallet, Insights and You returns to Home', (
    tester,
  ) async {
    await _pumpApp(tester);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    for (final path in [AppRoute.cards, AppRoute.insights, AppRoute.account]) {
      scope.read(goRouterProvider).go(path);
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget, reason: 'back on $path');
    }
  });

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

  // iOS hands a custom-scheme link to the router untouched, so the host
  // (`split`) is not part of the path and `/join/<token>` matched no route:
  // tapping "Open it" on the invite page ended on "That page couldn't be found".
  testWidgets(
    'pandapay://split/join/<token> opens the Join screen, not the not-found page',
    (tester) async {
      await _pumpApp(tester, shared: true);
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      final token = List.filled(43, 'a').join();
      scope.read(goRouterProvider).go('pandapay://split/join/$token');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(AppRouteErrorScreen), findsNothing);
      final join = tester.widget<SharedJoinRoute>(find.byType(SharedJoinRoute));
      expect(join.token, token);
    },
  );

  testWidgets('the https split invite link opens the Join screen too', (
    tester,
  ) async {
    await _pumpApp(tester, shared: true);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final token = List.filled(43, 'b').join();
    scope
        .read(goRouterProvider)
        .go('https://pandapay.pandapath.live/split/join/$token');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AppRouteErrorScreen), findsNothing);
    expect(
      tester.widget<SharedJoinRoute>(find.byType(SharedJoinRoute)).token,
      token,
    );
  });

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

  group('swiping between the main tabs', () {
    String location(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    ).read(goRouterProvider).routeInformationProvider.value.uri.path;

    // Drag from the upper part of the page, away from the nav bar and the
    // voice button, the way a thumb would. [dx] < 0 is a swipe left.
    Future<void> swipe(WidgetTester tester, double dx) async {
      await tester.flingFrom(const Offset(400, 160), Offset(dx, 0), 1500);
      await tester.pumpAndSettle();
    }

    Future<void> tapNav(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('appShellNavBar')),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('swiping left walks Home, Wallet, Insights, You in the order '
        'of the bottom bar, and swiping right walks back', (tester) async {
      await _pumpApp(tester);
      expect(location(tester), AppRoute.home);
      expect(find.byType(HomeScreen), findsOneWidget);

      await swipe(tester, -500);
      expect(location(tester), AppRoute.cards);
      expect(find.byType(MyCardsScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);

      await swipe(tester, -500);
      expect(location(tester), AppRoute.insights);
      expect(find.byType(InsightsHubScreen), findsOneWidget);

      await swipe(tester, -500);
      expect(location(tester), AppRoute.account);
      expect(find.byType(AccountScreen), findsOneWidget);

      await swipe(tester, 500);
      expect(location(tester), AppRoute.insights);
      await swipe(tester, 500);
      expect(location(tester), AppRoute.cards);
      await swipe(tester, 500);
      expect(location(tester), AppRoute.home);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('there is nothing to swipe to before Home or after You', (
      tester,
    ) async {
      await _pumpApp(tester);
      await swipe(tester, 500);
      expect(location(tester), AppRoute.home);
      expect(find.byType(HomeScreen), findsOneWidget);

      await tapNav(tester, 'You');
      expect(location(tester), AppRoute.account);
      await swipe(tester, -500);
      expect(location(tester), AppRoute.account);
      expect(find.byType(AccountScreen), findsOneWidget);
    });

    testWidgets('a short drag that falls back stays on the same tab', (
      tester,
    ) async {
      await _pumpApp(tester);
      final gesture = await tester.startGesture(const Offset(400, 160));
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(location(tester), AppRoute.home);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(MyCardsScreen), findsNothing);
    });

    testWidgets('the bottom bar still jumps straight to a tab without '
        'building the ones in between', (tester) async {
      await _pumpApp(tester);

      await tapNav(tester, 'You');
      expect(location(tester), AppRoute.account);
      expect(find.byType(AccountScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(MyCardsScreen), findsNothing);
      expect(find.byType(InsightsHubScreen), findsNothing);

      await tapNav(tester, 'Home');
      expect(location(tester), AppRoute.home);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(AccountScreen), findsNothing);
    });

    testWidgets('a swipe and the bottom bar agree on where you are', (
      tester,
    ) async {
      await _pumpApp(tester);
      await swipe(tester, -500);
      await tapNav(tester, 'Insights');
      expect(location(tester), AppRoute.insights);
      expect(find.byType(InsightsHubScreen), findsOneWidget);

      await swipe(tester, 500);
      expect(location(tester), AppRoute.cards);
      expect(find.byType(MyCardsScreen), findsOneWidget);
    });

    testWidgets('tapping a tab while a swipe is still settling is not undone '
        'by the swipe', (tester) async {
      await _pumpApp(tester);
      await tester.flingFrom(const Offset(400, 160), const Offset(-500, 0), 1500);
      // Mid-settle: do not wait for the swipe to finish before the tap.
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('appShellNavBar')),
          matching: find.text('You'),
        ),
      );
      await tester.pumpAndSettle();

      expect(location(tester), AppRoute.account);
      expect(find.byType(AccountScreen), findsOneWidget);
    });

    testWidgets('system back after a swipe returns to Home', (tester) async {
      await _pumpApp(tester);
      await swipe(tester, -500);
      await swipe(tester, -500);
      expect(location(tester), AppRoute.insights);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(location(tester), AppRoute.home);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a page pushed over a tab is not swiped away', (tester) async {
      await _pumpApp(tester);
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      scope.read(goRouterProvider).go(AppRoute.splits);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('appShellNavBar')), findsNothing);

      await swipe(tester, -500);
      expect(location(tester), AppRoute.splits);
    });
  });
}
