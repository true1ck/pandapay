import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/settings/account_settings_screen.dart' show biometricLockProvider;
import 'package:pandapay/features/system/biometric_lock_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Router-level coverage for account_settings_screen.dart's "Biometric
/// lock" toggle enforcement, same shape as router_app_status_test.dart's
/// S5/S6 coverage — pumps the REAL goRouterProvider (not a synthetic test
/// router) so this exercises router.dart's actual redirect logic, not a
/// re-implementation of it.
class _EmptyCatalogueRepository implements CatalogueRepository {
  @override
  Future<List<CardProduct>> fetchCatalogue() async => const [];
}

class _EmptyCategoryRepository implements CategoryRepository {
  @override
  Future<List<SpendCategory>> fetchCategories() async => const [];
}

/// [settleAfter] is deliberately `pump()` a bounded number of times rather
/// than `pumpAndSettle()` when the test expects to land ON
/// BiometricLockScreen: that screen's initState kicks off a REAL
/// LocalAuthentication platform-channel call (no mock plugin handler
/// registered here — biometric_lock_screen_test.dart covers that
/// interaction separately, with an injected fake), which never resolves
/// in this test environment and would make pumpAndSettle hang forever.
/// These tests only care what router.dart's redirect decided to show, not
/// how that screen's own authentication attempt then behaves.
Future<void> _pumpApp(
  WidgetTester tester, {
  required bool biometricLockEnabled,
  List<Override> extraOverrides = const [],
  bool settleAfter = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'pandapay_app.onboarding_complete_v1': true,
    'biometric_lock_enabled_v1': biometricLockEnabled,
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_EmptyCatalogueRepository()),
        categoryRepositoryProvider.overrideWithValue(_EmptyCategoryRepository()),
        sessionInitProvider.overrideWith((ref) async {}),
        ...extraOverrides,
      ],
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: ref.watch(goRouterProvider),
        ),
      ),
    ),
  );
  if (settleAfter) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  testWidgets('the toggle off reaches Home normally, never showing the lock screen', (tester) async {
    await _pumpApp(tester, biometricLockEnabled: false);

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(BiometricLockScreen), findsNothing);
  });

  testWidgets('the toggle on, not yet unlocked this session, blocks every route with BiometricLockScreen', (
    tester,
  ) async {
    await _pumpApp(tester, biometricLockEnabled: true, settleAfter: false);

    expect(find.byType(BiometricLockScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('the toggle on but already unlocked this session reaches Home, not the lock screen', (
    tester,
  ) async {
    await _pumpApp(
      tester,
      biometricLockEnabled: true,
      extraOverrides: [biometricUnlockedProvider.overrideWith((ref) => true)],
    );

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(BiometricLockScreen), findsNothing);
  });

  // A scenario about flipping biometricUnlockedProvider mid-session and
  // confirming the redirect reacts live via _RouterRefreshNotifier was
  // deliberately not added here — router_app_status_test.dart doesn't test
  // that class of live transition either, only static states.
  //
  // The test below covers a DIFFERENT live transition that is not
  // optional: it's a regression test for a real bug found by running the
  // app on a device. biometricLockProvider (BiometricLockController)
  // starts at AsyncValue.loading() and only resolves once its
  // SharedPreferences read completes — on a device this genuinely races
  // the router's first redirect evaluation, so on a cold start the app
  // sits at Home for a beat before the toggle's real value comes back.
  // _RouterRefreshNotifier used to listen only to biometricUnlockedProvider,
  // not biometricLockProvider itself, so a LATER change to
  // biometricLockProvider's state — cold-start resolution included — never
  // triggered a re-evaluation, and the app sailed straight through to Home.
  // Confirmed on a real cold start with the toggle already on from a
  // previous session. Drives the controller's own real setEnabled() rather
  // than a synthetic subclass, so this exercises the exact API
  // account_settings_screen.dart's toggle calls.
  testWidgets('turning the toggle on live locks the app without any other navigation happening', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'pandapay_app.onboarding_complete_v1': true,
      'biometric_lock_enabled_v1': false,
    });
    final container = ProviderContainer(
      overrides: [
        catalogueRepositoryProvider.overrideWithValue(_EmptyCatalogueRepository()),
        categoryRepositoryProvider.overrideWithValue(_EmptyCategoryRepository()),
        sessionInitProvider.overrideWith((ref) async {}),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) =>
              MaterialApp.router(theme: AppTheme.light(), routerConfig: ref.watch(goRouterProvider)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(BiometricLockScreen), findsNothing);

    // Same call account_settings_screen.dart's SwitchListTile makes.
    await container.read(biometricLockProvider.notifier).setEnabled(true);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(BiometricLockScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
