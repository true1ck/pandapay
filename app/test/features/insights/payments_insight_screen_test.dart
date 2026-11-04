import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/insights/payments_insight_screen.dart';
import 'package:pandapay/features/insights/subscriptions_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  setUp(() {
    BambooFonts.useSystemFontsForTests = true;
    SharedPreferences.setMockInitialValues({});
  });
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'test-session'),
          recurringReportProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(home: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Subscriptions reuses its content beneath one Payments header', (
    tester,
  ) async {
    await pump(
      tester,
      const PaymentsInsightScreen(initialTab: 'subscriptions'),
    );
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    for (final label in [
      'Payments',
      'Bills & commitments',
      'Due dates',
      'Subscriptions',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(SubscriptionsScreen), findsOneWidget);
    expect(find.text('Subscriptions are still loading'), findsOneWidget);
    expect(find.byTooltip('Add subscription'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing); // the parent owns navigation
  });
  testWidgets(
    'the existing standalone subscription body still has its chrome',
    (tester) async {
      await pump(tester, const SubscriptionsScreen());
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Subscriptions'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Add subscription'), findsOneWidget);
    },
  );
  testWidgets('embedded subscription content never brings a Scaffold', (
    tester,
  ) async {
    await pump(
      tester,
      const Scaffold(body: SubscriptionsScreen(showChrome: false)),
    );
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('Add subscription'), findsOneWidget);
    expect(find.text('Subscriptions are still loading'), findsOneWidget);
  });
  testWidgets('cadence selection survives leaving the Subscriptions tab', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'test-session'),
          recurringReportProvider.overrideWith(
            (ref) async => RecurringReport(
              series: [
                RecurringSeries(
                  id: 'spotify',
                  displayName: 'Spotify',
                  typicalAmount: const Money.fromPaise(14900),
                  cadenceDays: 30,
                  occurrenceCount: 3,
                  annualCost: const Money.fromPaise(178800),
                ),
                RecurringSeries(
                  id: 'netflix',
                  displayName: 'Netflix',
                  typicalAmount: const Money.fromPaise(49900),
                  cadenceDays: 365,
                  occurrenceCount: 3,
                  annualCost: const Money.fromPaise(49900),
                ),
              ],
              totalAnnual: const Money.fromPaise(228700),
            ),
          ),
          userCardsProvider.overrideWith((ref) async => const []),
          myCardsProvider.overrideWith((ref) async => const []),
          transactionsProvider.overrideWith((ref) async => const []),
          utilizationTransactionsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(
          home: PaymentsInsightScreen(initialTab: 'subscriptions'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monthly (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Spotify'), findsOneWidget);
    expect(find.text('Netflix'), findsNothing);
    await tester.tap(find.text('Due dates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subscriptions'));
    await tester.pumpAndSettle();
    expect(find.text('Spotify'), findsOneWidget);
    expect(find.text('Netflix'), findsNothing);
    final chip = tester.widget<ChoiceChip>(
      find.ancestor(
        of: find.text('Monthly (1)'),
        matching: find.byType(ChoiceChip),
      ),
    );
    expect(chip.selected, isTrue);
    expect(find.byType(AppBar), findsOneWidget);
  });
}
