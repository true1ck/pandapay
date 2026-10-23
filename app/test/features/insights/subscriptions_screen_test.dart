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

    expect(find.text('1 active'), findsOneWidget);
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

      expect(find.text('1 active'), findsOneWidget);
      expect(find.text('OpenAILLC'), findsOneWidget);
      expect(find.text('Monthly AutoPay'), findsOneWidget);
      expect(find.text('Axis Bank Card XX7105'), findsOneWidget);
      expect(find.text('paytm-98510@ptys'), findsNothing);
      expect(find.text('Kavlekar petroleum'), findsNothing);
    },
  );

  testWidgets('shows an active mandate without inventing renewal details', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recurringReportProvider.overrideWith((ref) async {
            return RecurringReport(
              series: [
                RecurringSeries(
                  id: 'incomplete-mandate',
                  displayName: 'A service',
                  typicalAmount: Money.zero(),
                  cadenceDays: 30,
                  occurrenceCount: 1,
                  annualCost: Money.zero(),
                  isMandate: true,
                  detectionSource: 'mandate',
                  autopayStatus: 'active',
                  cadenceConfirmed: false,
                ),
              ],
              totalAnnual: Money.zero(),
            );
          }),
        ],
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A service'), findsOneWidget);
    expect(find.text('AutoPay Active'), findsOneWidget);
    expect(find.text('Cadence not confirmed'), findsOneWidget);
    expect(find.text('Amount not stated in the AutoPay alert'), findsOneWidget);
    expect(find.textContaining('Renews around'), findsNothing);
  });

  testWidgets('marks an old observed series for review instead of showing a renewal date', (
    tester,
  ) async {
    final lastSeen = DateTime.now().subtract(const Duration(days: 100));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recurringReportProvider.overrideWith((ref) async {
            return RecurringReport(
              series: [
                RecurringSeries(
                  id: 'stale-observed',
                  displayName: 'Old service',
                  typicalAmount: Money.fromRupees(499),
                  cadenceDays: 30,
                  occurrenceCount: 4,
                  annualCost: Money.fromRupees(5988),
                  lastSeenOn: lastSeen,
                  nextExpectedOn: DateTime.now().add(const Duration(days: 3)),
                ),
              ],
              totalAnnual: Money.fromRupees(5988),
            );
          }),
        ],
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Needs review'), findsOneWidget);
    expect(find.textContaining('No recent charge detected since'), findsOneWidget);
    expect(find.textContaining('Renews around'), findsNothing);
  });

  testWidgets('never presents a past AutoPay date as an upcoming renewal', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recurringReportProvider.overrideWith((ref) async {
            return RecurringReport(
              series: [
                RecurringSeries(
                  id: 'past-autopay-date',
                  displayName: 'Google Play',
                  typicalAmount: Money.fromRupees(1850),
                  cadenceDays: 30,
                  occurrenceCount: 1,
                  annualCost: Money.fromRupees(22508.33),
                  nextExpectedOn: DateTime(2025, 7, 4),
                  isMandate: true,
                  detectionSource: 'mandate',
                  autopayStatus: 'active',
                ),
              ],
              totalAnnual: Money.fromRupees(22508.33),
            );
          }),
        ],
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Google Play'), findsOneWidget);
    expect(find.text('Needs review'), findsOneWidget);
    expect(find.text('Saved renewal date has passed; please review it'), findsOneWidget);
    expect(find.textContaining('Renews around 4 Jul 2025'), findsNothing);
  });

  testWidgets('filters by cadence and displays clear AutoPay frequency labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recurringReportProvider.overrideWith((ref) async {
            return RecurringReport(
              series: [
                RecurringSeries(
                  id: 'netflix-monthly',
                  displayName: 'Netflix',
                  typicalAmount: Money.fromRupees(649),
                  cadenceDays: 30,
                  occurrenceCount: 3,
                  annualCost: Money.fromRupees(7788),
                  nextExpectedOn: DateTime(2026, 11, 15),
                  isMandate: true,
                  autopayStatus: 'active',
                ),
                RecurringSeries(
                  id: 'amazon-prime-yearly',
                  displayName: 'Amazon Prime',
                  typicalAmount: Money.fromRupees(1499),
                  cadenceDays: 365,
                  occurrenceCount: 2,
                  annualCost: Money.fromRupees(1499),
                  nextExpectedOn: DateTime(2027, 5, 20),
                  isMandate: true,
                  autopayStatus: 'active',
                ),
                RecurringSeries(
                  id: 'gym-monthly',
                  displayName: 'Cult Fit',
                  typicalAmount: Money.fromRupees(1200),
                  cadenceDays: 30,
                  occurrenceCount: 2,
                  annualCost: Money.fromRupees(14400),
                  nextExpectedOn: DateTime(2026, 11, 10),
                  isMandate: false,
                  autopayStatus: 'unknown',
                ),
              ],
              totalAnnual: Money.fromRupees(23687),
            );
          }),
        ],
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Frequency labels for recurring items
    expect(find.text('Monthly AutoPay', skipOffstage: false), findsNWidgets(2));
    expect(find.text('Yearly AutoPay', skipOffstage: false), findsOneWidget);

    // Cadence filter chips present
    expect(find.text('All (3)'), findsOneWidget);
    expect(find.text('Monthly (2)'), findsOneWidget);
    expect(find.text('Quarterly (0)'), findsOneWidget);
    expect(find.text('Yearly (1)'), findsOneWidget);

    // Tap Monthly filter
    await tester.tap(find.text('Monthly (2)'));
    await tester.pumpAndSettle();

    // Monthly items visible, yearly hidden
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('Cult Fit', skipOffstage: false), findsOneWidget);
    expect(find.text('Amazon Prime'), findsNothing);
    expect(find.text('Your monthly AutoPay spend'), findsOneWidget);

    // Tap Yearly filter
    await tester.tap(find.text('Yearly (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Amazon Prime'), findsOneWidget);
    expect(find.text('Netflix'), findsNothing);
    expect(find.text('Cult Fit'), findsNothing);
    expect(find.text('Your yearly AutoPay spend'), findsOneWidget);

    // Tap Quarterly (0) filter
    await tester.tap(find.text('Quarterly (0)'));
    await tester.pumpAndSettle();

    expect(find.text('No quarterly AutoPay found'), findsOneWidget);
    expect(find.text('Netflix'), findsNothing);

    // Tap All filter
    await tester.tap(find.text('All (3)'));
    await tester.pumpAndSettle();

    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('Amazon Prime'), findsOneWidget);
    expect(find.text('Cult Fit', skipOffstage: false), findsOneWidget);
    expect(find.text('Your recurring spend'), findsOneWidget);
  });
}
