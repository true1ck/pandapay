import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/consents_api.dart';
import 'package:pandapay/features/auth/login_screen.dart';

/// A4: DPDP §8.2 purpose-specific consent checkboxes on sign-up. Verifies
/// (1) the required Terms checkbox actually gates submission, and (2) a
/// successful sign-up writes one POST /consents call per purpose (terms,
/// crowdsource, marketing), not a single bundled write.
void main() {
  setUp(() {
    // TokenStore reads real SharedPreferences on every save() call
    // (_verifyOtp's success path) — without mock initial values the
    // platform channel call in a widget test can hang pumpAndSettle.
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap({required List<Override> overrides}) {
    // router.dart wraps LoginScreen in a Scaffold for real (see its own
    // GoRoute for AppRoute.signUp) — LoginScreen itself is a bare Container,
    // so TextField/CheckboxListTile need that same Material ancestor here.
    return ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: Scaffold(body: LoginScreen(mode: AuthMode.signUp))),
    );
  }

  testWidgets('Send code is a no-op and shows a validation message when Terms is unchecked',
      (tester) async {
    var otpRequested = false;
    final authApi = AuthApi(
      authBaseUrl: 'http://auth.test',
      client: MockClient((req) async {
        otpRequested = true;
        return http.Response('{}', 200);
      }),
    );

    await tester.pumpWidget(wrap(overrides: [authApiProvider.overrideWithValue(authApi)]));

    await tester.enterText(find.byType(TextField).at(0), 'newuser@example.com');
    await tester.enterText(find.byType(TextField).at(1), '9876543210');
    // Terms checkbox left unchecked deliberately.
    await tester.ensureVisible(find.text('Send code'));
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    expect(otpRequested, isFalse);
    expect(find.textContaining('accept the Terms'), findsOneWidget);
  });

  testWidgets('a successful sign-up writes one POST /consents call per purpose', (tester) async {
    final otpClient = MockClient((req) async {
      if (req.url.path.contains('request-email-otp')) return http.Response('{}', 200);
      if (req.url.path.contains('verify-email-otp')) {
        return http.Response(
          jsonEncode({'access_token': 'tok-abc', 'refresh_token': 'ref-abc'}),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final authApi = AuthApi(authBaseUrl: 'http://auth.test', client: otpClient);

    final profileClient = MockClient((req) async {
      return http.Response(
        jsonEncode({
          'profile': {'id': 'profile-new', 'display_name': null},
        }),
        201,
      );
    });

    final consentCalls = <Map<String, dynamic>>[];
    final consentsClient = MockClient((req) async {
      consentCalls.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{"consent":{}}', 201);
    });

    await tester.pumpWidget(wrap(overrides: [
      authApiProvider.overrideWithValue(authApi),
      profileApiProvider.overrideWithValue(
        ProfileApi(apiBaseUrl: 'http://api.test', accessToken: 'tok-abc', client: profileClient),
      ),
      consentsApiProvider.overrideWithValue(
        ConsentsApi(apiBaseUrl: 'http://api.test', accessToken: 'tok-abc', client: consentsClient),
      ),
    ]));

    await tester.enterText(find.byType(TextField).at(0), 'newuser@example.com');
    await tester.enterText(find.byType(TextField).at(1), '9876543210');
    await tester.ensureVisible(find.byType(CheckboxListTile).at(0));
    await tester.tap(find.byType(CheckboxListTile).at(0)); // required Terms
    await tester.pump();
    await tester.ensureVisible(find.text('Send code'));
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();

    // OTP step now showing.
    expect(find.text('Verification code'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '1234');
    await tester.tap(find.text('Verify & continue'));
    await tester.pumpAndSettle();

    expect(consentCalls.length, 3);
    final purposes = consentCalls.map((c) => c['purpose']).toSet();
    expect(purposes, {'terms', 'crowdsource', 'marketing'});

    final terms = consentCalls.firstWhere((c) => c['purpose'] == 'terms');
    expect(terms['granted'], isTrue);
    expect(terms['sourceScreen'], 'A4');

    // Crowdsource/marketing were left unchecked in this test.
    final crowdsource = consentCalls.firstWhere((c) => c['purpose'] == 'crowdsource');
    expect(crowdsource['granted'], isFalse);
  });
}
