import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/recovery_email_api.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

RecoveryEmailApi api(MockClient client, {DateTime Function()? now}) => RecoveryEmailApi(
  authBaseUrl: 'https://auth.test',
  accessToken: 'token-1',
  client: client,
  now: now,
);

const goodChallenge = {
  'challenge': 'signed-token',
  'contact_hint': 'b•••@outlook.com',
  'expires_in': 60,
  'version': 2,
  'code_length': 6,
};

void main() {
  test('status reads whether there is a recovery email and its masked address', () async {
    late http.Request seen;
    final status = await api(
      MockClient((r) async {
        seen = r;
        return json({'has_recovery_email': true, 'recovery_email_hint': 'b•••@outlook.com'});
      }),
    ).status();
    expect(seen.method, 'GET');
    expect(seen.url.toString(), 'https://auth.test/users/me/recovery-email');
    expect(seen.headers['Authorization'], 'Bearer token-1');
    expect(status.hasRecoveryEmail, isTrue);
    expect(status.hint, 'b•••@outlook.com');
    expect(RecoveryEmailStatus.fromJson(const {}).hasRecoveryEmail, isFalse);
  });

  test('step one sends the trimmed address and the device, and returns the challenge', () async {
    late http.Request seen;
    final start = DateTime.utc(2026, 11, 9, 12);
    final challenge = await api(
      MockClient((r) async {
        seen = r;
        return json(goodChallenge);
      }),
      now: () => start,
    ).requestChange('  backup@outlook.com ', deviceId: 'device-1');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/users/me/recovery-email/request');
    expect(jsonDecode(seen.body), {'email': 'backup@outlook.com', 'device_id': 'device-1'});
    expect(challenge.token, 'signed-token');
    expect(challenge.contactHint, 'b•••@outlook.com');
    expect(challenge.expiresAt, start.add(const Duration(seconds: 60)));
  });

  test('a malformed or out-of-contract challenge is refused with a plain message', () async {
    for (final body in [
      {...goodChallenge, 'challenge': ''},
      {...goodChallenge, 'version': 1},
      {...goodChallenge, 'code_length': 4},
      {...goodChallenge, 'expires_in': 600},
      {...goodChallenge, 'contact_hint': null},
    ]) {
      await expectLater(
        api(MockClient((_) async => json(body))).requestChange('a@b.co', deviceId: 'device-1'),
        throwsA(isA<ApiException>().having((e) => e.userMessage, 'userMessage', contains('try again'))),
        reason: jsonEncode(body),
      );
    }
  });

  test('step two sends both codes and the challenge, and returns the masked address', () async {
    late http.Request seen;
    final now = DateTime.utc(2026, 11, 9, 12);
    final client = api(
      MockClient((r) async {
        seen = r;
        return r.url.path.endsWith('/request')
            ? json(goodChallenge)
            : json({'ok': true, 'recovery_email_hint': 'b•••@outlook.com'});
      }),
      now: () => now,
    );
    final challenge = await client.requestChange('backup@outlook.com', deviceId: 'device-1');
    final hint = await client.confirm(challenge, signInCode: '123456', recoveryCode: '654321', deviceId: 'device-1');
    expect(seen.url.path, '/users/me/recovery-email/verify');
    expect(jsonDecode(seen.body), {
      'challenge': 'signed-token',
      'signin_code': '123456',
      'recovery_code': '654321',
      'device_id': 'device-1',
    });
    expect(hint, 'b•••@outlook.com');
  });

  test('expired codes are refused on the phone without a request', () async {
    var requests = 0;
    var clock = DateTime.utc(2026, 11, 9, 12);
    final client = api(
      MockClient((r) async {
        requests++;
        return json(goodChallenge);
      }),
      now: () => clock,
    );
    final challenge = await client.requestChange('backup@outlook.com', deviceId: 'device-1');
    clock = clock.add(const Duration(seconds: 61));
    await expectLater(
      client.confirm(challenge, signInCode: '123456', recoveryCode: '654321', deviceId: 'device-1'),
      throwsA(isA<ApiException>().having((e) => e.userMessage, 'userMessage', contains('expired'))),
    );
    expect(requests, 1);
  });

  test('a refusal carries the server wording and code', () async {
    const message = 'Please use your regular email address, not a temporary one.';
    await expectLater(
      api(MockClient((_) async => json({'error': 'email_not_allowed', 'message': message}, 400)))
          .requestChange('x@mailinator.com', deviceId: 'device-1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.errorCode, 'errorCode', 'email_not_allowed')
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.userMessage, 'userMessage', message),
      ),
    );
  });

  test('remove calls DELETE and surfaces a step-up refusal plainly', () async {
    late http.Request seen;
    await api(MockClient((r) async { seen = r; return json({'ok': true, 'removed': true}); })).remove();
    expect(seen.method, 'DELETE');
    await expectLater(
      api(MockClient((_) async => json({'error': 'step_up_required', 'message': 'This action requires additional verification. Please verify your OTP first.'}, 403))).remove(),
      throwsA(isA<ApiException>().having((e) => e.errorCode, 'errorCode', 'step_up_required')),
    );
  });
}
