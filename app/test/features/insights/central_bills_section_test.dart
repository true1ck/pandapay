import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/bills_projection_api.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/insights/central_bills_section.dart';

void main() {
  testWidgets('shows local non-subscription AutoPay evidence when central API is unavailable', (tester) async {
    final db = openInMemoryForTesting();
    final cache = ResponseCache(db);
    cache.financialStore.saveObservation('user:test', 'sms:bescom', {
      'event_type': 'autopay',
      'biller_name': 'BESCOM',
      'card_last4': '7105',
      'autopay_limit_paise': 250000,
      'received_at': '2026-10-18T09:00:00Z',
    });
    cache.financialStore.saveObservation('user:test', 'sms:axis-openai', {
      'event_type': 'autopay',
      'biller_name': 'OpenAI LLC',
      'card_last4': '7105',
      'autopay_limit_paise': 199900,
      'received_at': '2026-10-18T09:00:00Z',
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        cacheNamespaceProvider.overrideWithValue('user:test'),
        responseCacheProvider.overrideWith((ref) async => cache),
        centralBillsProjectionProvider.overrideWith(
          (ref) async => const BillProjectionSnapshot.unavailable(),
        ),
        commitmentsProvider.overrideWith((ref) async => const []),
      ],
      child: const MaterialApp(home: Scaffold(body: CentralBillsSection())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('BESCOM'), findsOneWidget);
    expect(find.text('AutoPay limit ₹2500'), findsOneWidget);
    expect(find.text('OpenAI LLC'), findsNothing);
    expect(find.text('₹2500'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    db.close();
  });

  testWidgets('labels non-subscription mandate ceilings as AutoPay limits', (tester) async {
    final projection = BillProjection.fromJson({
      'id': 'mandate-1',
      'projectionKind': 'mandate',
      'projectionKey': 'mandate:bescom',
      'status': 'active',
      'projection': {
        'billerName': 'BESCOM',
        'authorizationLimitInr': 2500,
        'asOfAt': '2026-10-23T00:00:00Z',
      },
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          centralBillsProjectionProvider.overrideWith(
            (ref) async => BillProjectionSnapshot(
              available: true,
              projections: [projection],
            ),
          ),
          commitmentsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: Scaffold(body: CentralBillsSection())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BESCOM'), findsOneWidget);
    expect(find.text('AutoPay limit ₹2500'), findsOneWidget);
    expect(find.text('₹2500'), findsNothing);
  });

  testWidgets('excludes subscription AutoPay authorizations from central bills', (tester) async {
    final db = openInMemoryForTesting();
    final cache = ResponseCache(db);
    cache.financialStore.saveObservation('user:test', 'sms:axis-openai', {
      'event_type': 'autopay',
      'biller_name': 'OpenAI LLC',
      'card_last4': '7105',
      'autopay_limit_paise': 199900,
      'received_at': '2026-10-18T09:00:00Z',
    });
    cache.financialStore.saveObservation('user:test', 'sms:axis-googleplay', {
      'event_type': 'autopay',
      'biller_name': 'Google Play',
      'card_last4': '7105',
      'autopay_limit_paise': 185000,
      'received_at': '2026-10-18T09:00:00Z',
    });
    final centralSubscriptionMandate = BillProjection.fromJson({
      'id': 'mandate-sub',
      'projectionKind': 'mandate',
      'projectionKey': 'mandate:openai',
      'status': 'active',
      'projection': {
        'billerName': 'OpenAI',
        'authorizationLimitInr': 1999,
        'asOfAt': '2026-10-23T00:00:00Z',
      },
    });

    await tester.pumpWidget(ProviderScope(
      overrides: [
        cacheNamespaceProvider.overrideWithValue('user:test'),
        responseCacheProvider.overrideWith((ref) async => cache),
        centralBillsProjectionProvider.overrideWith(
          (ref) async => BillProjectionSnapshot(
            available: true,
            projections: [centralSubscriptionMandate],
          ),
        ),
        commitmentsProvider.overrideWith((ref) async => const []),
      ],
      child: const MaterialApp(home: Scaffold(body: CentralBillsSection())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('OpenAI LLC'), findsNothing);
    expect(find.text('Google Play'), findsNothing);
    expect(find.text('OpenAI'), findsNothing);
    expect(find.text('Autopay authorizations'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    db.close();
  });

  testWidgets('hides a server card bill already represented by card dues', (
    tester,
  ) async {
    final projection = BillProjection.fromJson({
      'id': 'bill-1',
      'projectionKind': 'bill_obligation',
      'projectionKey': 'bill:axis:2026-11-05:due_total',
      'status': 'open',
      'projection': {
        'billerName': 'Axis Card',
        'last4': '7105',
        'amountInr': 3000,
        'dueDate': '2026-11-05T00:00:00Z',
      },
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          centralBillsProjectionProvider.overrideWith(
            (ref) async => BillProjectionSnapshot(
              available: true,
              projections: [projection],
            ),
          ),
          commitmentsProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CentralBillsSection(
              cardRows: [
                CentralBillDedupKey(
                  last4: '7105',
                  dueOn: DateTime(2026, 11, 5),
                  amountInr: 3000,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Axis Card'), findsNothing);
  });

  testWidgets(
    'hides a suffix-less server bill resolved locally by amount and due date',
    (tester) async {
      final projection = BillProjection.fromJson({
        'id': 'bill-hdfc-8331',
        'projectionKind': 'bill_obligation',
        'projectionKey': 'bill:hdfccreditcard:2026-11-08:due_total',
        'status': 'open',
        'projection': {
          'billerName': 'HDFC Credit Card',
          'amountInr': 8331,
          'dueDate': '2026-11-08T00:00:00Z',
        },
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            centralBillsProjectionProvider.overrideWith(
              (ref) async => BillProjectionSnapshot(
                available: true,
                projections: [projection],
              ),
            ),
            commitmentsProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CentralBillsSection(
                cardRows: [
                  CentralBillDedupKey(
                    last4: '8708',
                    dueOn: DateTime(2026, 11, 8),
                    amountInr: 8331,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('HDFC Credit Card'), findsNothing);
    },
  );
}
