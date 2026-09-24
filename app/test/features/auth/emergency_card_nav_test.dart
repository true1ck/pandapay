import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/features/onboarding/welcome_screen.dart';
import 'package:pandapay/features/tools/emergency_card_info_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'first-time user can navigate from Welcome -> Login -> EmergencyCardInfoScreen without bouncing back',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'pandapay_app.onboarding_complete_v1': false,
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionInitProvider.overrideWith((ref) async {}),
          ],
          child: Consumer(
            builder: (context, ref, _) => MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: ref.watch(goRouterProvider),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(WelcomeScreen), findsOneWidget);

      // Tap "I already have an account"
      await tester.tap(find.text('I already have an account'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);

      // Tap "Lost or stolen card? Get emergency help — no sign-in needed"
      final emergencyLink = find.text(
        'Lost or stolen card? Get emergency help — no sign-in needed',
      );
      expect(emergencyLink, findsOneWidget);
      await tester.ensureVisible(emergencyLink);
      await tester.tap(emergencyLink);
      await tester.pumpAndSettle();

      // Verify it navigated to EmergencyCardInfoScreen and didn't redirect back to Welcome
      expect(find.byType(EmergencyCardInfoScreen), findsOneWidget);
    },
  );
}
