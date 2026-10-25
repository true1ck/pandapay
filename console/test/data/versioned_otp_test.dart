import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/data/admin_api.dart';

void main() {
  test(
    'browser v2 binds request and verify while keeping bearer credentials server-side',
    () async {
      final calls = <http.Request>[];
      final api = AuthApi(
        authBaseUrl: 'https://auth.test',
        browserSessions: true,
        browserBaseUrl: 'https://console.test/browser',
        versionedOtpEnabled: true,
        client: MockClient((r) async {
          calls.add(r);
          return http.Response(
            jsonEncode(
              r.url.path.contains('/request-')
                  ? {
                      'ok': true,
                      'version': 2,
                      'challenge_id': 'bc3f590c-b3c9-412c-98eb-1be64946cb70',
                      'code_length': 6,
                      'expires_in': 120,
                    }
                  : {'authenticated': true, 'csrfToken': 'synthetic-csrf'},
            ),
            200,
          );
        }),
      );
      final c = await api.requestEmailOtp(
        'operator@example.test',
        deviceId: 'console-device',
      );
      expect(calls.single.url.path, '/browser/v2/request-email-otp');
      final tokens = await api.verifyEmailOtp(
        'operator@example.test',
        '819273',
        'console-device',
        challenge: c,
      );
      expect(tokens.accessToken, 'console-browser-session');
      expect(tokens.refreshToken, isNull);
      expect(api.browserCsrf, 'synthetic-csrf');
      expect(jsonDecode(calls.last.body), {
        'email': 'operator@example.test',
        'code': '819273',
        'device_id': 'console-device',
        'challenge_id': c!.id,
      });
    },
  );
  test(
    'console v2 refuses another device and never downgrades missing challenge',
    () async {
      var calls = 0;
      final api = AuthApi(
        authBaseUrl: 'https://auth.test',
        versionedOtpEnabled: true,
        client: MockClient((r) async {
          calls++;
          return http.Response('{}', 404);
        }),
      );
      await expectLater(
        api.requestEmailOtp(
          'operator@example.test',
          deviceId: 'console-device',
        ),
        throwsA(isA<AdminApiException>()),
      );
      expect(
        () => api.verifyEmailOtp(
          'operator@example.test',
          '819273',
          'console-device',
        ),
        throwsA(isA<AdminApiException>()),
      );
      expect(calls, 1);
    },
  );
}
