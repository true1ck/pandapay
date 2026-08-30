import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/features/onboarding/account_choice_screen.dart';
import 'package:pandapay/features/onboarding/welcome_screen.dart';

void main() {
  testWidgets('the onboarding account-choice screen returns to welcome', (
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
          path: AppRoute.accountChoice,
          builder: (_, _) => const AccountChoiceScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    expect(find.text('How do you want to start?'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(
      find.text('Know which card to use — before you pay.'),
      findsOneWidget,
    );
  });
}
