import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/subscriptions_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
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
}
