import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/features/onboarding/first_card_intro.dart';
import 'package:pandapay/features/onboarding/welcome_screen.dart';

void main() {
  testWidgets(
    'account entry remains usable on a narrow screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final screen in <Widget>[
        const WelcomeScreen(),
        const LoginScreen(mode: AuthMode.logIn),
        const LoginScreen(mode: AuthMode.signUp),
        FirstCardIntroduction(onAdd: () {}, onSkip: () {}),
      ]) {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(body: screen),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${screen.runtimeType} should scroll rather than overflow',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'OTP accepts pasted digits and stays usable with a narrow keyboard viewport',
    (tester) async {
      tester.view.physicalSize = const Size(320, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final authApi = AuthApi(
        authBaseUrl: 'http://auth.test',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authApiProvider.overrideWithValue(authApi)],
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(body: LoginScreen(mode: AuthMode.logIn)),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).at(0), 'test@example.com');
      await tester.enterText(find.byType(TextField).at(1), '9876543210');
      // Send code only enables once the fields validate on the next frame.
      await tester.pump();
      await tester.ensureVisible(find.text('Send code'));
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '12a345');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '1234',
      );
      await tester.ensureVisible(find.text('Verify & continue'));
      expect(tester.takeException(), isNull);
    },
  );
}
