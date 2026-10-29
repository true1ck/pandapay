import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/features/insights/subscription_detail_screen.dart';
import 'package:pandapay/features/insights/subscriptions_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  group('SubscriptionDetailScreen', () {
    testWidgets(
      'renders prominent title, status badge, and What We Know card with crisp amount',
      (tester) async {
        final series = RecurringSeries(
          id: 'netflix-1',
          displayName: 'Netflix',
          typicalAmount: Money.fromRupees(649),
          cadenceDays: 30,
          occurrenceCount: 5,
          annualCost: Money.fromRupees(7788),
          lastSeenOn: DateTime(2026, 10, 15),
          nextExpectedOn: DateTime(2026, 11, 15),
          cardName: 'HDFC Bank Card XX4012',
          autopayStatus: 'active',
          cadenceConfirmed: true,
          engineStatus: 'confirmed',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              cacheNamespaceProvider.overrideWithValue('user:test'),
            ],
            child: MaterialApp(
              home: SubscriptionDetailScreen(series: series),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Prominent header elements
        expect(find.text('Subscription details'), findsOneWidget);
        expect(find.text('Netflix'), findsOneWidget);
        expect(find.text('Active'), findsNWidgets(2)); // Status badge & What we know card
        expect(find.text('AutoPay Active'), findsOneWidget);

        // What we know section
        expect(find.text('What we know'), findsOneWidget);
        expect(find.text('Billing cycle'), findsOneWidget);
        expect(find.text('Monthly'), findsNWidgets(2)); // Badge and What we know
        expect(find.text('Last seen date'), findsOneWidget);
        expect(find.text('15/10/2026'), findsOneWidget);
        expect(find.text('Next expected date'), findsOneWidget);
        expect(find.text('15/11/2026'), findsOneWidget);
        expect(find.text('Payment card'), findsOneWidget);
        expect(find.text('HDFC Bank Card XX4012'), findsOneWidget);

        // Amount formatting must have single currency symbol ₹, never ₹₹
        expect(find.text('₹649.00'), findsNWidgets(2)); // Header & What we know
        expect(find.textContaining('₹₹'), findsNothing);
      },
    );

    testWidgets(
      'renders Awaiting first charge when subscription amount is unset',
      (tester) async {
        final series = const RecurringSeries(
          id: 'openai-mandate',
          displayName: 'OpenAI',
          typicalAmount: Money.zero(),
          amountKnown: false,
          cadenceDays: 30,
          occurrenceCount: 0,
          annualCost: Money.zero(),
          setupConfirmed: true,
          autopayStatus: 'active',
          cadenceConfirmed: true,
          engineStatus: 'candidate',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              cacheNamespaceProvider.overrideWithValue('user:test'),
            ],
            child: MaterialApp(
              home: SubscriptionDetailScreen(series: series),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('OpenAI'), findsOneWidget);
        expect(find.text('Setup confirmed'), findsNWidgets(2));
        expect(find.text('AutoPay Active'), findsOneWidget);

        // What we know shows 'Awaiting first charge'
        expect(find.text('Awaiting first charge'), findsOneWidget);
        expect(find.text('Amount not stated'), findsNothing);
        expect(find.text('Payment amount unknown'), findsNothing);
      },
    );

    testWidgets(
      'renders SMS evidence card with masked account number, received date, and sender tag',
      (tester) async {
        final db = openInMemoryForTesting();
        final cache = ResponseCache(db);
        SmsIntakeRepository(db); // ensures tables exist

        // Capture an SMS matching the mandate reference directly in DB
        db.db.execute(
          'INSERT INTO sms_captured_messages(namespace, id, sender, body, received_at) VALUES (?, ?, ?, ?, ?)',
          [
            'user:test',
            'sms-msg-1',
            'HDFCBK',
            'AutoPay mandate for Spotify India of Rs 119.00 created on account 50100492817234. Ref: SPOTIFYMANDATE123',
            DateTime(2026, 10, 10, 14, 30).millisecondsSinceEpoch,
          ],
        );

        final series = RecurringSeries(
          id: 'spotify-sub',
          displayName: 'Spotify',
          typicalAmount: Money.fromRupees(119),
          cadenceDays: 30,
          occurrenceCount: 2,
          annualCost: Money.fromRupees(1428),
          mandateReference: 'SPOTIFYMANDATE123',
          autopayStatus: 'active',
          cadenceConfirmed: true,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              cacheNamespaceProvider.overrideWithValue('user:test'),
              responseCacheProvider.overrideWith((ref) async => cache),
            ],
            child: MaterialApp(
              home: SubscriptionDetailScreen(series: series),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // SMS evidence header
        expect(find.text('SMS evidence', skipOffstage: false), findsOneWidget);
        expect(find.text('Source message on this device', skipOffstage: false), findsOneWidget);

        // Sender tag & received date
        expect(find.text('HDFCBK', skipOffstage: false), findsOneWidget);
        expect(find.text('Received 10/10/2026', skipOffstage: false), findsOneWidget);

        // Masked body: account 50100492817234 should be masked to •••• 7234
        expect(find.textContaining('•••• 7234', skipOffstage: false), findsOneWidget);
        expect(find.textContaining('50100492817234', skipOffstage: false), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        db.close();
      },
    );

    testWidgets(
      'renders gracefully on small screen dimensions without layout overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final series = RecurringSeries(
          id: 'apple-one',
          displayName: 'Apple One Premier Family Subscription Service',
          typicalAmount: Money.fromRupees(1950),
          cadenceDays: 30,
          occurrenceCount: 12,
          annualCost: Money.fromRupees(23400),
          lastSeenOn: DateTime(2026, 10, 1),
          nextExpectedOn: DateTime(2026, 11, 1),
          cardName: 'Axis Bank Burgundy Debit Card XX9988',
          autopayStatus: 'active',
          cadenceConfirmed: true,
          engineStatus: 'confirmed',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              cacheNamespaceProvider.overrideWithValue('user:test'),
            ],
            child: MaterialApp(
              home: SubscriptionDetailScreen(series: series),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Subscription details'), findsOneWidget);
        expect(find.text('What we know'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping subscription card navigates seamlessly to SubscriptionDetailScreen',
      (tester) async {
        final series = RecurringSeries(
          id: 'sub-hotstar',
          displayName: 'Disney+ Hotstar',
          typicalAmount: Money.fromRupees(1499),
          cadenceDays: 365,
          occurrenceCount: 2,
          annualCost: Money.fromRupees(1499),
          nextExpectedOn: DateTime(2027, 4, 1),
          cardName: 'ICICI Sapphiro Card XX1234',
          autopayStatus: 'active',
          cadenceConfirmed: true,
          engineStatus: 'confirmed',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              recurringReportProvider.overrideWith(
                (ref) async => RecurringReport(
                  series: [series],
                  totalAnnual: Money.fromRupees(1499),
                ),
              ),
            ],
            child: const MaterialApp(home: SubscriptionsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Verify card is on screen
        expect(find.text('Disney+ Hotstar'), findsOneWidget);
        expect(find.text('Yearly'), findsOneWidget);
        expect(find.text('AutoPay Active'), findsOneWidget);

        // Tap the card
        await tester.tap(find.text('Disney+ Hotstar'));
        await tester.pumpAndSettle();

        // Verify we navigated to SubscriptionDetailScreen
        expect(find.text('Subscription details'), findsOneWidget);
        expect(find.text('What we know'), findsOneWidget);
        expect(find.text('ICICI Sapphiro Card XX1234'), findsOneWidget);
        expect(find.text('₹1,499.00'), findsNWidgets(2)); // Header and What we know
      },
    );
  });
}
