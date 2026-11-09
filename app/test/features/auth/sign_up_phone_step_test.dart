import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/features/auth/phone_gate_provider.dart';

const taken =
    "This number can't be used. If it is yours, sign in with the email you first used, or contact support.";

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Drives the real sign-in screen against a fake auth service and returns what it
/// did with the phone number.
class _Run {
  final List<http.Request> phonePosts = [];
  int profileCalls = 0;
  late ProviderContainer container;
}

Future<_Run> signIn(
  WidgetTester tester, {
  required AuthMode mode,
  required Map<String, Object?> phoneStatus,
  http.Response Function()? claimReply,
  int phoneStatusCode = 200,
}) async {
  final run = _Run();
  final auth = AuthApi(
    authBaseUrl: 'https://auth.test',
    client: MockClient((request) async {
      final path = request.url.path;
      if (path == '/auth/request-email-otp') return json({'ok': true});
      if (path == '/auth/verify-email-otp') {
        return json({'access_token': 'access', 'refresh_token': 'refresh'});
      }
      if (path == '/users/me/phone' && request.method == 'GET') {
        return json(phoneStatus, phoneStatusCode);
      }
      if (path == '/users/me/phone' && request.method == 'POST') {
        run.phonePosts.add(request);
        return claimReply?.call() ?? json({'ok': true, 'phone_hint': '+91 •••• 3210'});
      }
      return json({});
    }),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authApiProvider.overrideWithValue(auth),
        localDeviceIdProvider.overrideWith((ref) async => 'test-device'),
        deviceMetadataProvider.overrideWith((ref) async => const {'platform': 'test'}),
        phoneGateProvider.overrideWith((ref) => PhoneGateController(ref)),
        profileApiProvider.overrideWith(
          (ref) => ProfileApi(
            apiBaseUrl: 'https://api.test',
            accessToken: 'access',
            client: MockClient((_) async {
              run.profileCalls++;
              return json({'profile': {'id': 'p1'}}, 201);
            }),
          ),
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            run.container = ProviderScope.containerOf(context);
            return ref.watch(accessTokenProvider) == null
                ? Scaffold(body: LoginScreen(mode: mode))
                : const Scaffold(body: Text('Signed-in home'));
          },
        ),
      ),
    ),
  );
  await tester.enterText(find.byType(TextField).at(0), 'person@example.test');
  if (mode == AuthMode.signUp) {
    await tester.enterText(find.byType(TextField).at(1), '98765 43210');
    for (final i in [0, 1]) {
      await tester.ensureVisible(find.byType(CheckboxListTile).at(i));
      await tester.tap(find.byType(CheckboxListTile).at(i));
    }
  }
  await tester.pump();
  final send = find.text(mode == AuthMode.signUp ? 'Send verification code' : 'Send code');
  await tester.ensureVisible(send);
  await tester.tap(send);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), '1234');
  await tester.ensureVisible(find.text('Verify & continue'));
  await tester.tap(find.text('Verify & continue'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
  return run;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('sign-up with the lock on saves the typed number as ten digits and opens no gate', (tester) async {
    final run = await signIn(
      tester,
      mode: AuthMode.signUp,
      phoneStatus: {'claimed': false, 'verified': false, 'required': true, 'needs_phone': true},
    );
    expect(find.text('Signed-in home'), findsOneWidget);
    expect(run.phonePosts, hasLength(1));
    expect(jsonDecode(run.phonePosts.single.body), {'phone_number': '9876543210'});
    expect(run.phonePosts.single.headers['Authorization'], 'Bearer access');
    expect(run.container.read(phoneGateProvider).needsPhone, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a number the server refuses opens the gate with what was typed and why', (tester) async {
    final run = await signIn(
      tester,
      mode: AuthMode.signUp,
      phoneStatus: {'claimed': false, 'verified': false, 'required': true, 'needs_phone': true},
      claimReply: () => json({'error': 'phone_unavailable', 'message': taken}, 409),
    );
    expect(find.text('Signed-in home'), findsOneWidget, reason: 'the email sign-in itself still succeeds');
    final gate = run.container.read(phoneGateProvider);
    expect(gate.needsPhone, isTrue);
    expect(gate.prefill, '9876543210');
    expect(gate.message, taken);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('with the lock off no phone is sent and nothing is blocked', (tester) async {
    final run = await signIn(
      tester,
      mode: AuthMode.signUp,
      phoneStatus: {'claimed': false, 'verified': false, 'required': false, 'needs_phone': false},
    );
    expect(find.text('Signed-in home'), findsOneWidget);
    expect(run.phonePosts, isEmpty);
    expect(run.container.read(phoneGateProvider).needsPhone, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an older server without the phone route never blocks sign-up', (tester) async {
    final run = await signIn(
      tester,
      mode: AuthMode.signUp,
      phoneStatus: {'error': 'not found'},
      phoneStatusCode: 404,
    );
    expect(find.text('Signed-in home'), findsOneWidget);
    expect(run.phonePosts, isEmpty);
    expect(run.container.read(phoneGateProvider).needsPhone, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('logging in to an account with no phone opens the gate and skips the profile call', (tester) async {
    final run = await signIn(
      tester,
      mode: AuthMode.logIn,
      phoneStatus: {'claimed': false, 'verified': false, 'required': true, 'needs_phone': true},
    );
    expect(find.text('Signed-in home'), findsOneWidget);
    expect(run.phonePosts, isEmpty, reason: 'log-in has no phone to send');
    final gate = run.container.read(phoneGateProvider);
    expect(gate.needsPhone, isTrue);
    expect(gate.prefill, isNull);
    expect(run.profileCalls, 0, reason: 'a profile needs a phone when the lock is on');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('logging in to an account that already has a phone goes straight through', (tester) async {
    final run = await signIn(
      tester,
      mode: AuthMode.logIn,
      phoneStatus: {'claimed': true, 'verified': false, 'required': true, 'needs_phone': false, 'phone_hint': '+91 •••• 3210'},
    );
    expect(find.text('Signed-in home'), findsOneWidget);
    expect(run.container.read(phoneGateProvider).needsPhone, isFalse);
    expect(run.profileCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
