import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/features/auth/add_phone_screen.dart';
import 'package:pandapay/features/auth/phone_gate_provider.dart';

const unavailable =
    "This number can't be used. If it is yours, sign in with the email you first used, or contact support.";

http.Response json(Map<String, Object?> body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<ProviderContainer> mount(
  WidgetTester tester,
  MockClient client, {
  String? prefill,
  String? message,
}) async {
  final container = ProviderContainer(
    overrides: [
      authApiProvider.overrideWithValue(
        AuthApi(authBaseUrl: 'https://auth.test', client: client),
      ),
      authenticatedHttpClientProvider.overrideWithValue(
        AuthenticatedHttpClient(inner: client, refreshAccessToken: () async => null),
      ),
      phoneGateProvider.overrideWith(
        (ref) => PhoneGateController(ref),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(accessTokenProvider.notifier).state = 'token';
  container.read(phoneGateProvider.notifier).needs(prefill: prefill, message: message);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AddPhoneScreen()),
    ),
  );
  return container;
}

/// The client streams its reply, which needs real async turns, not just frames.
Future<void> save(WidgetTester tester) async {
  await tester.tap(find.text('Save number'));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('a wrong number is explained on the spot and nothing is sent', (tester) async {
    var requests = 0;
    await mount(tester, MockClient((_) async { requests++; return json({'ok': true}); }));
    await tester.enterText(find.byType(TextField), '12345');
    await tester.tap(find.text('Save number'));
    await tester.pump();
    expect(find.text('Enter a valid 10-digit Indian mobile number.'), findsOneWidget);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a good number is sent as ten digits and closes the gate', (tester) async {
    late http.Request seen;
    final container = await mount(
      tester,
      MockClient((request) async {
        seen = request;
        return json({'ok': true, 'phone_hint': '+91 •••• 3210'});
      }),
    );
    await tester.enterText(find.byType(TextField), '+91 98765 43210');
    await save(tester);
    expect(seen.method, 'POST');
    expect(jsonDecode(seen.body), {'phone_number': '9876543210'});
    expect(container.read(phoneGateProvider).needsPhone, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a number that is taken shows the server wording and a support way out', (tester) async {
    final container = await mount(
      tester,
      MockClient((_) async => json({'error': 'phone_unavailable', 'message': unavailable}, 409)),
    );
    await tester.enterText(find.byType(TextField), '9876543210');
    await save(tester);
    expect(find.text(unavailable), findsOneWidget);
    expect(find.text('It’s my number. Contact support'), findsOneWidget);
    expect(container.read(phoneGateProvider).needsPhone, isTrue, reason: 'still blocked');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('what was typed at sign-up and why it was refused are shown up front', (tester) async {
    await mount(
      tester,
      MockClient((_) async => json({'ok': true})),
      prefill: '9876543210',
      message: unavailable,
    );
    expect(find.text('9876543210'), findsOneWidget);
    expect(find.text(unavailable), findsOneWidget);
    expect(find.text('It’s my number. Contact support'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('too many tries and server trouble show a plain message and keep the gate shut', (tester) async {
    final container = await mount(
      tester,
      MockClient((_) async => json({'error': 'too_many_attempts', 'message': 'Too many tries today. Please try again tomorrow or contact support.'}, 429)),
    );
    await tester.enterText(find.byType(TextField), '9876543210');
    await save(tester);
    expect(find.textContaining('Too many tries today'), findsOneWidget);
    expect(find.text('Save number'), findsOneWidget, reason: 'the button comes back after a failure');
    expect(container.read(phoneGateProvider).needsPhone, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
