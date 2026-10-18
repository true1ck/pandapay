import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/features/auth/account_recovery_screen.dart';
import 'package:pandapay/features/auth/login_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> contacts({String email = 'o•••@gmail.com'}) => {
    'phone_verified': true,
    'email_verified': true,
    'has_backup_channel': true,
    'email_hint': email,
    'phone_hint': '+91 •••• 1234',
  };

  http.Response jsonResponse(Object body, [int status = 200]) =>
      http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<void> verify(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), '5678');
    await tester.ensureVisible(find.text('Verify code'));
    await tester.tap(find.text('Verify code'));
    await tester.pumpAndSettle();
  }

  Future<void> mountRecovery(
    WidgetTester tester,
    MockClient client, {
    String identifier = 'user@example.com',
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDeviceIdProvider.overrideWith((ref) async => 'recovery-device'),
          authApiProvider.overrideWithValue(
            AuthApi(authBaseUrl: 'http://auth.test', client: client),
          ),
        ],
        child: const MaterialApp(home: AccountRecoveryScreen()),
      ),
    );
    await tester.enterText(find.byType(TextField), identifier);
    await tester.tap(find.text('Send sign-in code'));
    await tester.pumpAndSettle();
  }

  testWidgets('failed delivery stays on the contact screen with a send error', (
    tester,
  ) async {
    await mountRecovery(
      tester,
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error':
                'Unable to send a sign-in code right now. Please try again later.',
          }),
          503,
        ),
      ),
    );
    expect(
      find.textContaining('Unable to send a sign-in code'),
      findsOneWidget,
    );
    expect(find.text('Send sign-in code'), findsOneWidget);
    expect(find.text('Verify code'), findsNothing);
  });

  testWidgets(
    'verified email shows masked phone without activating a session',
    (tester) async {
      await mountRecovery(
        tester,
        MockClient((request) async {
          if (request.url.path == '/auth/verify-email-otp') {
            expect(jsonDecode(request.body)['recovery_only'], true);
            return http.Response(
              jsonEncode({
                'access_token': 'pending',
                'refresh_token': 'pending-refresh',
              }),
              200,
            );
          }
          if (request.url.path == '/users/me/recovery-contact-check') {
            expect(jsonDecode(request.body)['last_four'], '1234');
            return jsonResponse({'ok': true});
          }
          if (request.url.path == '/auth/request-email-otp') {
            expect(jsonDecode(request.body)['recovery_only'], true);
            return jsonResponse({'ok': true});
          }
          return jsonResponse(
            request.method == 'GET' ? contacts() : {'ok': true},
          );
        }),
      );
      expect(find.text('Return to sign in'), findsNothing);
      await verify(tester);
      expect(find.text('+91 •••• 1234'), findsOneWidget);
      expect(find.text('Return to sign in'), findsOneWidget);
      expect(find.text('Last 4 letters or digits'), findsOneWidget);
      expect(find.text('Continue signing in'), findsNothing);
      expect(
        ProviderScope.containerOf(
          tester.element(find.byType(AccountRecoveryScreen)),
        ).read(accessTokenProvider),
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed linked-contact lookup retries without consuming the OTP again',
    (tester) async {
      var verifications = 0, lookups = 0;
      await mountRecovery(
        tester,
        MockClient((request) async {
          if (request.url.path == '/auth/verify-email-otp') {
            verifications++;
            return http.Response(jsonEncode({'access_token': 'pending'}), 200);
          }
          if (request.method == 'GET') {
            lookups++;
            return lookups == 1
                ? http.Response(
                    jsonEncode({'error': 'Unable to load linked contacts.'}),
                    503,
                  )
                : jsonResponse(contacts());
          }
          return http.Response('{}', 200);
        }),
      );
      await verify(tester);
      expect(find.text('Return to sign in'), findsNothing);
      await tester.ensureVisible(find.text('Show linked contact'));
      await tester.tap(find.text('Show linked contact'));
      await tester.pumpAndSettle();
      expect(verifications, 1);
      expect(find.text('+91 •••• 1234'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'phone recovery shows masked email and replaces it only after a new code',
    (tester) async {
      var saves = 0;
      await mountRecovery(
        tester,
        MockClient((request) async {
          if (request.url.path == '/auth/verify-otp') {
            return http.Response(jsonEncode({'access_token': 'pending'}), 200);
          }
          if (request.url.path == '/auth/request-otp') {
            expect(jsonDecode(request.body)['recovery_only'], true);
            return jsonResponse({'ok': true});
          }
          if (request.url.path.endsWith('/recovery-contact/request')) {
            expect(jsonDecode(request.body)['identifier'], 'new@gmail.com');
            return http.Response(
              jsonEncode({'challenge': 'bound-challenge'}),
              200,
            );
          }
          if (request.url.path.endsWith('/recovery-contact/verify')) {
            saves++;
            expect(jsonDecode(request.body)['challenge'], 'bound-challenge');
            return jsonResponse(contacts(email: 'n•••@gmail.com'));
          }
          return jsonResponse(
            request.method == 'GET' ? contacts() : {'ok': true},
          );
        }),
        identifier: '+919876541234',
      );
      await verify(tester);
      expect(find.text('o•••@gmail.com'), findsOneWidget);
      await tester.ensureVisible(find.text('I can’t access this email'));
      await tester.tap(find.text('I can’t access this email'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'new@gmail.com');
      await tester.tap(find.text('Send verification code'));
      await tester.pumpAndSettle();
      expect(saves, 0);
      await tester.enterText(find.byType(TextField), '5678');
      await tester.tap(find.text('Verify & save contact'));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(find.text('n•••@gmail.com'), findsOneWidget);
      expect(
        ProviderScope.containerOf(
          tester.element(find.byType(AccountRecoveryScreen)),
        ).read(accessTokenProvider),
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('resend waits for the cooldown and displays delivery failure', (
    tester,
  ) async {
    var requests = 0;
    await mountRecovery(
      tester,
      MockClient((_) async {
        requests++;
        return requests == 1
            ? http.Response(jsonEncode({'ok': true}), 200)
            : http.Response(
                jsonEncode({
                  'error':
                      'Unable to send a sign-in code right now. Please try again later.',
                }),
                503,
              );
      }),
    );
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Resend code in 02:00'),
          )
          .onPressed,
      isNull,
    );
    await tester.pump(const Duration(seconds: 120));
    await tester.pumpAndSettle();
    final resend = find.text('Didn’t get the code? Resend code');
    await tester.ensureVisible(resend);
    await tester.tap(resend);
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(
      find.textContaining('Unable to send a sign-in code'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'second check returns to sign-in without activating recovery tokens',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localDeviceIdProvider.overrideWith(
              (ref) async => 'recovery-device',
            ),
            authApiProvider.overrideWithValue(
              AuthApi(
                authBaseUrl: 'http://auth.test',
                client: MockClient((request) async {
                  if (request.url.path == '/auth/request-email-otp') {
                    return jsonResponse({'ok': true});
                  }
                  if (request.url.path == '/auth/verify-email-otp') {
                    return jsonResponse({'access_token': 'pending'});
                  }
                  if (request.url.path == '/users/me/recovery-status') {
                    return jsonResponse(contacts());
                  }
                  if (request.url.path == '/users/me/recovery-contact-check') {
                    expect(jsonDecode(request.body)['last_four'], '1234');
                    return jsonResponse({'ok': true});
                  }
                  return jsonResponse({'ok': true});
                }),
              ),
            ),
          ],
          child: MaterialApp(
            home: const Scaffold(body: LoginScreen(mode: AuthMode.logIn)),
          ),
        ),
      );
      final loginFields = find.byType(TextField);
      await tester.enterText(loginFields.at(0), 'old@example.com');
      await tester.enterText(loginFields.at(1), '+919876548102');
      await tester.ensureVisible(find.text('Need help signing in?'));
      await tester.tap(find.text('Need help signing in?'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.tap(find.text('Send sign-in code'));
      await tester.pumpAndSettle();
      await verify(tester);
      await tester.enterText(find.byType(TextField), '1234');
      await tester.ensureVisible(find.text('Return to sign in'));
      await tester.tap(find.text('Return to sign in'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      final returnedFields = find.byType(TextField);
      expect(returnedFields, findsNWidgets(2));
      expect(
        tester.widget<TextField>(returnedFields.at(0)).controller!.text,
        isEmpty,
      );
      expect(
        tester.widget<TextField>(returnedFields.at(1)).controller!.text,
        isEmpty,
      );
      expect(
        ProviderScope.containerOf(
          tester.element(find.byType(LoginScreen)),
        ).read(accessTokenProvider),
        isNull,
      );
    },
  );

  testWidgets('an active code explains the block and shows the resend timer', (
    tester,
  ) async {
    await mountRecovery(
      tester,
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'message':
                'An OTP is already active. Please wait a moment before requesting a new one.',
          }),
          429,
        ),
      ),
    );
    expect(
      find.textContaining('A code request is still active'),
      findsOneWidget,
    );
    expect(find.text('Resend code in 02:00'), findsOneWidget);
    expect(find.text('Verify code'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recovery code field requests native one-time-code autofill', (
    tester,
  ) async {
    final authApi = AuthApi(
      authBaseUrl: 'http://auth.test',
      client: MockClient((_) async => http.Response(jsonEncode({}), 200)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authApiProvider.overrideWithValue(authApi)],
        child: const MaterialApp(home: AccountRecoveryScreen()),
      ),
    );
    await tester.enterText(find.byType(TextField), 'user@example.com');
    await tester.tap(find.text('Send sign-in code'));
    await tester.pumpAndSettle();

    final codeField = tester.widget<TextField>(find.byType(TextField));
    expect(codeField.autofillHints, const [AutofillHints.oneTimeCode]);
    expect(codeField.focusNode?.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), '12a345');
    expect(codeField.controller!.text, '1234');
  });
}
