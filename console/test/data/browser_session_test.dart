import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/data/token_store.dart';

void main() {
  test(
    'browser storage erases legacy bearer credentials and never saves new ones',
    () async {
      SharedPreferences.setMockInitialValues({
        'pandapay_console.access_token': 'old-access',
        'pandapay_console.refresh_token': 'old-refresh',
        'unrelated': 'kept',
      });
      final store = await TokenStore.load(browserSessions: true);
      expect(store.accessToken, isNull);
      expect(store.refreshToken, isNull);
      await store.save(
        accessToken: 'must-not-persist',
        refreshToken: 'must-not-persist',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pandapay_console.access_token'), isNull);
      expect(prefs.getString('pandapay_console.refresh_token'), isNull);
      expect(prefs.getString('unrelated'), 'kept');
    },
  );
  test(
    'browser email OTP stores only an in-memory session marker and CSRF',
    () async {
      final requests = <http.Request>[];
      final api = AuthApi(
        authBaseUrl: 'https://unused.test',
        browserSessions: true,
        browserBaseUrl: 'https://console.test/browser',
        client: MockClient((request) async {
          requests.add(request);
          expect(request.headers['X-Console-Request'], '1');
          expect(request.headers.containsKey('Authorization'), isFalse);
          if (request.url.path.endsWith('request-email-otp')) {
            return http.Response('{"success":true}', 200);
          }
          return http.Response(
            '{"authenticated":true,"csrfToken":"csrf-example"}',
            200,
          );
        }),
      );
      await api.requestEmailOtp('operator@example.test');
      final tokens = await api.verifyEmailOtp(
        'operator@example.test',
        '1234',
        'console-web',
      );
      expect(tokens.accessToken, 'console-browser-session');
      expect(tokens.refreshToken, isNull);
      expect(api.browserCsrf, 'csrf-example');
      expect(requests.map((r) => r.url.path), [
        '/browser/request-email-otp',
        '/browser/verify-email-otp',
      ]);
    },
  );
  test(
    'browser reload uses the cookie session endpoint without a refresh token body',
    () async {
      final api = AuthApi(
        authBaseUrl: 'https://unused.test',
        browserSessions: true,
        browserBaseUrl: 'https://console.test/browser',
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/browser/session');
          expect(request.body, isEmpty);
          return http.Response(
            '{"authenticated":true,"csrfToken":"new-csrf"}',
            200,
          );
        }),
      );
      expect((await api.refresh('')).accessToken, 'console-browser-session');
      expect(api.browserCsrf, 'new-csrf');
    },
  );
  test(
    'browser admin transport forwards CSRF instead of bearer credentials',
    () async {
      final api = AdminApi(
        apiBaseUrl: 'https://console.test/browser/api',
        accessToken: 'ui-marker',
        csrfToken: () => 'csrf-example',
        client: MockClient((request) async {
          expect(
            request.url.path,
            '/browser/api/admin/referrals/holds/enrollment',
          );
          expect(request.headers['X-Console-Request'], '1');
          expect(request.headers['X-CSRF-Token'], 'csrf-example');
          expect(request.headers.containsKey('Authorization'), isFalse);
          return http.Response(
            jsonEncode({
              'hold': {'paused': true},
            }),
            200,
          );
        }),
      );
      expect(
        (await api.setReferralHold(
          scope: 'enrollment',
          paused: true,
          reason: 'review',
        ))['paused'],
        isTrue,
      );
    },
  );
  test('browser logout calls server and clears CSRF after success', () async {
    final requests = <http.Request>[];
    final api = AuthApi(
      authBaseUrl: 'https://unused.test',
      browserSessions: true,
      browserBaseUrl: 'https://console.test/browser',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          request.url.path.endsWith('/logout')
              ? '{"ok":true}'
              : '{"authenticated":true,"csrfToken":"csrf"}',
          200,
        );
      }),
    );
    await api.refresh('');
    await api.logout();
    expect(requests.last.url.path, '/browser/logout');
    expect(requests.last.headers['X-CSRF-Token'], 'csrf');
    expect(api.browserCsrf, isNull);
  });
  test('browser session failures retain retry distinction', () async {
    for (final status in [401, 503]) {
      final api = AuthApi(
        authBaseUrl: 'https://unused.test',
        browserSessions: true,
        browserBaseUrl: 'https://console.test/browser',
        client: MockClient(
          (_) async => http.Response('{"error":"unavailable"}', status),
        ),
      );
      await expectLater(
        api.refresh(''),
        throwsA(
          isA<AdminApiException>().having(
            (e) => e.statusCode,
            'status',
            status,
          ),
        ),
      );
    }
  });
}
