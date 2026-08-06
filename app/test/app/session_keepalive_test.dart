import 'dart:convert';

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
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a container whose /auth/refresh returns a fresh, countable token.
  /// The refresh interval is squeezed to milliseconds so the test drives real
  /// timers without waiting: the invariant under test is "it rotates on the
  /// interval", not the specific wall-clock duration.
  Future<(ProviderContainer, List<String>)> makeContainer({
    required Duration interval,
    bool refreshFails = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'pandapay_app.access_token': 'initial-access',
      'pandapay_app.refresh_token': 'initial-refresh',
    });
    final store = await TokenStore.load();

    final refreshTokensSeen = <String>[];
    var counter = 0;

    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      refreshTokensSeen.add(body['refresh_token'] as String);
      if (refreshFails) {
        return http.Response(jsonEncode({'error': 'Invalid refresh token'}), 401);
      }
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
      sessionRefreshIntervalProvider.overrideWithValue(interval),
      tokenStoreProvider.overrideWith((ref) async => store),
      authApiProvider.overrideWithValue(
        AuthApi(authBaseUrl: 'http://auth.test', client: client),
      ),
      // Keep startup resume out of the way; this test is only about the
      // periodic keep-alive.
      sessionInitProvider.overrideWith((ref) async {}),
    ]);
    // Resolve the token store future before any tick can read it.
    await container.read(tokenStoreProvider.future);
    return (container, refreshTokensSeen);
  }

  test('rotates the access token on the interval, well inside the 15m TTL',
      () async {
    final (container, _) =
        await makeContainer(interval: const Duration(milliseconds: 20));
    addTearDown(container.dispose);

    container.read(accessTokenProvider.notifier).state = 'initial-access';
    container.read(sessionKeepAliveProvider);

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(container.read(accessTokenProvider), isNot('initial-access'),
        reason: 'token must rotate before auth/ expires it at 15 minutes');
    expect(container.read(accessTokenProvider), startsWith('rotated-access-'));
  });

  test('sends the ROTATED refresh token on each tick, not the original',
      () async {
    // auth/ rotates the refresh token on every /auth/refresh and treats reuse
    // of a spent one as theft — revoking the whole device family. Re-sending
    // the original would log the user out on the second tick.
    final (container, refreshTokensSeen) =
        await makeContainer(interval: const Duration(milliseconds: 20));
    addTearDown(container.dispose);

    container.read(accessTokenProvider.notifier).state = 'initial-access';
    container.read(sessionKeepAliveProvider);

    await Future<void>.delayed(const Duration(milliseconds: 90));

    expect(refreshTokensSeen.length, greaterThanOrEqualTo(2),
        reason: 'expected several ticks in the window');
    expect(refreshTokensSeen.first, 'initial-refresh');
    expect(refreshTokensSeen[1], 'rotated-refresh-1',
        reason: 'must send the newly-issued token, never replay a spent one');
  });

  test('signs the user out cleanly when the refresh token is rejected',
      () async {
    final (container, _) = await makeContainer(
        interval: const Duration(milliseconds: 20), refreshFails: true);
    addTearDown(container.dispose);

    container.read(accessTokenProvider.notifier).state = 'initial-access';
    container.read(sessionKeepAliveProvider);

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(container.read(accessTokenProvider), isNull,
        reason: 'a dead refresh token must sign out, not retry-loop forever');
    final store = await container.read(tokenStoreProvider.future);
    expect(store.refreshToken, isNull, reason: 'stored tokens must be cleared');
  });

  test('does not refresh at all while signed out', () async {
    final (container, refreshTokensSeen) =
        await makeContainer(interval: const Duration(milliseconds: 20));
    addTearDown(container.dispose);

    // accessTokenProvider stays null — nobody is signed in.
    container.read(sessionKeepAliveProvider);

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(refreshTokensSeen, isEmpty,
        reason: 'a signed-out app must not hit /auth/refresh on a timer');
  });
}
