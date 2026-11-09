import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/account_recovery_api.dart';
import 'package:pandapay/data/api_exception.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

AccountRecoveryApi api(http.Response Function(http.Request) reply, [List<http.Request>? seen]) =>
    AccountRecoveryApi(
      authBaseUrl: 'https://auth.test',
      client: MockClient((r) async {
        seen?.add(r);
        return reply(r);
      }),
    );

void main() {
  test('start sends the four details to /auth/recovery/start and reads the attempt', () async {
    final seen = <http.Request>[];
    final result = await api(
      (_) => json({'ok': true, 'attempt_id': 'abc', 'version': 2, 'code_length': 6, 'expires_in': 60}),
      seen,
    ).start(lostEmail: ' a@gmail.com ', phone: '+919876543210', fact: ' 4821 ', deviceId: 'd1');
    expect(seen.single.url.toString(), 'https://auth.test/auth/recovery/start');
    expect(seen.single.headers['Authorization'], isNull, reason: 'there is no session yet');
    expect(jsonDecode(seen.single.body), {
      'lost_email': 'a@gmail.com',
      'phone': '+919876543210',
      'fact': '4821',
      'device_id': 'd1',
    });
    expect(result.attemptId, 'abc');
    expect(result.codeLength, 6);
    expect(result.codeLifetime, const Duration(seconds: 60));
  });

  test('a start reply that is not shaped right is refused rather than trusted', () async {
    for (final bad in [
      <String, Object?>{'ok': true},
      {'attempt_id': '', 'code_length': 6, 'expires_in': 60},
      {'attempt_id': 'a', 'code_length': 99, 'expires_in': 60},
      {'attempt_id': 'a', 'code_length': 6, 'expires_in': 99999},
    ]) {
      await expectLater(
        api((_) => json(bad)).start(lostEmail: 'a@b.co', phone: '1', fact: '4821', deviceId: 'd'),
        throwsA(isA<ApiException>()),
        reason: '$bad',
      );
    }
  });

  test('the server error code and wording come through, with the hold end time', () async {
    final until = DateTime.utc(2026, 11, 10, 10);
    try {
      await api((_) => json({'error': 'hold_not_over', 'message': 'The 24 hours are not over yet.', 'hold_until': until.toIso8601String()}, 409))
          .finish(attemptId: 'a', deviceId: 'd', resumeToken: 't');
      fail('should have thrown');
    } on RecoveryFailure catch (e) {
      expect(e.code, 'hold_not_over');
      expect(e.status, 409);
      expect(e.userMessage, 'The 24 hours are not over yet.');
      expect(e.holdUntil?.toUtc(), until);
      expect(e.startOver, isFalse);
    }
    try {
      await api((_) => json({'error': 'recovery_failed', 'message': 'x'}, 400)).verifyCode(attemptId: 'a', code: '1', deviceId: 'd');
      fail('should have thrown');
    } on RecoveryFailure catch (e) {
      expect(e.startOver, isTrue);
      expect(e.retryable, isFalse);
    }
    try {
      await api((_) => json({'error': 'code_invalid', 'message': 'y'}, 400)).complete(attemptId: 'a', deviceId: 'd', code: '1');
      fail('should have thrown');
    } on RecoveryFailure catch (e) {
      expect(e.retryable, isTrue);
    }
  });

  test('a reply that is not JSON (a proxy error page) is a generic failure, not a crash', () async {
    await expectLater(
      api((_) => http.Response('<html>Bad gateway</html>', 502)).noRecoveryEmail(attemptId: 'a', deviceId: 'd'),
      throwsA(isA<RecoveryFailure>().having((e) => e.code, 'code', 'unknown')),
    );
  });

  test('complete returns either a session or a waiting recovery, and refuses half of either', () async {
    final session = await api((_) => json({'ok': true, 'pending': false, 'access_token': 'a', 'refresh_token': 'r', 'new_email_hint': 'n•••@y.com'}))
        .complete(attemptId: 'a', deviceId: 'd');
    expect(session.pending, isFalse);
    expect(session.tokens?.accessToken, 'a');
    expect(session.tokens?.refreshToken, 'r');
    expect(session.newEmailHint, 'n•••@y.com');

    final held = await api((_) => json({'ok': true, 'pending': true, 'hold_until': '2026-11-10T10:00:00.000Z', 'resume_token': 'secret'}))
        .complete(attemptId: 'a', deviceId: 'd');
    expect(held.pending, isTrue);
    expect(held.resumeToken, 'secret');
    expect(held.holdUntil?.toUtc(), DateTime.utc(2026, 11, 10, 10));
    expect(held.tokens, isNull);

    for (final bad in [
      <String, Object?>{'ok': true, 'pending': true, 'hold_until': 'soon'},
      {'ok': true, 'pending': true, 'hold_until': '2026-11-10T10:00:00.000Z'},
      {'ok': true, 'pending': false},
    ]) {
      await expectLater(api((_) => json(bad)).complete(attemptId: 'a', deviceId: 'd'), throwsA(isA<ApiException>()), reason: '$bad');
    }
  });

  test('new-email says whether a code was sent, and omits what it was not given', () async {
    final seen = <http.Request>[];
    final typed = await api((_) => json({'ok': true, 'needs_code': true, 'new_email_hint': 'n•••@y.com', 'expires_in': 60}), seen)
        .setNewEmail(attemptId: 'a', deviceId: 'd', newEmail: ' n@y.com ');
    expect(typed.needsCode, isTrue);
    expect(jsonDecode(seen.single.body), {'attempt_id': 'a', 'device_id': 'd', 'new_email': 'n@y.com'});

    final shortcut = await api((_) => json({'ok': true, 'needs_code': false, 'new_email_hint': 'r•••@o.com'}), seen)
        .setNewEmail(attemptId: 'a', deviceId: 'd', useRecoveryEmail: true);
    expect(shortcut.needsCode, isFalse);
    expect(jsonDecode(seen.last.body), {'attempt_id': 'a', 'device_id': 'd', 'use_recovery_email': true});
  });

  test('the signed-in side reads a waiting recovery and cancels it; nothing left to cancel is fine', () async {
    final seen = <http.Request>[];
    http.Response reply(http.Request r) {
      if (r.method == 'GET') return json({'pending': true, 'hold_until': '2026-11-10T10:00:00.000Z'});
      return r.url.path.endsWith('/cancel') ? json({'ok': true, 'cancelled': 1}) : json({}, 404);
    }

    final pending = RecoveryPendingApi(
      authBaseUrl: 'https://auth.test',
      accessToken: 'tok',
      client: MockClient((r) async {
        seen.add(r);
        return reply(r);
      }),
    );
    final status = await pending.status();
    expect(status.pending, isTrue);
    expect(status.holdUntil?.toUtc(), DateTime.utc(2026, 11, 10, 10));
    await pending.cancel();
    expect(seen.map((r) => '${r.method} ${r.url.path}'), ['GET /users/me/recovery-pending', 'POST /users/me/recovery-pending/cancel']);
    expect(seen.every((r) => r.headers['Authorization'] == 'Bearer tok'), isTrue);

    final nothing = RecoveryPendingApi(
      authBaseUrl: 'https://auth.test',
      accessToken: 'tok',
      client: MockClient((_) async => json({'error': 'nothing_pending'}, 404)),
    );
    await nothing.cancel();
    final broken = RecoveryPendingApi(
      authBaseUrl: 'https://auth.test',
      accessToken: 'tok',
      client: MockClient((_) async => json({}, 500)),
    );
    await expectLater(broken.cancel(), throwsA(isA<ApiException>()));
  });
}
