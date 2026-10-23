import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/bills_projection_api.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/insights/central_bills_section.dart';

void main() {
  testWidgets('shows local AutoPay evidence when central API is unavailable', (tester) async {
    final db = openInMemoryForTesting();
    final cache = ResponseCache(db);
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
    expect(find.text('OpenAI LLC'), findsOneWidget);
    expect(find.text('AutoPay limit ₹1999'), findsOneWidget);
    expect(find.text('₹1999'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    db.close();
  });

  testWidgets('labels mandate ceilings as AutoPay limits', (tester) async {
    final projection = BillProjection.fromJson({
      'id': 'mandate-1',
      'projectionKind': 'mandate',
      'projectionKey': 'mandate:openai',
      'status': 'active',
      'projection': {
        'merchant': 'OpenAI',
        'authorizationLimitInr': 1999,
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

    expect(find.text('AutoPay limit ₹1999'), findsOneWidget);
    expect(find.text('₹1999'), findsNothing);
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
}
