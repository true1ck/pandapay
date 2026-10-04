import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/features/onboarding/welcome_screen.dart';

void main() {
  testWidgets('welcome opens account creation directly', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: AppRoute.welcome,
      routes: [
        GoRoute(
          path: AppRoute.welcome,
          builder: (_, _) => const WelcomeScreen(),
        ),
        GoRoute(
          path: AppRoute.signUp,
          builder: (_, _) => const Scaffold(
            body: LoginScreen(mode: AuthMode.signUp),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(
      find.text('Know which card to use — before you pay.'),
      findsOneWidget,
    );
  });
}
