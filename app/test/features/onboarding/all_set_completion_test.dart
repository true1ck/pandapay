import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/data/product_access_api.dart';
import 'package:pandapay/features/home/home_screen.dart';
import 'package:pandapay/features/onboarding/all_set_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProductAccess implements ProductAccessRepository {
  bool fail = false;
  int calls = 0;
  Completer<void>? pending;

  @override
  Future<void> completeOnboarding() async {
    calls++;
    if (pending != null) await pending!.future;
    if (fail) throw Exception('offline');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('successful completion navigates from All Set to Home', (
    tester,
  ) async {
    final result = await _pumpFlow(tester);
    await tester.tap(find.text('Take me Home'));
    await tester.pumpAndSettle();

    expect(
      result.read(goRouterProvider).routeInformationProvider.value.uri.path,
      AppRoute.home,
    );
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(AllSetScreen), findsNothing);
    expect(result.read(onboardingCompleteProvider).valueOrNull, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('pandapay_app.onboarding_complete_v1'), isTrue);
  });

  testWidgets('failure stays on setup with a visible retry, then completes', (
    tester,
  ) async {
    final api = _FakeProductAccess()..fail = true;
    final result = await _pumpFlow(tester, api: api);
    await tester.tap(find.text('Take me Home'));
    await tester.pumpAndSettle();

    expect(find.byType(AllSetScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey('onboarding-completion-error')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('onboarding-completion-error')),
          )
          .data,
      isNotEmpty,
    );
    expect(result.read(onboardingCompleteProvider).valueOrNull, isFalse);
    expect(find.textContaining('try again'), findsOneWidget);

    api.fail = false;
    await tester.tap(find.text('Take me Home'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(api.calls, 2);
  });

  testWidgets(
    'pending completion shows busy state and prevents duplicate calls',
    (tester) async {
      final pending = Completer<void>();
      final api = _FakeProductAccess()..pending = pending;
      final container = await _pumpFlow(tester, api: api);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      // Exercise even the callback retained before the disabled rebuild.
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(api.calls, 1);
      expect(find.text('Finishing setup…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Finishing setup…'));
      await tester.pump(const Duration(seconds: 1));
      expect(api.calls, 1);
      expect(container.read(onboardingCompleteProvider).valueOrNull, isFalse);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    },
  );

  testWidgets(
    'real API timeout leaves setup and data intact and permits retry',
    (tester) async {
      final stalled = Completer<http.Response>();
      var calls = 0;
      final client = MockClient((request) {
        calls++;
        expect(request.url.path, '/onboarding/complete');
        expect(request.headers['authorization'], 'Bearer test-token');
        return calls == 1
            ? stalled.future
            : Future.value(http.Response('{"completed":true}', 200));
      });
      addTearDown(client.close);
      final container = await _pumpFlow(
        tester,
        api: ProductAccessApi(
          apiBaseUrl: 'https://api.test',
          accessToken: 'test-token',
          client: client,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wallet-sentinel', 'keep');
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      await tester.tap(find.text('Take me Home'));
      await tester.pump();
      expect(calls, 1);
      expect(find.text('Finishing setup…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 14));
      expect(find.text('Finishing setup…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byType(AllSetScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onboarding-completion-error')),
        findsOneWidget,
      );
      expect(
        find.textContaining('check your connection and try again'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(container.read(onboardingCompleteProvider).valueOrNull, isFalse);
      expect(container.read(accessTokenProvider), 'test-token');
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);

      // A late acknowledgement must not complete the timed-out attempt locally.
      stalled.complete(http.Response('{"completed":true}', 200));
      await tester.pump();
      expect(container.read(onboardingCompleteProvider).valueOrNull, isFalse);
      await tester.tap(find.text('Take me Home'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(container.read(accessTokenProvider), 'test-token');
      expect(prefs.getString('wallet-sentinel'), 'keep');
    },
  );

  testWidgets(
    'recovers from required_terms_missing via terms consent and navigates to Home',
    (tester) async {
      final requestedUrls = <String>[];
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requestedUrls.add(request.url.path);
        requests.add(request);
        if (request.url.path == '/onboarding/complete') {
          if (requestedUrls.where((p) => p == '/onboarding/complete').length ==
              1) {
            return http.Response(
              jsonEncode({'error': 'required_terms_missing'}),
              409,
            );
          }
          return http.Response(jsonEncode({'completed': true}), 200);
        }
        if (request.url.path == '/consents') {
          return http.Response(jsonEncode({'status': 'created'}), 201);
        }
        return http.Response('Not Found', 404);
      });
      addTearDown(client.close);

      final container = await _pumpFlow(
        tester,
        api: ProductAccessApi(
          apiBaseUrl: 'https://api.test',
          accessToken: 'test-token',
          client: client,
        ),
      );

      expect(find.byType(AllSetScreen), findsOneWidget);
      await tester.tap(find.text('Take me Home'));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(AllSetScreen), findsNothing);
      expect(container.read(onboardingCompleteProvider).valueOrNull, isTrue);

      expect(requestedUrls, [
        '/onboarding/complete',
        '/consents',
        '/onboarding/complete',
      ]);
      final consentBody = jsonDecode(requests[1].body) as Map<String, dynamic>;
      expect(consentBody['purpose'], 'terms');
      expect(consentBody['granted'], isTrue);
      expect(consentBody['policyVersion'], appProductTermsVersion);
      expect(consentBody['sourceScreen'], 'onboarding_complete');
    },
  );

  testWidgets(
    'unresolved required_terms_missing displays friendly error and allows retry',
    (tester) async {
      var consentSucceeds = false;
      final client = MockClient((request) async {
        if (request.url.path == '/onboarding/complete') {
          if (!consentSucceeds) {
            return http.Response(
              jsonEncode({'error': 'required_terms_missing'}),
              409,
            );
          }
          return http.Response(jsonEncode({'completed': true}), 200);
        }
        if (request.url.path == '/consents') {
          if (!consentSucceeds) {
            return http.Response(jsonEncode({'error': 'consent_failed'}), 500);
          }
          return http.Response(jsonEncode({'status': 'created'}), 201);
        }
        return http.Response('Not Found', 404);
      });
      addTearDown(client.close);

      final container = await _pumpFlow(
        tester,
        api: ProductAccessApi(
          apiBaseUrl: 'https://api.test',
          accessToken: 'test-token',
          client: client,
        ),
      );

      await tester.tap(find.text('Take me Home'));
      await tester.pumpAndSettle();

      // Screen stays on AllSetScreen
      expect(find.byType(AllSetScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(container.read(onboardingCompleteProvider).valueOrNull, isFalse);

      // Shows friendly message, NOT raw snake_case
      expect(
        find.byKey(const ValueKey('onboarding-completion-error')),
        findsOneWidget,
      );
      expect(
        find.text('Please accept the terms to complete setup.'),
        findsOneWidget,
      );
      expect(find.textContaining('required_terms_missing'), findsNothing);

      // Now server allows consent and completion
      consentSucceeds = true;
      await tester.tap(find.text('Take me Home'));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(AllSetScreen), findsNothing);
      expect(container.read(onboardingCompleteProvider).valueOrNull, isTrue);
    },
  );
}

Future<ProviderContainer> _pumpFlow(
  WidgetTester tester, {
  ProductAccessRepository? api,
}) async {
  final fakeApi = api ?? _FakeProductAccess();
  final container = ProviderContainer(
    overrides: [
      productAccessApiProvider.overrideWithValue(fakeApi),
      ownedCardsWithProductProvider.overrideWithValue(
        const AsyncValue.data([]),
      ),
      sessionInitProvider.overrideWith((ref) async {}),
      sessionKeepAliveProvider.overrideWith((ref) {}),
      smsBackgroundFlushProvider.overrideWith((ref) {}),
      accessTokenProvider.overrideWith((ref) => 'test-token'),
      activationVerifiedNamespaceProvider.overrideWith(
        (ref) => ref.watch(cacheNamespaceProvider),
      ),
      appStatusProvider.overrideWith((ref) async => null),
      catalogueProvider.overrideWith((ref) async => []),
      categoriesProvider.overrideWith((ref) async => []),
      userCardsProvider.overrideWith((ref) async => []),
      userCardsRepositoryProvider.overrideWithValue(null),
      spendReportsRepositoryProvider.overrideWithValue(null),
    ],
  );
  final router = container.read(goRouterProvider);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    container.dispose();
  });
  container.read(onboardingCompleteProvider);
  await container.read(sessionInitProvider.future);
  await tester.pump();
  router.go(AppRoute.trackingSetup);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Set up later'));
  await tester.pumpAndSettle();
  return container;
}
