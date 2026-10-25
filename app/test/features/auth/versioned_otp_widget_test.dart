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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> mount(WidgetTester tester, {bool busy = false}) async {
    final api = AuthApi(
      authBaseUrl: 'https://auth.test',
      versionedOtpEnabled: true,
      client: MockClient((r) async {
        expect(r.url.path, '/auth/v2/request-email-otp');
        expect(jsonDecode(r.body), {
          'email': 'person@example.test',
          'device_id': 'test-device',
        });
        return http.Response(
          jsonEncode(
            busy
                ? {'message': 'An OTP is already active.'}
                : {
                    'ok': true,
                    'version': 2,
                    'challenge_id': 'bc3f590c-b3c9-412c-98eb-1be64946cb70',
                    'code_length': 6,
                    'expires_in': 120,
                  },
          ),
          busy ? 429 : 200,
        );
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authApiProvider.overrideWithValue(api),
          localDeviceIdProvider.overrideWith((ref) async => 'test-device'),
        ],
        child: const MaterialApp(home: Scaffold(body: LoginScreen())),
      ),
    );
    await tester.enterText(find.byType(TextField).at(0), 'person@example.test');
    await tester.enterText(find.byType(TextField).at(1), '9999999999');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'v2 login displays six digits and filters code without changing existing fields',
    (tester) async {
      await mount(tester);
      expect(
        find.text('Enter the 6-digit verification code sent to'),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autofillHints, [AutofillHints.oneTimeCode]);
      await tester.enterText(find.byType(TextField), '12a345678');
      expect(field.controller!.text, '123456');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'missing v2 challenge does not pretend another devices active code can be verified',
    (tester) async {
      await mount(tester, busy: true);
      expect(find.text('Send code'), findsOneWidget);
      expect(find.text('Verify & continue'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
