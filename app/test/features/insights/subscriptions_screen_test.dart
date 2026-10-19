import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/subscriptions_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  testWidgets(
    'does not ask a signed-in user to sign in when the report is unavailable',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accessTokenProvider.overrideWith((ref) => 'restored-session'),
            recurringReportProvider.overrideWith((ref) async => null),
          ],
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign in to find your subscriptions'), findsNothing);
      expect(find.text('Subscriptions are still loading'), findsOneWidget);
    },
  );

  testWidgets('shows only named subscriptions with a renewal date', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recurringReportProvider.overrideWith((ref) async {
            return RecurringReport(
              series: [
                RecurringSeries(
                  id: 'bad-number',
                  displayName: '7308080808',
                  typicalAmount: Money.fromRupees(2000),
                  cadenceDays: 30,
                  occurrenceCount: 1,
                  annualCost: Money.fromRupees(24333.33),
                  nextExpectedOn: DateTime(2026, 11, 1),
                ),
                RecurringSeries(
                  id: 'bad-label',
                  displayName: 'MONTHLY',
                  typicalAmount: Money.fromRupees(1649),
                  cadenceDays: 30,
                  occurrenceCount: 1,
                  annualCost: Money.fromRupees(20000),
                  nextExpectedOn: DateTime(2026, 11, 1),
                ),
                RecurringSeries(
                  id: 'openai',
                  displayName: 'OpenAI',
                  typicalAmount: Money.fromRupees(1999),
                  cadenceDays: 30,
                  occurrenceCount: 3,
                  annualCost: Money.fromRupees(24321.17),
                  nextExpectedOn: DateTime(2026, 11, 1),
                ),
              ],
              totalAnnual: Money.fromRupees(68654.50),
            );
          }),
        ],
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 subscription'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.textContaining('Renews around 1 Nov 2026'), findsOneWidget);
    expect(find.text('7308080808'), findsNothing);
    expect(find.text('MONTHLY'), findsNothing);
    expect(find.text('Not a subscription'), findsNothing);
  });

  testWidgets(
    'filters out raw VPAs and fuel stations, and renders AutoPay badge on mandates',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recurringReportProvider.overrideWith((ref) async {
              return RecurringReport(
                series: [
                  RecurringSeries(
                    id: 'vpa-charge',
                    displayName: 'paytm-98510@ptys',
                    typicalAmount: Money.fromRupees(210),
                    cadenceDays: 8,
                    occurrenceCount: 5,
                    annualCost: Money.fromRupees(9581.25),
                    nextExpectedOn: DateTime(2026, 11, 1),
                  ),
                  RecurringSeries(
                    id: 'fuel-charge',
                    displayName: 'Kavlekar petroleum',
                    typicalAmount: Money.fromRupees(500),
                    cadenceDays: 70,
                    occurrenceCount: 4,
                    annualCost: Money.fromRupees(2570.42),
                    nextExpectedOn: DateTime(2026, 12, 17),
                  ),
                  RecurringSeries(
                    id: 'openai-mandate',
                    displayName: 'OpenAILLC',
                    typicalAmount: Money.fromRupees(1999),
                    cadenceDays: 30,
                    occurrenceCount: 1,
                    annualCost: Money.fromRupees(24321.17),
                    nextExpectedOn: DateTime(2026, 11, 19),
                    cardName: 'Axis Bank Card XX7105',
                    isMandate: true,
                    detectionSource: 'mandate',
                  ),
                ],
                totalAnnual: Money.fromRupees(24321.17),
              );
            }),
          ],
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 subscription'), findsOneWidget);
      expect(find.text('OpenAILLC'), findsOneWidget);
      expect(find.text('AutoPay'), findsOneWidget);
      expect(find.text('Axis Bank Card XX7105'), findsOneWidget);
      expect(find.text('paytm-98510@ptys'), findsNothing);
      expect(find.text('Kavlekar petroleum'), findsNothing);
    },
  );
}
