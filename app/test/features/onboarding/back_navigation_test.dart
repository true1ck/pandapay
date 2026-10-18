import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/router.dart';
import 'package:pandapay/features/auth/login_screen.dart';
import 'package:pandapay/features/onboarding/welcome_screen.dart';

Future<void> _finishPageTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump();
}

void main() {
  testWidgets(
    'welcome auto-plays both stories before showing account actions',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WelcomeScreen())),
      );
      await tester.pump();

      expect(find.text('A little less\ncard chaos.'), findsOneWidget);
      expect(find.text('Create account'), findsNothing);

      await tester.pump(const Duration(milliseconds: 4850));
      await _finishPageTransition(tester);
      expect(find.text('A clearer view.\nA calmer month.'), findsOneWidget);
      expect(find.text('Create account'), findsNothing);

      await tester.pump(const Duration(milliseconds: 6600));
      await _finishPageTransition(tester);
      expect(find.text('Make every\ncard count.'), findsOneWidget);
      expect(find.text('Create account'), findsOneWidget);
      expect(find.text('I already have an account'), findsOneWidget);
    },
  );

  testWidgets('welcome can be swiped both ways through all three pages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WelcomeScreen())),
    );
    await tester.pump();
    final pages = find.byKey(const ValueKey('welcome-pages'));

    for (final title in [
      'A clearer view.\nA calmer month.',
      'Make every\ncard count.',
    ]) {
      await tester.drag(pages, const Offset(-300, 0));
      await _finishPageTransition(tester);
      expect(find.text(title), findsOneWidget);
      expect(
        tester.widget<PageView>(pages).controller!.page,
        title.startsWith('Make every') ? 2 : 1,
      );
    }
    expect(find.text('Create account'), findsOneWidget);

    for (final title in [
      'A clearer view.\nA calmer month.',
      'A little less\ncard chaos.',
    ]) {
      await tester.drag(pages, const Offset(300, 0));
      await _finishPageTransition(tester);
      expect(find.text(title), findsOneWidget);
      expect(
        tester.widget<PageView>(pages).controller!.page,
        title.startsWith('A little less') ? 0 : 1,
      );
      expect(find.text('Create account'), findsNothing);
    }
  });

  testWidgets('dots navigate and a held swipe pauses automatic progression', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WelcomeScreen())),
    );
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('View introduction 3'));
    await tester.pump();
    await _finishPageTransition(tester);
    expect(find.text('Create account'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('View introduction 1'));
    await tester.pump();
    await _finishPageTransition(tester);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    expect(find.text('A little less\ncard chaos.'), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('welcome-pages'))),
    );
    await gesture.moveBy(const Offset(-35, 0));
    await tester.pump(const Duration(seconds: 7));
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      lessThan(.2),
    );
    await gesture.up();
    await _finishPageTransition(tester);

    await tester.pump(const Duration(seconds: 3));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    await tester.pump(const Duration(milliseconds: 1850));
    await _finishPageTransition(tester);
    expect(find.text('A clearer view.\nA calmer month.'), findsOneWidget);
  });

  testWidgets('welcome opens account creation directly', (tester) async {
    final router = GoRouter(
      initialLocation: AppRoute.welcome,
      routes: [
        GoRoute(
          path: AppRoute.welcome,
          builder: (_, _) => const WelcomeScreen(),
        ),
        GoRoute(
          path: AppRoute.signUp,
          builder: (_, _) =>
              const Scaffold(body: LoginScreen(mode: AuthMode.signUp)),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pump(const Duration(milliseconds: 4850));
    await _finishPageTransition(tester);
    await tester.pump(const Duration(milliseconds: 6600));
    await _finishPageTransition(tester);
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Make every\ncard count.'), findsOneWidget);
  });
}
