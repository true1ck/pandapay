import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/recovery_api.dart';

http.Response _response(Object value, [int status = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(value)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, Object?> _challengeBody({
  Object challenge = 'opaque.signed.jwt',
  Object hint = 'a•••@example.test',
  Object version = 2,
  Object codeLength = 6,
  Object expiresIn = 120,
}) => {
  'challenge': challenge,
  'contact_hint': hint,
  'version': version,
  'code_length': codeLength,
  'expires_in': expiresIn,
};

Map<String, Object?> _statusBody() => {
  'phone_verified': true,
  'email_verified': true,
  'has_backup_channel': true,
};

void main() {
  group('v2 contact replacement', () {
    test('posts request and verify with exact device binding', () async {
      final calls = <http.Request>[];
      final auth = AuthApi(
        authBaseUrl: 'https://auth.test',
        versionedOtpEnabled: true,
        client: MockClient((request) async {
          calls.add(request);
          return request.url.path.endsWith('/request')
              ? _response(_challengeBody())
              : _response(_statusBody());
        }),
      );
      final api = auth.recoveryApiFor('recent-proof');
      final challenge = await api.requestContactReplacementV2(
        'New@Example.test',
        deviceId: 'device-123',
      );
      expect(calls.first.url.path, '/users/me/recovery-contact/v2/request');
      expect(calls.first.headers['authorization'], 'Bearer recent-proof');
      expect(jsonDecode(calls.first.body), {
        'identifier': 'New@Example.test',
        'device_id': 'device-123',
      });
      expect(challenge.identifier, 'new@example.test');
      expect(challenge.contactHint, 'a•••@example.test');
      expect(challenge.protocolVersion, 2);
      await api.verifyContactReplacementV2(
        challenge,
        '123456',
        identifier: 'new@example.test',
        deviceId: 'device-123',
      );
      expect(calls.last.url.path, '/users/me/recovery-contact/v2/verify');
      expect(jsonDecode(calls.last.body), {
        'challenge': 'opaque.signed.jwt',
        'code': '123456',
        'device_id': 'device-123',
      });
    });

    test(
      'rejects absent feature flag and invalid device before network',
      () async {
        var calls = 0;
        RecoveryApi api() => RecoveryApi(
          authBaseUrl: 'https://auth.test',
          accessToken: 'proof',
          client: MockClient((_) async {
            calls++;
            return _response(_challengeBody());
          }),
        );
        await expectLater(
          api().requestContactReplacementV2(
            'a@example.test',
            deviceId: 'device-1',
          ),
          throwsStateError,
        );
        final enabled = RecoveryApi(
          authBaseUrl: 'https://auth.test',
          accessToken: 'proof',
          versionedOtpEnabled: true,
          client: MockClient((_) async {
            calls++;
            return _response(_challengeBody());
          }),
        );
        await expectLater(
          enabled.requestContactReplacementV2(
            'a@example.test',
            deviceId: 'bad',
          ),
          throwsStateError,
        );
        expect(calls, 0);
      },
    );

    test('rejects missing or malformed response metadata', () async {
      for (final body in [
        <String, Object?>{},
        _challengeBody(challenge: ''),
        _challengeBody(hint: ''),
        _challengeBody(version: 1),
        _challengeBody(codeLength: 4),
        _challengeBody(expiresIn: 0),
        _challengeBody(expiresIn: 121),
        _challengeBody(expiresIn: '30'),
      ]) {
        final api = RecoveryApi(
          authBaseUrl: 'https://auth.test',
          accessToken: 'proof',
          versionedOtpEnabled: true,
          client: MockClient((_) async => _response(body)),
        );
        await expectLater(
          api.requestContactReplacementV2(
            'a@example.test',
            deviceId: 'device-123',
          ),
          throwsA(isA<ApiException>()),
        );
      }
    });

    test('404 never retries against legacy route', () async {
      final paths = <String>[];
      final api = RecoveryApi(
        authBaseUrl: 'https://auth.test',
        accessToken: 'proof',
        versionedOtpEnabled: true,
        client: MockClient((request) async {
          paths.add(request.url.path);
          return _response({'error': 'not_found'}, 404);
        }),
      );
      await expectLater(
        api.requestContactReplacementV2(
          'a@example.test',
          deviceId: 'device-123',
        ),
        throwsA(isA<ApiException>()),
      );
      expect(paths, ['/users/me/recovery-contact/v2/request']);
    });

    test(
      'wrong identifier, wrong device, and four digits refuse locally',
      () async {
        var calls = 0;
        final api = RecoveryApi(
          authBaseUrl: 'https://auth.test',
          accessToken: 'proof',
          versionedOtpEnabled: true,
          client: MockClient((_) async {
            calls++;
            return _response(_challengeBody());
          }),
        );
        final challenge = await api.requestContactReplacementV2(
          'a@example.test',
          deviceId: 'device-123',
        );
        for (final attempt in [
          () => api.verifyContactReplacementV2(
            challenge,
            '123456',
            identifier: 'other@example.test',
            deviceId: 'device-123',
          ),
          () => api.verifyContactReplacementV2(
            challenge,
            '123456',
            identifier: 'a@example.test',
            deviceId: 'another-device',
          ),
          () => api.verifyContactReplacementV2(
            challenge,
            '1234',
            identifier: 'a@example.test',
            deviceId: 'device-123',
          ),
        ]) {
          await expectLater(attempt(), throwsStateError);
        }
        expect(calls, 1);
      },
    );

    test('expired challenge refuses locally', () async {
      var now = DateTime.utc(2026, 10, 25);
      var calls = 0;
      final api = RecoveryApi(
        authBaseUrl: 'https://auth.test',
        accessToken: 'proof',
        versionedOtpEnabled: true,
        now: () => now,
        client: MockClient((request) async {
          calls++;
          return request.url.path.endsWith('/request')
              ? _response(_challengeBody(expiresIn: 1))
              : _response(_statusBody());
        }),
      );
      final challenge = await api.requestContactReplacementV2(
        'a@example.test',
        deviceId: 'device-123',
      );
      now = now.add(const Duration(seconds: 1));
      await expectLater(
        api.verifyContactReplacementV2(
          challenge,
          '123456',
          identifier: 'a@example.test',
          deviceId: 'device-123',
        ),
        throwsStateError,
      );
      expect(calls, 1);
    });
  });

  test(
    'legacy replacement methods and route remain source-compatible',
    () async {
      final calls = <http.Request>[];
      final api = RecoveryApi(
        authBaseUrl: 'https://auth.test',
        accessToken: 'proof',
        client: MockClient((request) async {
          calls.add(request);
          return request.url.path.endsWith('/request')
              ? _response({'challenge': 'legacy-token'})
              : _response(_statusBody());
        }),
      );
      final challenge = await api.requestContactReplacement('new@example.test');
      expect(challenge, 'legacy-token');
      await api.verifyContactReplacement(challenge, '1234');
      expect(calls.map((call) => call.url.path), [
        '/users/me/recovery-contact/request',
        '/users/me/recovery-contact/verify',
      ]);
    },
  );
}
