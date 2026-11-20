// "Add the payment yourself" / "Add as transaction" on the Needs review screen
// opens the Edit transaction screen on a draft filled in with what the question
// knows. Saving it answers the question (it leaves Needs review and shows in
// History); backing out leaves the question as it was.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/consents_api.dart' show ConsentRecord;
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/sync/ai_server_status.dart';
import 'package:pandapay/features/sms_v2/ui/review_history_views.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2.dart' show kReceiptWithoutPaymentReason;

import '../support/ledger_dataset.dart';

void main() {
  late Dataset d;
  TransactionEntry? opened;

  setUp(() {
    d = Dataset(2)..open();
    d.seed();
    SmsIntakeRepository(d.database);
    opened = null;
    d.database.db.execute(
      "INSERT INTO v2_review_items(namespace,review_id,kind,payload,status) VALUES(?,?,?,?,'open')",
      [
        ns,
        'rc1',
        'event',
        jsonEncode({
          'reason': kReceiptWithoutPaymentReason,
          'factId': 'f',
          'amountMinor': 1000,
          'receiptAt': '2026-11-07T10:00:00Z',
          'app': 'Airtel',
          'sourceKey': 'k',
        }),
      ],
    );
  });
  tearDown(() => d.close());

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/review',
      routes: [
        GoRoute(path: '/review', builder: (_, _) => const ReviewInboxScreen()),
        GoRoute(
          path: '/activity/:id/edit',
          builder: (context, state) {
            opened = state.extra as TransactionEntry?;
            return Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => context.pop(
                      AddedTransaction(
                        clientMutationId: 'cm-1',
                        amount: Money.fromPaise(1250),
                        occurredAt: DateTime.utc(2026, 11, 7, 10),
                        entryKind: TxnEntryKind.spend,
                        merchantName: 'Airtel',
                      ),
                    ),
                    child: const Text('stub-save'),
                  ),
                  TextButton(
                    onPressed: () => context.pop(),
                    child: const Text('stub-back'),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        app.cacheNamespaceProvider.overrideWithValue(ns),
        app.responseCacheProvider.overrideWith((ref) async => d.cache),
        smsV2RuntimeProvider.overrideWith((ref) async => null),
        geminiServerStatusProvider.overrideWith(
          (ref) async => const AiServerStatus(
            countedNow: false,
            eligible: false,
            total: 0,
            ready: 0,
          ),
        ),
        aiUnreadCountProvider.overrideWith((ref) async => 0),
        app.smsSharedLearningConsentProvider.overrideWith(
          (ref) async => ConsentRecord(
            purpose: 'sms_shared_learning',
            granted: false,
            grantedAt: DateTime(2026, 11, 1),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  String status() =>
      d.database.db
              .select(
                "SELECT status FROM v2_review_items WHERE namespace=? AND review_id='rc1'",
                [ns],
              )
              .single['status']
          as String;

  testWidgets('opens the Edit screen on a draft with what the receipt says', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Add the payment yourself'));
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect(opened!.id, '${kDraftTransactionPrefix}rc1');
    expect(opened!.amount, Money.fromPaise(1000));
    expect(opened!.merchantName, 'Airtel');
    expect(status(), 'open', reason: 'nothing is answered before it is saved');
  });

  testWidgets('saving answers the question: it leaves Needs review and shows in History', (
    tester,
  ) async {
    final container = await pump(tester);
    await tester.tap(find.text('Add the payment yourself'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('stub-save'));
    await tester.pumpAndSettle();
    expect(status(), 'resolved');
    final items = await container.read(reviewItemsProvider.future);
    expect(items.where((i) => i.id == 'rc1'), isEmpty);
    final lists = await container.read(settledListsProvider.future);
    expect(lists.history.single.entry.merchantName, 'Airtel');
    expect(lists.history.single.entry.amount, Money.fromPaise(1250));
    expect(lists.history.single.how, 'You added this from a message');
  });

  testWidgets('backing out leaves the question as it was', (tester) async {
    final container = await pump(tester);
    await tester.tap(find.text('Add the payment yourself'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('stub-back'));
    await tester.pumpAndSettle();
    expect(status(), 'open');
    expect((await container.read(reviewItemsProvider.future)).any((i) => i.id == 'rc1'), isTrue);
    expect(find.text('Add the payment yourself'), findsOneWidget);
  });
}
