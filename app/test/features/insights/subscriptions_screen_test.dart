import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/bills_projection_api.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/central_bills_section.dart';
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

  testWidgets('shows named service setup without inventing paid terms', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recurringReportProvider.overrideWith((ref) async {
            return const RecurringReport(
              series: [
                RecurringSeries(
                  id: 'openai-setup',
                  displayName: 'OpenAI',
                  typicalAmount: Money.zero(),
                  amountKnown: false,
                  cadenceDays: 0,
                  occurrenceCount: 0,
                  annualCost: Money.zero(),
                  detectionSource: 'central_projection',
                  setupConfirmed: true,
                  cadenceConfirmed: false,
                  engineStatus: 'candidate',
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

    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Setup confirmed'), findsOneWidget);
    expect(find.text('Setup confirmed — payment amount unknown'), findsOneWidget);
    expect(find.text('Paid amount not known'), findsOneWidget);
    expect(find.textContaining('Renews around'), findsNothing);
    expect(find.textContaining('Next payment'), findsNothing);
    expect(find.text('Free'), findsNothing);
  });

  testWidgets('filters out raw VPAs, fuel stations, and mandate-only records', (
    tester,
  ) async {
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

    expect(find.text('OpenAILLC'), findsNothing);
    expect(find.text('Monthly AutoPay'), findsNothing);
    expect(find.text('Axis Bank Card XX7105'), findsNothing);
    expect(find.text('paytm-98510@ptys'), findsNothing);
    expect(find.text('Kavlekar petroleum'), findsNothing);
  });

  testWidgets('does not show a mandate-only record as a subscription', (
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

    expect(find.text('A service'), findsNothing);
    expect(find.text('AutoPay Active'), findsNothing);
    expect(find.text('Cadence not confirmed'), findsNothing);
    expect(find.text('Amount not stated'), findsNothing);
    expect(find.textContaining('Renews around'), findsNothing);
  });

  testWidgets(
    'marks an old observed series for review instead of showing a renewal date',
    (tester) async {
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
      expect(
        find.textContaining('No recent charge detected since'),
        findsOneWidget,
      );
      expect(find.textContaining('Renews around'), findsNothing);
    },
  );

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

    expect(find.text('Google Play'), findsNothing);
    expect(find.text('Needs review'), findsNothing);
    expect(
      find.text('Saved renewal date has passed; please review it'),
      findsNothing,
    );
    expect(find.textContaining('Renews around 4 Jul 2025'), findsNothing);
  });

  testWidgets(
    'filters by cadence and displays clear AutoPay frequency labels',
    (tester) async {
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
                    isMandate: false,
                    autopayStatus: 'unknown',
                  ),
                  RecurringSeries(
                    id: 'amazon-prime-yearly',
                    displayName: 'Amazon Prime',
                    typicalAmount: Money.fromRupees(1499),
                    cadenceDays: 365,
                    occurrenceCount: 2,
                    annualCost: Money.fromRupees(1499),
                    nextExpectedOn: DateTime(2027, 5, 20),
                    isMandate: false,
                    autopayStatus: 'unknown',
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
      expect(find.text('Monthly', skipOffstage: false), findsNWidgets(2));
      expect(find.text('Yearly', skipOffstage: false), findsOneWidget);

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
      expect(find.text('Your monthly spend'), findsOneWidget);

      // Tap Yearly filter
      await tester.tap(find.text('Yearly (1)'));
      await tester.pumpAndSettle();

      expect(find.text('Amazon Prime'), findsOneWidget);
      expect(find.text('Netflix'), findsNothing);
      expect(find.text('Cult Fit'), findsNothing);
      expect(find.text('Your yearly spend'), findsOneWidget);

      // Tap Quarterly (0) filter
      await tester.tap(find.text('Quarterly (0)'));
      await tester.pumpAndSettle();

      expect(find.text('No quarterly subscriptions found'), findsOneWidget);
      expect(find.text('Netflix'), findsNothing);

      // Tap All filter
      await tester.tap(find.text('All (3)'));
      await tester.pumpAndSettle();

      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('Amazon Prime'), findsOneWidget);
      expect(find.text('Cult Fit', skipOffstage: false), findsOneWidget);
      expect(find.text('Your recurring spend'), findsOneWidget);
    },
  );

  testWidgets(
    'does not display a zero-cost mandate ceiling as a subscription',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recurringReportProvider.overrideWith((ref) async {
              return RecurringReport(
                series: [
                  RecurringSeries(
                    id: 'mandate:openai-7105',
                    displayName: 'OpenAILLC',
                    typicalAmount: Money.fromRupees(1999),
                    cadenceDays: 30,
                    occurrenceCount: 1,
                    annualCost: Money.fromRupees(24321.17),
                    nextExpectedOn: DateTime(2026, 11, 19),
                    cardName: 'Card XX7105',
                    isMandate: true,
                    autopayStatus: 'active',
                    detectionSource: 'mandate',
                    cadenceConfirmed: true,
                    engineStatus: 'confirmed',
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

      expect(find.text('OpenAILLC'), findsNothing);
      expect(find.text('Monthly AutoPay'), findsNothing);
      expect(find.text('Card XX7105'), findsNothing);
      expect(find.textContaining('1,999'), findsNothing);
    },
  );

  testWidgets(
    'displays subscription autopay authorizations (OpenAI LLC, Google Play) when no recurring series exist without showing empty state',
    (tester) async {
      final db = openInMemoryForTesting();
      final cache = ResponseCache(db);
      cache.financialStore.saveObservation('user:test', 'sms:openai', {
        'event_type': 'autopay',
        'biller_name': 'OpenAI LLC',
        'card_last4': '7105',
        'autopay_limit_paise': 199900,
        'received_at': '2026-10-18T09:00:00Z',
      });
      cache.financialStore.saveObservation('user:test', 'sms:googleplay', {
        'event_type': 'autopay',
        'biller_name': 'Google Play',
        'card_last4': '7105',
        'autopay_limit_paise': 185000,
        'received_at': '2026-10-18T09:00:00Z',
      });
      // Non-subscription autopay should NOT be shown on subscriptions screen
      cache.financialStore.saveObservation('user:test', 'sms:bescom', {
        'event_type': 'autopay',
        'biller_name': 'BESCOM',
        'card_last4': '7105',
        'autopay_limit_paise': 250000,
        'received_at': '2026-10-18T09:00:00Z',
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cacheNamespaceProvider.overrideWithValue('user:test'),
            responseCacheProvider.overrideWith((ref) async => cache),
            centralBillsProjectionProvider.overrideWith(
              (ref) async => const BillProjectionSnapshot.unavailable(),
            ),
            recurringReportProvider.overrideWith(
              (ref) async => const RecurringReport(
                series: [],
                totalAnnual: Money.zero(),
              ),
            ),
          ],
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Empty state MUST NOT replace the autopay authorizations
      expect(find.text('No subscriptions found yet'), findsNothing);
      expect(find.text('Autopay authorizations'), findsOneWidget);
      expect(find.text('OpenAI LLC'), findsOneWidget);
      expect(find.text('AutoPay limit ₹1999'), findsOneWidget);
      expect(find.text('Google Play'), findsOneWidget);
      expect(find.text('AutoPay limit ₹1850'), findsOneWidget);
      expect(find.text('BESCOM'), findsNothing);
      expect(find.text('AutoPay setup reported'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox.shrink());
      db.close();
    },
  );

  testWidgets(
    'displays subscription autopay authorizations together with active subscriptions',
    (tester) async {
      final db = openInMemoryForTesting();
      final cache = ResponseCache(db);
      cache.financialStore.saveObservation('user:test', 'sms:openai', {
        'event_type': 'autopay',
        'biller_name': 'OpenAI LLC',
        'card_last4': '7105',
        'autopay_limit_paise': 199900,
        'received_at': '2026-10-18T09:00:00Z',
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cacheNamespaceProvider.overrideWithValue('user:test'),
            responseCacheProvider.overrideWith((ref) async => cache),
            centralBillsProjectionProvider.overrideWith(
              (ref) async => const BillProjectionSnapshot.unavailable(),
            ),
            recurringReportProvider.overrideWith(
              (ref) async => RecurringReport(
                series: [
                  RecurringSeries(
                    id: 'netflix-active',
                    displayName: 'Netflix',
                    typicalAmount: Money.fromRupees(649),
                    cadenceDays: 30,
                    occurrenceCount: 3,
                    annualCost: Money.fromRupees(7788),
                    nextExpectedOn: DateTime(2026, 11, 15),
                    setupConfirmed: true,
                    cadenceConfirmed: true,
                    engineStatus: 'confirmed',
                  ),
                ],
                totalAnnual: Money.fromRupees(7788),
              ),
            ),
          ],
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('Autopay authorizations'), findsOneWidget);
      expect(find.text('OpenAI LLC'), findsOneWidget);
      expect(find.text('AutoPay limit ₹1999'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      db.close();
    },
  );

  testWidgets(
    'displays central subscription projection mandates and filters non-subscription mandates',
    (tester) async {
      final projectionSub = BillProjection.fromJson({
        'id': 'mandate-googleplay',
        'projectionKind': 'mandate',
        'projectionKey': 'mandate:googleplay',
        'status': 'active',
        'projection': {
          'billerName': 'Google Play',
          'authorizationLimitInr': 1850,
          'asOfAt': '2026-10-23T00:00:00Z',
        },
      });
      final projectionUtility = BillProjection.fromJson({
        'id': 'mandate-hdfc',
        'projectionKind': 'mandate',
        'projectionKey': 'mandate:hdfc',
        'status': 'active',
        'projection': {
          'billerName': 'HDFC Life',
          'authorizationLimitInr': 5000,
          'asOfAt': '2026-10-23T00:00:00Z',
        },
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            centralBillsProjectionProvider.overrideWith(
              (ref) async => BillProjectionSnapshot(
                available: true,
                projections: [projectionSub, projectionUtility],
              ),
            ),
            recurringReportProvider.overrideWith(
              (ref) async => const RecurringReport(
                series: [],
                totalAnnual: Money.zero(),
              ),
            ),
          ],
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Google Play'), findsOneWidget);
      expect(find.text('AutoPay limit ₹1850'), findsOneWidget);
      expect(find.text('HDFC Life'), findsNothing);
      expect(find.text('No subscriptions found yet'), findsNothing);
    },
  );
}
