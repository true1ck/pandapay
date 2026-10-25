import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/api_exception.dart';

const challengeId = 'bc3f590c-b3c9-412c-98eb-1be64946cb70';
Map<String, Object?> challengeBody() => {
  'ok': true,
  'version': 2,
  'challenge_id': challengeId,
  'code_length': 6,
  'expires_in': 120,
};
http.Response response(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);
void main() {
  test(
    'v2 email sends only proved channel binding and verifies exact challenge',
    () async {
      final calls = <http.Request>[];
      final api = AuthApi(
        authBaseUrl: 'https://auth.test',
        versionedOtpEnabled: true,
        client: MockClient((r) async {
          calls.add(r);
          return r.url.path.contains('/request-')
              ? response(challengeBody())
              : response({
                  'access_token': 'verified',
                  'refresh_token': 'refresh',
                });
        }),
      );
      final challenge = await api.requestEmailOtp(
        'Person@Example.test',
        deviceId: 'device-1',
        phoneNumber: '+919999999999',
        isSignUp: true,
      );
      expect(calls.single.url.path, '/auth/v2/request-email-otp');
      expect(jsonDecode(calls.single.body), {
        'email': 'Person@Example.test',
        'device_id': 'device-1',
      });
      final tokens = await api.verifyEmailOtp(
        'person@example.test',
        '819273',
        'device-1',
        phoneNumber: '+919999999999',
        challenge: challenge,
      );
      expect(tokens.accessToken, 'verified');
      expect(api.otpCodeLength, 6);
      expect(jsonDecode(calls.last.body), {
        'email': 'person@example.test',
        'code': '819273',
        'device_id': 'device-1',
        'challenge_id': challengeId,
      });
    },
  );
  test(
    'v2 recovery phone binds purpose and preserves code on wrong device',
    () async {
      var calls = 0;
      final api = AuthApi(
        authBaseUrl: 'https://auth.test',
        versionedOtpEnabled: true,
        client: MockClient((r) async {
          calls++;
          return response(challengeBody());
        }),
      );
      final c = await api.requestOtp(
        '+919999999999',
        deviceId: 'device-1',
        recoveryOnly: true,
      );
      for (final attempt in [
        () => api.verifyOtp(
          '+919999999999',
          '819273',
          'device-2',
          challenge: c,
          recoveryOnly: true,
        ),
        () =>
            api.verifyOtp('+919999999999', '819273', 'device-1', challenge: c),
        () => api.verifyOtp(
          '+918888888888',
          '819273',
          'device-1',
          challenge: c,
          recoveryOnly: true,
        ),
        () => api.verifyEmailOtp(
          'person@example.test',
          '819273',
          'device-1',
          challenge: c,
          recoveryOnly: true,
        ),
        () => api.verifyOtp(
          '+919999999999',
          '1234',
          'device-1',
          challenge: c,
          recoveryOnly: true,
        ),
        () => api.verifyOtp(
          '+919999999999',
          '819273',
          'device-1',
          recoveryOnly: true,
        ),
      ]) {
        await expectLater(attempt(), throwsStateError);
      }
      expect(calls, 1);
    },
  );
  test('expired v2 request is refused locally and cannot downgrade', () async {
    var now = DateTime.utc(2026, 10, 24), calls = 0;
    final api = AuthApi(
      authBaseUrl: 'https://auth.test',
      versionedOtpEnabled: true,
      now: () => now,
      client: MockClient((r) async {
        calls++;
        return response(challengeBody());
      }),
    );
    final c = await api.requestEmailOtp(
      'person@example.test',
      deviceId: 'device-1',
    );
    now = now.add(const Duration(seconds: 120));
    await expectLater(
      api.verifyEmailOtp(
        'person@example.test',
        '819273',
        'device-1',
        challenge: c,
      ),
      throwsStateError,
    );
    expect(calls, 1);
  });
  test(
    'v2 rejects server legacy response, invalid UUID and unbounded TTL',
    () async {
      for (final b in [
        <String, Object?>{},
        {...challengeBody(), 'version': 1},
        {...challengeBody(), 'challenge_id': 'wrong'},
        {...challengeBody(), 'expires_in': 121},
        {...challengeBody(), 'code_length': 4},
      ]) {
        final api = AuthApi(
          authBaseUrl: 'https://auth.test',
          versionedOtpEnabled: true,
          client: MockClient((r) async => response(b)),
        );
        await expectLater(
          api.requestEmailOtp('person@example.test', deviceId: 'device-1'),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );
  test(
    'v2 transport failure makes one request and never retries legacy',
    () async {
      final calls = <String>[];
      final api = AuthApi(
        authBaseUrl: 'https://auth.test',
        versionedOtpEnabled: true,
        client: MockClient((r) async {
          calls.add(r.url.path);
          return response({'error': 'not_found'}, 404);
        }),
      );
      await expectLater(
        api.requestEmailOtp('person@example.test', deviceId: 'device-1'),
        throwsA(isA<ApiException>()),
      );
      expect(calls, ['/auth/v2/request-email-otp']);
    },
  );
  test('v2 requires real device before making network request', () async {
    var calls = 0;
    final api = AuthApi(
      authBaseUrl: 'https://auth.test',
      versionedOtpEnabled: true,
      client: MockClient((r) async {
        calls++;
        return response(challengeBody());
      }),
    );
    await expectLater(api.requestOtp('+919999999999'), throwsStateError);
    expect(calls, 0);
  });
}
