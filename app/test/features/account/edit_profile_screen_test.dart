import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/account_name_api.dart';
import 'package:pandapay/data/phone_api.dart';
import 'package:pandapay/features/account/edit_profile_screen.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

PhoneStatus typed(String hint) => PhoneStatus(
  claimed: true,
  verified: false,
  required: true,
  needsPhone: false,
  phoneHint: hint,
);

Future<List<http.Request>> mount(
  WidgetTester tester, {
  Map<String, dynamic>? profile,
  PhoneStatus? phone,
  http.Response Function(http.Request)? reply,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final requests = <http.Request>[];
  final saved = <Map<String, dynamic>>[];
  final api = AccountNameApi(
    apiBaseUrl: 'https://api.test',
    authBaseUrl: 'https://auth.test',
    accessToken: 'token',
    client: MockClient((request) async {
      requests.add(request);
      return reply != null ? reply(request) : json({'profile': {'id': 'p1', 'display_name': 'Asha Rao'}, 'ok': true});
    }),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileProvider.overrideWith((ref) async => profile),
        phoneStatusProvider.overrideWith((ref) async => phone),
        accountNameApiProvider.overrideWithValue(api),
        profileSnapshotWriterProvider.overrideWithValue((p) async => saved.add(p)),
      ],
      child: const MaterialApp(home: EditProfileScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return requests;
}

void main() {
  testWidgets('shows the name, the masked phone and the email, with the email read-only', (tester) async {
    await mount(
      tester,
      profile: {'id': 'p1', 'display_name': 'Asha', 'email': 'asha@example.com'},
      phone: typed('+91 •••• 3210'),
    );
    expect(find.widgetWithText(TextField, 'Asha'), findsOneWidget);
    expect(find.text('+91 •••• 3210'), findsOneWidget);
    expect(find.text('asha@example.com'), findsOneWidget);
    expect(find.text('Change phone number'), findsOneWidget);
    expect(find.text('Verified'), findsNothing);
    expect(find.text('Not verified'), findsNothing);
    // Email has no text field: only the name is editable inline.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('no phone yet: offers Add phone number', (tester) async {
    await mount(tester, profile: {'id': 'p1', 'email': 'asha@example.com'}, phone: const PhoneStatus(
      claimed: false, verified: false, required: true, needsPhone: true,
    ));
    expect(find.text('Not added'), findsOneWidget);
    expect(find.text('Add phone number'), findsOneWidget);
  });

  testWidgets('Save is disabled until the name changes, then saves the cleaned name', (tester) async {
    final requests = await mount(
      tester,
      profile: {'id': 'p1', 'display_name': 'Asha', 'email': 'asha@example.com'},
      phone: typed('+91 •••• 3210'),
    );
    FilledButton save() => tester.widget<FilledButton>(
      find.descendant(of: find.byKey(const Key('edit-name-save')), matching: find.byType(FilledButton)),
    );
    expect(save().onPressed, isNull);

    await tester.enterText(find.byKey(const Key('edit-name-field')), '  Asha   Rao ');
    await tester.pump();
    expect(save().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('edit-name-save')));
    await tester.pumpAndSettle();

    expect(requests.first.method, 'PATCH');
    expect(requests.first.url.path, '/profile');
    expect(jsonDecode(requests.first.body), {'display_name': 'Asha Rao'});
    expect(requests.last.method, 'PUT');
    expect(requests.last.url.path, '/users/me/name');
    expect(find.text('Name updated'), findsOneWidget);
  });

  testWidgets('an empty name is refused without a request', (tester) async {
    final requests = await mount(
      tester,
      profile: {'id': 'p1', 'display_name': 'Asha', 'email': 'asha@example.com'},
      phone: typed('+91 •••• 3210'),
    );
    await tester.enterText(find.byKey(const Key('edit-name-field')), '   ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('edit-name-save')));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
  });

  testWidgets('a failed save keeps the form and shows an error', (tester) async {
    await mount(
      tester,
      profile: {'id': 'p1', 'display_name': 'Asha', 'email': 'asha@example.com'},
      phone: typed('+91 •••• 3210'),
      reply: (_) => json({'error': 'display_name_invalid'}, 400),
    );
    await tester.enterText(find.byKey(const Key('edit-name-field')), 'Someone');
    await tester.pump();
    await tester.tap(find.byKey(const Key('edit-name-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('can’t be saved'), findsOneWidget);
    expect(find.text('Name updated'), findsNothing);
  });

  test('name rules match the server', () {
    expect(AccountNameApi.problemWith(''), isNotNull);
    expect(AccountNameApi.problemWith('a' * 61), isNotNull);
    expect(AccountNameApi.problemWith('<b>'), isNotNull);
    expect(AccountNameApi.problemWith('Asha Rao'), isNull);
    expect(AccountNameApi.clean('  Asha \n  Rao '), 'Asha Rao');
  });
}
