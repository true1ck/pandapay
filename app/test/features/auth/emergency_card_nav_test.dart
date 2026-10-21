import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/features/onboarding/welcome_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the auth screen does not expose a guest or emergency bypass', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'pandapay_app.onboarding_complete_v1': false,
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionInitProvider.overrideWith((ref) async {})],
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

    // The account actions appear after the two automatically played story
    // slides. Advance fake time through both dwell periods and page
    // transitions; pumpAndSettle alone cannot fire the delayed timers.
    await tester.pump(const Duration(milliseconds: 4850));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump(const Duration(milliseconds: 6600));
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('Make every\ncard count.'), findsOneWidget);

    // Tap "I already have an account".
    await tester.ensureVisible(find.text('I already have an account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I already have an account'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Use without an account'), findsNothing);
    expect(find.textContaining('no sign-in needed'), findsNothing);
  });
}
