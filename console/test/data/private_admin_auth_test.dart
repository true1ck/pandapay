import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/data/private_admin_auth.dart';

Future<void> verifyPendingEmail(PrivateAdminAuthApi api) async {
  await api.requestEmailOtp('operator@example.test');
  await expectLater(
    api.verifyEmailOtp('operator@example.test', '123456', 'device'),
    throwsA(isA<AdminApiException>()),
  );
  expect(api.enrollmentRequired, true);
}

void main() {
  test(
    'email verification cannot create a session before successful passkey verification',
    () async {
      final calls = <String>[];
      final api = PrivateAdminAuthApi(
        client: MockClient((r) async {
          calls.add(r.url.path);
          expect(r.headers['X-Admin-Protocol'], '1');
          expect(r.headers.containsKey('Authorization'), false);
          if (r.url.path.endsWith('/start')) {
            return http.Response(
              jsonEncode({'version': 1, 'loginId': 'challenge'}),
              202,
            );
          }
          if (r.url.path.endsWith('/verify-email')) {
            return http.Response(
              jsonEncode({
                'version': 1,
                'next': 'webauthn',
                'options': {'challenge': 'test'},
              }),
              200,
            );
          }
          fail('A cancelled passkey must not call session completion');
        }),
        passkey: (options, {required register}) async =>
            throw StateError('cancelled'),
      );
      await api.requestEmailOtp('operator@example.test');
      await expectLater(
        api.verifyEmailOtp('operator@example.test', '123456', 'device'),
        throwsStateError,
      );
      expect(api.browserCsrf, isNull);
      expect(calls.length, 2);
    },
  );
  test(
    'completed session returns a UI marker and CSRF, never a bearer token',
    () async {
      final api = PrivateAdminAuthApi(
        client: MockClient((r) async {
          final body = r.url.path.endsWith('/start')
              ? {'version': 1, 'loginId': 'challenge'}
              : r.url.path.endsWith('/verify-email')
              ? {'version': 1, 'next': 'webauthn', 'options': {}}
              : {
                  'version': 1,
                  'authenticated': true,
                  'csrfToken': 'csrf',
                  'admin': {
                    'email': 'operator@example.test',
                    'permissions': ['reference.read'],
                  },
                };
          return http.Response(jsonEncode(body), 200);
        }),
        passkey: (options, {required register}) async => {'id': 'credential'},
      );
      await api.requestEmailOtp('operator@example.test');
      final token = await api.verifyEmailOtp(
        'operator@example.test',
        '123456',
        'device',
      );
      expect(token.accessToken, 'console-browser-session');
      expect(token.refreshToken, isNull);
      expect(api.browserCsrf, 'csrf');
    },
  );
  test('enrollment response does not sign in the operator', () async {
    final api = PrivateAdminAuthApi(
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.path.endsWith('/start')
                ? {'version': 1, 'loginId': 'pending'}
                : {'version': 1, 'next': 'enrollment'},
          ),
          200,
        ),
      ),
    );
    await api.requestEmailOtp('operator@example.test');
    await expectLater(
      api.verifyEmailOtp('operator@example.test', '123456', 'device'),
      throwsA(isA<AdminApiException>()),
    );
    expect(api.enrollmentRequired, true);
    expect(api.browserCsrf, isNull);
  });
  test(
    'an incompatible gateway protocol fails without legacy fallback',
    () async {
      var calls = 0;
      final api = PrivateAdminAuthApi(
        client: MockClient((r) async {
          calls++;
          return http.Response('{"loginId":"old"}', 200);
        }),
      );
      await expectLater(
        api.requestEmailOtp('operator@example.test'),
        throwsA(isA<AdminApiException>()),
      );
      expect(calls, 1);
    },
  );

  test('malformed enrollment grants never reach the gateway', () async {
    var requests = 0;
    final api = PrivateAdminAuthApi(
      client: MockClient((r) async {
        requests++;
        return http.Response(
          jsonEncode(
            r.url.path.endsWith('/start')
                ? {'version': 1, 'loginId': 'pending'}
                : {'version': 1, 'next': 'enrollment'},
          ),
          200,
        );
      }),
    );
    await verifyPendingEmail(api);
    for (final grant in ['', '12', '123456', 'a' * 42, '${'a' * 42}+']) {
      await expectLater(api.enroll(grant), throwsA(isA<AdminApiException>()));
    }
    expect(requests, 2);
    expect(api.browserCsrf, isNull);
  });

  for (final failure in [
    (
      body: '{"version":1,"error":"preauth_required"}',
      status: 403,
      message:
          'This sign-in attempt is no longer valid. Start again to request a new email code.',
    ),
    (
      body: '{"version":1,"error":"enrollment_denied"}',
      status: 403,
      message:
          'Enrollment was not authorized. Your grant or email verification may have expired. Start again with a fresh grant and email code.',
    ),
    (
      body: '<html>private upstream diagnostic</html>',
      status: 503,
      message: 'The admin service is temporarily unavailable. Please retry.',
    ),
  ]) {
    test(
      'enrollment failure ${failure.status}/${failure.body} is actionable before any passkey prompt',
      () async {
        final api = PrivateAdminAuthApi(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/start')) {
              return http.Response('{"version":1,"loginId":"pending"}', 202);
            }
            if (r.url.path.endsWith('/verify-email')) {
              return http.Response('{"version":1,"next":"enrollment"}', 200);
            }
            expect(r.url.path, '/browser/enrollment/options');
            return http.Response(failure.body, failure.status);
          }),
          passkey: (_, {required register}) async =>
              fail('A rejected grant must not open a passkey prompt'),
        );
        await verifyPendingEmail(api);
        await expectLater(
          api.enroll('a' * 43),
          throwsA(
            isA<AdminApiException>()
                .having((e) => e.message, 'message', failure.message)
                .having((e) => e.statusCode, 'status', failure.status),
          ),
        );
        expect(api.browserCsrf, isNull);
        expect(api.enrollmentRequired, true);
      },
    );
  }

  test(
    'cancelled registration is distinct from a rejected grant and never verifies a credential',
    () async {
      final paths = <String>[];
      final api = PrivateAdminAuthApi(
        client: MockClient((r) async {
          paths.add(r.url.path);
          final data = switch (r.url.path) {
            '/browser/login/start' => {'version': 1, 'loginId': 'pending'},
            '/browser/login/verify-email' => {
              'version': 1,
              'next': 'enrollment',
            },
            '/browser/enrollment/options' => {'version': 1, 'options': {}},
            _ => throw StateError(
              'Cancelled registration must not be verified',
            ),
          };
          return http.Response(jsonEncode(data), 200);
        }),
        passkey: (_, {required register}) async {
          expect(register, true);
          throw StateError('browser prompt cancelled');
        },
      );
      await verifyPendingEmail(api);
      await expectLater(
        api.enroll('a' * 43),
        throwsA(
          isA<AdminApiException>().having(
            (e) => e.message,
            'message',
            'Passkey registration was cancelled or unavailable. Retry in Chrome and complete its security prompt.',
          ),
        ),
      );
      expect(paths.length, 3);
      expect(api.browserCsrf, isNull);
      expect(api.enrollmentRequired, true);
    },
  );

  test(
    'an unconfirmed enrollment response cannot complete the setup step',
    () async {
      final api = PrivateAdminAuthApi(
        client: MockClient((r) async {
          final data = switch (r.url.path) {
            '/browser/login/start' => {'version': 1, 'loginId': 'pending'},
            '/browser/login/verify-email' => {
              'version': 1,
              'next': 'enrollment',
            },
            '/browser/enrollment/options' => {'version': 1, 'options': {}},
            '/browser/enrollment/verify' => {'version': 1, 'enrolled': false},
            _ => throw StateError('Unexpected request'),
          };
          return http.Response(jsonEncode(data), 200);
        }),
        passkey: (_, {required register}) async => {
          'id': 'synthetic-test-credential',
        },
      );
      await verifyPendingEmail(api);
      await expectLater(
        api.enroll('a' * 43),
        throwsA(isA<AdminApiException>()),
      );
      expect(api.enrollmentRequired, true);
      expect(api.browserCsrf, isNull);
    },
  );
}
