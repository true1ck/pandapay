import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Task 2: prove the session actually survives past auth/'s 15-minute access
/// TTL.
///
/// sessionInitProvider only ever refreshes ONCE, at app start. Without
/// sessionKeepAliveProvider, an app left open longer than JWT_ACCESS_TTL kept
/// showing "signed in" while every API call underneath 401'd — the failure
/// mode this covers.
///
/// Runs entirely inside FakeAsync rather than real Future.delayed waits: an
/// earlier version used real millisecond delays, which passed in isolation
/// but flaked under full-suite load (CPU contention shifts real-time
/// scheduling enough to miss a tick window). FakeAsync's virtual clock
/// removes wall-clock timing from the equation entirely.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rotates the access token on the interval, well inside the 15m TTL', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({
        'pandapay_app.access_token': 'initial-access',
        'pandapay_app.refresh_token': 'initial-refresh',
      });

      var counter = 0;
      final client = MockClient((req) async {
        counter++;
        return http.Response(
          jsonEncode({
            'access_token': 'rotated-access-$counter',
            'refresh_token': 'rotated-refresh-$counter',
          }),
          200,
        );
      });

      final container = ProviderContainer(overrides: [
        sessionRefreshIntervalProvider.overrideWithValue(const Duration(minutes: 10)),
        tokenStoreProvider.overrideWith((ref) => TokenStore.load()),
        authApiProvider.overrideWithValue(AuthApi(authBaseUrl: 'http://auth.test', client: client)),
        sessionInitProvider.overrideWith((ref) async {}),
      ]);
      addTearDown(container.dispose);

      // Resolve the token store future synchronously under the fake clock
      // before starting the keep-alive timer, mirroring real startup order.
      async.elapse(Duration.zero);

      container.read(accessTokenProvider.notifier).state = 'initial-access';
      container.read(sessionKeepAliveProvider);

      async.elapse(const Duration(minutes: 11));

      expect(container.read(accessTokenProvider), isNot('initial-access'),
          reason: 'token must rotate before auth/ expires it at 15 minutes');
      expect(container.read(accessTokenProvider), startsWith('rotated-access-'));
    });
  });

  test('sends the ROTATED refresh token on each tick, not the original', () {
    fakeAsync((async) {
      // auth/ rotates the refresh token on every /auth/refresh and treats
      // reuse of a spent one as theft — revoking the whole device family.
      // Re-sending the original would log the user out on the second tick.
      SharedPreferences.setMockInitialValues({
        'pandapay_app.access_token': 'initial-access',
        'pandapay_app.refresh_token': 'initial-refresh',
      });

      final refreshTokensSeen = <String>[];
      var counter = 0;
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        refreshTokensSeen.add(body['refresh_token'] as String);
        counter++;
        return http.Response(
          jsonEncode({
            'access_token': 'rotated-access-$counter',
            'refresh_token': 'rotated-refresh-$counter',
          }),
          200,
        );
      });

      final container = ProviderContainer(overrides: [
        sessionRefreshIntervalProvider.overrideWithValue(const Duration(minutes: 10)),
        tokenStoreProvider.overrideWith((ref) => TokenStore.load()),
        authApiProvider.overrideWithValue(AuthApi(authBaseUrl: 'http://auth.test', client: client)),
        sessionInitProvider.overrideWith((ref) async {}),
      ]);
      addTearDown(container.dispose);

      async.elapse(Duration.zero);
      container.read(accessTokenProvider.notifier).state = 'initial-access';
      container.read(sessionKeepAliveProvider);

      async.elapse(const Duration(minutes: 21));

      expect(refreshTokensSeen.length, greaterThanOrEqualTo(2),
          reason: 'expected two ticks in a 21-minute window on a 10-minute interval');
      expect(refreshTokensSeen.first, 'initial-refresh');
      expect(refreshTokensSeen[1], 'rotated-refresh-1',
          reason: 'must send the newly-issued token, never replay a spent one');
    });
  });

  test('signs the user out cleanly when the refresh token is rejected', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({
        'pandapay_app.access_token': 'initial-access',
        'pandapay_app.refresh_token': 'initial-refresh',
      });

      final client = MockClient(
        (req) async => http.Response(jsonEncode({'error': 'Invalid refresh token'}), 401),
      );

      final container = ProviderContainer(overrides: [
        sessionRefreshIntervalProvider.overrideWithValue(const Duration(minutes: 10)),
        tokenStoreProvider.overrideWith((ref) => TokenStore.load()),
        authApiProvider.overrideWithValue(AuthApi(authBaseUrl: 'http://auth.test', client: client)),
        sessionInitProvider.overrideWith((ref) async {}),
      ]);
      addTearDown(container.dispose);

      async.elapse(Duration.zero);
      container.read(accessTokenProvider.notifier).state = 'initial-access';
      container.read(sessionKeepAliveProvider);
      TokenStore? capturedStore;
      container.read(tokenStoreProvider.future).then((s) => capturedStore = s);
      async.elapse(Duration.zero);

      async.elapse(const Duration(minutes: 11));

      expect(container.read(accessTokenProvider), isNull,
          reason: 'a dead refresh token must sign out, not retry-loop forever');
      expect(capturedStore?.refreshToken, isNull, reason: 'stored tokens must be cleared');
    });
  });

  test('does not refresh at all while signed out', () {
    fakeAsync((async) {
      SharedPreferences.setMockInitialValues({
        'pandapay_app.access_token': 'initial-access',
        'pandapay_app.refresh_token': 'initial-refresh',
      });

      final refreshTokensSeen = <String>[];
      final client = MockClient((req) async {
        refreshTokensSeen.add('called');
        return http.Response(jsonEncode({'access_token': 'x', 'refresh_token': 'y'}), 200);
      });

      final container = ProviderContainer(overrides: [
        sessionRefreshIntervalProvider.overrideWithValue(const Duration(minutes: 10)),
        tokenStoreProvider.overrideWith((ref) => TokenStore.load()),
        authApiProvider.overrideWithValue(AuthApi(authBaseUrl: 'http://auth.test', client: client)),
        sessionInitProvider.overrideWith((ref) async {}),
      ]);
      addTearDown(container.dispose);

      async.elapse(Duration.zero);
      // accessTokenProvider stays null — nobody is signed in.
      container.read(sessionKeepAliveProvider);

      async.elapse(const Duration(minutes: 30));

      expect(refreshTokensSeen, isEmpty,
          reason: 'a signed-out app must not hit /auth/refresh on a timer');
    });
  });
}
