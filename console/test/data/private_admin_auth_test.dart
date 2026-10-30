import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/data/admin_api.dart';
import 'package:pandapay_console/data/private_admin_auth.dart';

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
}
