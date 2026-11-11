import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/account_recovery_api.dart';
import 'package:pandapay/data/secure_storage/secure_storage_options.dart';
import 'package:pandapay/data/token_store.dart';
import 'package:pandapay/features/auth/cant_sign_in_screen.dart';
import 'package:pandapay/features/auth/recovery_hold_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const startBody = {
  'ok': true,
  'attempt_id': '11111111-2222-4333-8444-555555555555',
  'version': 2,
  'code_length': 6,
  'expires_in': 60,
};

const session = {
  'ok': true,
  'pending': false,
  'access_token': 'access-1',
  'refresh_token': 'refresh-1',
  'new_email_hint': 'n•••@yahoo.com',
};

class _Run {
  final requests = <http.Request>[];
  late ProviderContainer container;
  Map<String, Object?> lastBody() => jsonDecode(requests.last.body) as Map<String, Object?>;
  List<String> get paths => [for (final r in requests) r.url.path.replaceFirst('/auth/recovery', '')];
}

Future<_Run> mount(WidgetTester tester, http.Response Function(http.Request) reply) async {
  final run = _Run();
  run.container = ProviderContainer(
    overrides: [
      accountRecoveryApiProvider.overrideWithValue(
        AccountRecoveryApi(
          authBaseUrl: 'https://auth.test',
          client: MockClient((request) async {
            run.requests.add(request);
            return reply(request);
          }),
        ),
      ),
      accountDeviceIdProvider.overrideWith((ref) async => 'device-1'),
      tokenStoreProvider.overrideWith((ref) async => TokenStore(pandaPaySecureStorage)),
    ],
  );
  addTearDown(run.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: run.container,
      child: const MaterialApp(home: CantSignInScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return run;
}

Future<void> typeInto(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

Future<void> fillDetails(WidgetTester tester, {String fact = '4821'}) async {
  await typeInto(tester, 'recovery-lost-email', ' Old.Me@gmail.com ');
  await typeInto(tester, 'recovery-phone', '98765 43210');
  await typeInto(tester, 'recovery-fact', fact);
  await tapText(tester, 'Continue');
}

Future<void> end(WidgetTester tester) => tester.pumpWidget(const SizedBox.shrink());

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecoveryHoldStore().clear();
  });

  test('the fact is a card, or a month in either order; anything else is explained', () {
    for (final ok in ['4821', ' 2026 ', '11/2026', '2026-11', '1/2026', '2026/1']) {
      expect(recoveryFactProblem(ok), isNull, reason: ok);
    }
    expect(recoveryFactProblem(''), contains('last four digits'));
    for (final bad in ['482', '48211', '13/2026', '0/2026', '2026-13', '11/2019', '11/2101', 'abcd']) {
      expect(recoveryFactProblem(bad), isNotNull, reason: bad);
    }
  });

  testWidgets('the details are checked on the spot and nothing is sent until all three are fine', (tester) async {
    final run = await mount(tester, (_) => json(startBody));
    await tapText(tester, 'Continue');
    expect(find.textContaining('email address you used to sign in'), findsOneWidget);

    await typeInto(tester, 'recovery-lost-email', 'old.me@gmail.com');
    await typeInto(tester, 'recovery-phone', '12345');
    await tapText(tester, 'Continue');
    expect(find.textContaining('valid 10-digit Indian mobile number'), findsOneWidget);

    await typeInto(tester, 'recovery-phone', '9876543210');
    await typeInto(tester, 'recovery-fact', '13/2026');
    await tapText(tester, 'Continue');
    expect(find.textContaining('doesn’t look right'), findsOneWidget);
    expect(run.requests, isEmpty);
    await end(tester);
  });

  testWidgets('the fields ask the keyboard for the right autofill', (tester) async {
    await mount(tester, (_) => json(startBody));
    TextField field(String key) => tester.widget<TextField>(find.byKey(Key(key)));
    expect(field('recovery-lost-email').autofillHints, contains(AutofillHints.email));
    expect(field('recovery-phone').autofillHints, contains(AutofillHints.telephoneNumber));
    await end(tester);
  });

  testWidgets('with a recovery email: details, code, use the recovery email, signed in at once', (tester) async {
    final run = await mount(tester, (request) {
      final path = request.url.path;
      if (path.endsWith('/start')) return json(startBody);
      if (path.endsWith('/new-email')) return json({'ok': true, 'needs_code': false, 'new_email_hint': 'r•••@outlook.com'});
      if (path.endsWith('/complete')) return json(session);
      return json({'ok': true, 'next': 'new_email', 'can_use_recovery_email': true});
    });
    await fillDetails(tester);
    expect(run.paths, ['/start']);
    expect(run.lastBody(), {
      'lost_email': 'Old.Me@gmail.com',
      'phone': '+919876543210',
      'fact': '4821',
      'device_id': 'device-1',
    });
    expect(find.byKey(const Key('recovery-countdown')), findsOneWidget);

    await typeInto(tester, 'recovery-code', '123456');
    await tapText(tester, 'Continue');
    expect(run.paths.last, '/verify-code');
    expect(run.lastBody(), {
      'attempt_id': startBody['attempt_id'],
      'code': '123456',
      'device_id': 'device-1',
    });
    expect(find.byKey(const Key('recovery-use-recovery-email')), findsOneWidget);

    await tapText(tester, 'Use my recovery email to sign in');
    expect(run.paths.sublist(run.paths.length - 2), ['/new-email', '/complete']);
    expect(run.requests[run.requests.length - 2].body, contains('"use_recovery_email":true'));
    expect(run.lastBody().containsKey('code'), isFalse);

    expect(run.container.read(accessTokenProvider), 'access-1');
    expect(find.text('You’re back in'), findsOneWidget);
    expect(await RecoveryHoldStore().load(), isNull);
    await end(tester);
  });

  testWidgets('with a recovery email: a typed new email gets its own code, then signs in', (tester) async {
    final run = await mount(tester, (request) {
      final path = request.url.path;
      if (path.endsWith('/start')) return json(startBody);
      if (path.endsWith('/new-email')) return json({'ok': true, 'needs_code': true, 'new_email_hint': 'n•••@yahoo.com', 'expires_in': 60});
      if (path.endsWith('/complete')) return json(session);
      return json({'ok': true});
    });
    await fillDetails(tester);
    await typeInto(tester, 'recovery-code', '123456');
    await tapText(tester, 'Continue');
    await typeInto(tester, 'recovery-new-email', 'new.me@yahoo.com');
    await tapText(tester, 'Send code');
    expect(run.lastBody(), {
      'attempt_id': startBody['attempt_id'],
      'device_id': 'device-1',
      'new_email': 'new.me@yahoo.com',
    });
    expect(find.textContaining('n•••@yahoo.com'), findsWidgets);

    await typeInto(tester, 'recovery-new-code', '654321');
    await tapText(tester, 'Finish');
    expect(run.lastBody(), {
      'attempt_id': startBody['attempt_id'],
      'device_id': 'device-1',
      'code': '654321',
    });
    expect(run.container.read(accessTokenProvider), 'access-1');
    await end(tester);
  });

  testWidgets('without a recovery email: 24 hours, no shortcut, and the wait is kept for later', (tester) async {
    final holdUntil = DateTime.now().add(const Duration(hours: 24));
    final run = await mount(tester, (request) {
      final path = request.url.path;
      if (path.endsWith('/start')) return json(startBody);
      if (path.endsWith('/no-recovery-email')) return json({'ok': true, 'next': 'new_email', 'hold_hours': 24, 'can_use_recovery_email': false});
      if (path.endsWith('/new-email')) return json({'ok': true, 'needs_code': true, 'new_email_hint': 'n•••@yahoo.com', 'expires_in': 60});
      if (path.endsWith('/complete')) {
        return json({'ok': true, 'pending': true, 'hold_until': holdUntil.toUtc().toIso8601String(), 'resume_token': 'resume-secret'});
      }
      return json({'ok': true});
    });
    await fillDetails(tester, fact: '11/2026');
    await tapText(tester, 'I don’t have a recovery email');
    expect(find.textContaining('this takes 24 hours'), findsOneWidget);
    expect(find.byKey(const Key('recovery-use-recovery-email')), findsNothing);

    await typeInto(tester, 'recovery-new-email', 'new.me@yahoo.com');
    await tapText(tester, 'Send code');
    await typeInto(tester, 'recovery-new-code', '654321');
    await tapText(tester, 'Finish');

    expect(find.text('Your recovery is waiting'), findsOneWidget);
    expect(run.container.read(accessTokenProvider), isNull, reason: 'nothing is granted yet');
    final saved = await RecoveryHoldStore().load();
    expect(saved?.attemptId, startBody['attempt_id']);
    expect(saved?.resumeToken, 'resume-secret');
    expect(saved?.newEmailHint, 'n•••@yahoo.com');
    // Finish is not offered until the hold is over.
    final finish = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Finish recovery'));
    expect(finish.onPressed, isNull);
    await end(tester);
  });

  testWidgets('reopening the screen resumes a saved wait, and finishing after the hold signs in', (tester) async {
    await RecoveryHoldStore().save(
      RecoveryHold(
        attemptId: 'attempt-9',
        resumeToken: 'resume-secret',
        holdUntil: DateTime.now().subtract(const Duration(minutes: 1)),
        newEmailHint: 'n•••@yahoo.com',
      ),
    );
    final run = await mount(tester, (request) => request.url.path.endsWith('/finish') ? json(session) : json({'ok': true}));
    expect(find.text('Ready to finish'), findsOneWidget);
    await tapText(tester, 'Finish recovery');
    expect(run.lastBody(), {'attempt_id': 'attempt-9', 'device_id': 'device-1', 'resume_token': 'resume-secret'});
    expect(run.container.read(accessTokenProvider), 'access-1');
    expect(await RecoveryHoldStore().load(), isNull, reason: 'a finished wait is forgotten');
    await end(tester);
  });

  testWidgets('a wait that was cancelled says so and clears itself', (tester) async {
    await RecoveryHoldStore().save(
      RecoveryHold(
        attemptId: 'attempt-9',
        resumeToken: 'resume-secret',
        holdUntil: DateTime.now().subtract(const Duration(minutes: 1)),
        newEmailHint: 'n•••@yahoo.com',
      ),
    );
    await mount(tester, (_) => json({'error': 'recovery_failed', 'message': 'That did not match. Check the details, or use the newest code.'}, 400));
    await tapText(tester, 'Finish recovery');
    expect(find.textContaining('no longer waiting'), findsOneWidget);
    expect(find.textContaining('cancelled from your old email'), findsOneWidget);
    expect(await RecoveryHoldStore().load(), isNull);
    expect(find.text('Start again'), findsOneWidget);
    await end(tester);
  });

  testWidgets('a wait that is not over keeps its saved token when the server says too early', (tester) async {
    await RecoveryHoldStore().save(
      RecoveryHold(
        attemptId: 'attempt-9',
        resumeToken: 'resume-secret',
        holdUntil: DateTime.now().subtract(const Duration(seconds: 1)),
        newEmailHint: 'n•••@yahoo.com',
      ),
    );
    await mount(tester, (_) => json({'error': 'hold_not_over', 'message': 'The 24 hours are not over yet.', 'hold_until': DateTime.now().add(const Duration(minutes: 5)).toUtc().toIso8601String()}, 409));
    await tapText(tester, 'Finish recovery');
    expect(find.text('The 24 hours are not over yet.'), findsOneWidget);
    expect(await RecoveryHoldStore().load(), isNotNull);
    await end(tester);
  });

  testWidgets('a mismatch gives the server wording and offers to start over; a wrong code just asks again', (tester) async {
    var verifyReply = json({'error': 'recovery_failed', 'message': 'That did not match. Check the details, or use the newest code.'}, 400);
    final run = await mount(tester, (request) => request.url.path.endsWith('/start') ? json(startBody) : verifyReply);
    await fillDetails(tester);
    await typeInto(tester, 'recovery-code', '123456');
    await tapText(tester, 'Continue');
    expect(find.text('That did not match. Check the details, or use the newest code.'), findsOneWidget);
    expect(find.text('Start over'), findsOneWidget);
    await tapText(tester, 'Start over');
    expect(find.byKey(const Key('recovery-lost-email')), findsOneWidget);

    verifyReply = json({'error': 'code_invalid', 'message': 'That code is wrong or has expired. Check it and try again.'}, 400);
    await fillDetails(tester);
    await typeInto(tester, 'recovery-code', '000000');
    await tapText(tester, 'Continue');
    expect(find.text('That code is wrong or has expired. Check it and try again.'), findsOneWidget);
    expect(find.text('Start over'), findsNothing);
    expect(find.byKey(const Key('recovery-code')), findsOneWidget);
    expect(run.container.read(accessTokenProvider), isNull);
    await end(tester);
  });

  testWidgets('a network failure is a plain message, not a stack trace', (tester) async {
    await mount(tester, (_) => throw http.ClientException('offline'));
    await fillDetails(tester);
    expect(find.textContaining('check your connection'), findsOneWidget);
    await end(tester);
  });
}
