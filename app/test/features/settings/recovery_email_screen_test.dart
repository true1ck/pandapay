import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/recovery_email_api.dart';
import 'package:pandapay/features/auth/recovery_email_reminder.dart';
import 'package:pandapay/features/settings/recovery_email_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const challengeBody = {
  'challenge': 'signed-token',
  'contact_hint': 'b•••@outlook.com',
  'expires_in': 60,
  'version': 2,
  'code_length': 6,
};

class _Run {
  final requests = <http.Request>[];
  late ProviderContainer container;
}

Future<_Run> mount(
  WidgetTester tester,
  http.Response Function(http.Request) reply, {
  bool changing = false,
}) async {
  final run = _Run();
  final api = RecoveryEmailApi(
    authBaseUrl: 'https://auth.test',
    accessToken: 'token',
    client: MockClient((request) async {
      run.requests.add(request);
      return reply(request);
    }),
  );
  run.container = ProviderContainer(
    overrides: [
      recoveryEmailApiProvider.overrideWithValue(api),
      accountDeviceIdProvider.overrideWith((ref) async => 'device-1'),
    ],
  );
  addTearDown(run.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: run.container,
      child: MaterialApp(home: RecoveryEmailScreen(changing: changing)),
    ),
  );
  return run;
}

Future<void> enterEmail(WidgetTester tester, String email) async {
  await tester.enterText(find.byKey(const Key('recovery-email-field')), email);
  await tester.tap(find.text('Send codes'));
  await tester.pumpAndSettle();
}

Future<void> enterCodes(WidgetTester tester, {String signIn = '123456', String fresh = '654321'}) async {
  await tester.enterText(find.byKey(const Key('recovery-signin-code')), signIn);
  await tester.enterText(find.byKey(const Key('recovery-new-code')), fresh);
  await tester.ensureVisible(find.text('Save recovery email'));
  await tester.tap(find.text('Save recovery email'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a wrong-looking address is explained on the spot and nothing is sent', (tester) async {
    final run = await mount(tester, (_) => json(challengeBody));
    await enterEmail(tester, 'not-an-email');
    expect(find.text('That email address doesn’t look right.'), findsOneWidget);
    expect(run.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the whole flow: address, two codes, saved, reminders stop', (tester) async {
    final run = await mount(tester, (request) {
      if (request.url.path.endsWith('/request')) return json(challengeBody);
      return json({'ok': true, 'recovery_email_hint': 'b•••@outlook.com'});
    });
    await enterEmail(tester, ' backup@outlook.com ');
    expect(jsonDecode(run.requests.first.body), {'email': 'backup@outlook.com', 'device_id': 'device-1'});
    expect(find.textContaining('Enter both codes'), findsOneWidget);
    expect(find.textContaining('b•••@outlook.com'), findsWidgets);
    expect(find.byKey(const Key('recovery-email-countdown')), findsOneWidget);

    await enterCodes(tester);
    expect(jsonDecode(run.requests.last.body), {
      'challenge': 'signed-token',
      'signin_code': '123456',
      'recovery_code': '654321',
      'device_id': 'device-1',
    });
    expect(find.text('Recovery email saved'), findsOneWidget);
    expect(find.textContaining('b•••@outlook.com is now your recovery email'), findsOneWidget);
    expect(await run.container.read(recoveryEmailReminderStoreProvider).added(), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('both codes must be six digits before anything is sent', (tester) async {
    final run = await mount(tester, (_) => json(challengeBody));
    await enterEmail(tester, 'backup@outlook.com');
    await enterCodes(tester, signIn: '12345', fresh: '654321');
    expect(find.text('Enter both 6-digit codes.'), findsOneWidget);
    expect(run.requests, hasLength(1), reason: 'only the first request was made');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a wrong code shows the server wording and clears both boxes', (tester) async {
    const message = 'One of the codes is wrong or has expired. Start again and use the newest codes.';
    await mount(tester, (request) => request.url.path.endsWith('/request')
        ? json(challengeBody)
        : json({'error': 'code_invalid', 'message': message}, 400));
    await enterEmail(tester, 'backup@outlook.com');
    await enterCodes(tester);
    expect(find.text(message), findsOneWidget);
    expect(find.text('Recovery email saved'), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const Key('recovery-signin-code'))).controller!.text, isEmpty);
    expect(tester.widget<TextField>(find.byKey(const Key('recovery-new-code'))).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an address the server refuses is explained and the person stays on the first step', (tester) async {
    const message = 'Please use your regular email address, not a temporary one.';
    await mount(tester, (_) => json({'error': 'email_not_allowed', 'message': message}, 400));
    await enterEmail(tester, 'x@mailinator.com');
    expect(find.text(message), findsOneWidget);
    expect(find.byKey(const Key('recovery-signin-code')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('once the codes expire the only way on is to ask for new ones', (tester) async {
    await mount(tester, (_) => json({...challengeBody, 'expires_in': 1}));
    await enterEmail(tester, 'backup@outlook.com');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('The codes have expired.'), findsOneWidget);
    expect(find.text('Send new codes'), findsOneWidget);
    expect(find.text('Save recovery email'), findsNothing);
    await tester.tap(find.text('Send new codes'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-email-field')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing shows the change title and the same two-code flow', (tester) async {
    await mount(tester, (_) => json(challengeBody), changing: true);
    expect(find.text('Change recovery email'), findsOneWidget);
    expect(find.text('Add a recovery email'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
