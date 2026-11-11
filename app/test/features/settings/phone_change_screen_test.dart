import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/phone_api.dart';
import 'package:pandapay/features/settings/phone_change_screen.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const challengeBody = {
  'challenge': 'signed-token',
  'email_hint': 'm•••@gmail.com',
  'phone_hint': '+91 •••• 3210',
  'expires_in': 60,
  'code_length': 6,
};

Future<List<http.Request>> mount(
  WidgetTester tester,
  http.Response Function(http.Request) reply, {
  bool changing = false,
}) async {
  final requests = <http.Request>[];
  final api = PhoneApi(
    authBaseUrl: 'https://auth.test',
    accessToken: 'token',
    client: MockClient((request) async {
      requests.add(request);
      return reply(request);
    }),
  );
  final container = ProviderContainer(
    overrides: [
      phoneApiProvider.overrideWithValue(api),
      localDeviceIdProvider.overrideWith((ref) async => 'device-1'),
      phoneStatusProvider.overrideWith((ref) async => null),
      profileProvider.overrideWith((ref) async => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: PhoneChangeScreen(changing: changing)),
    ),
  );
  return requests;
}

Future<void> enterPhone(WidgetTester tester, String phone) async {
  await tester.enterText(find.byKey(const Key('phone-change-field')), phone);
  await tester.tap(find.text('Email me a code'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('adding: sends the ten digits and the device id, then asks for the emailed code', (tester) async {
    final requests = await mount(tester, (_) => json(challengeBody));
    await enterPhone(tester, '98765 43210');

    expect(requests.single.url.path, '/users/me/phone/change/request');
    expect(jsonDecode(requests.single.body), {'phone_number': '9876543210', 'device_id': 'device-1'});
    expect(find.textContaining('m•••@gmail.com'), findsOneWidget);
    expect(find.textContaining('+91 •••• 3210'), findsOneWidget);
    expect(find.byKey(const Key('phone-change-code')), findsOneWidget);
    expect(find.textContaining('Code expires in'), findsOneWidget);
  });

  testWidgets('wording never calls the number verified (the code proves the email, not the phone)', (tester) async {
    await mount(tester, (_) => json(challengeBody));
    expect(find.textContaining('verif', findRichText: true), findsNothing);
    await enterPhone(tester, '9876543210');
    expect(find.textContaining('verif', findRichText: true), findsNothing);
  });

  testWidgets('a bad number is caught before any request', (tester) async {
    final requests = await mount(tester, (_) => json(challengeBody));
    await enterPhone(tester, '12345');
    expect(requests, isEmpty);
    expect(find.text('Enter a valid 10-digit Indian mobile number.'), findsOneWidget);
  });

  testWidgets('a number someone else holds shows the server wording and stays on the form', (tester) async {
    await mount(
      tester,
      (_) => json({'error': 'phone_unavailable', 'message': "This number can't be used."}, 409),
    );
    await enterPhone(tester, '9876543210');
    expect(find.text("This number can't be used."), findsOneWidget);
    expect(find.byKey(const Key('phone-change-code')), findsNothing);
  });

  testWidgets('the right code saves the number and says so', (tester) async {
    final requests = await mount(tester, (request) {
      if (request.url.path.endsWith('/request')) return json(challengeBody);
      return json({'ok': true, 'phone_hint': '+91 •••• 3210'});
    });
    await enterPhone(tester, '9876543210');
    await tester.enterText(find.byKey(const Key('phone-change-code')), '123456');
    await tester.tap(find.text('Save number'));
    await tester.pumpAndSettle();

    expect(requests.last.url.path, '/users/me/phone/change/confirm');
    expect(jsonDecode(requests.last.body), {
      'challenge': 'signed-token',
      'code': '123456',
      'device_id': 'device-1',
    });
    expect(find.text('Phone number saved'), findsOneWidget);
  });

  testWidgets('changing: the done screen says changed', (tester) async {
    await mount(
      tester,
      (request) => request.url.path.endsWith('/request')
          ? json(challengeBody)
          : json({'ok': true, 'phone_hint': '+91 •••• 3210'}),
      changing: true,
    );
    expect(find.text('Change phone number'), findsOneWidget);
    await enterPhone(tester, '9876543210');
    await tester.enterText(find.byKey(const Key('phone-change-code')), '123456');
    await tester.tap(find.text('Save number'));
    await tester.pumpAndSettle();
    expect(find.text('Phone number changed'), findsOneWidget);
  });

  testWidgets('a wrong code shows the server message and clears the field', (tester) async {
    await mount(tester, (request) {
      if (request.url.path.endsWith('/request')) return json(challengeBody);
      return json({'error': 'code_invalid', 'message': 'That code is wrong or has expired.'}, 400);
    });
    await enterPhone(tester, '9876543210');
    await tester.enterText(find.byKey(const Key('phone-change-code')), '000000');
    await tester.tap(find.text('Save number'));
    await tester.pumpAndSettle();
    expect(find.text('That code is wrong or has expired.'), findsOneWidget);
    expect(find.text('Phone number saved'), findsNothing);
  });

  testWidgets('a code that is not 6 digits is refused without a request', (tester) async {
    final requests = await mount(tester, (_) => json(challengeBody));
    await enterPhone(tester, '9876543210');
    await tester.enterText(find.byKey(const Key('phone-change-code')), '123');
    await tester.tap(find.text('Save number'));
    await tester.pumpAndSettle();
    expect(requests.length, 1);
    expect(find.text('Enter the 6-digit code.'), findsOneWidget);
  });
}
