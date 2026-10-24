import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/needs_review_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  Map<String, dynamic>? lastLogArgs;
  Map<String, dynamic>? lastOverrideArgs;
  final List<Map<String, dynamic>> allOverrideArgs = [];

  @override
  Future<String> logTransaction({
    String? userCardId,
    required dynamic amount,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    String? merchantVpa,
    String? mcc,
    DateTime? occurredAt,
    String? note,
    String? rail,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
    String? clientMutationId,
  }) async {
    lastLogArgs = {
      'userCardId': userCardId,
      'amount': amount,
      'categoryId': categoryId,
    };
    return 'fake-txn-id';
  }

  @override
  Future<bool> overrideSmsFact({
    required String sourceKey,
    required int factIndex,
    required Map<String, dynamic> patch,
    String? reason,
    String? templateText,
    String? sampleBody,
  }) async {
    lastOverrideArgs = {
      'sourceKey': sourceKey,
      'factIndex': factIndex,
      'patch': patch,
      'reason': reason,
      'templateText': templateText,
      'sampleBody': sampleBody,
    };
    allOverrideArgs.add(lastOverrideArgs!);
    return true;
  }

  Map<String, dynamic>? lastDismissArgs;
  final List<Map<String, dynamic>> allDismissArgs = [];

  @override
  Future<bool> dismissSms({
    required String sourceKey,
    String? sender,
    String? reason,
    String? templateText,
    String? sampleBody,
    String? family,
  }) async {
    lastDismissArgs = {
      'sourceKey': sourceKey,
      'sender': sender,
      'reason': reason,
      'templateText': templateText,
      'sampleBody': sampleBody,
      'family': family,
    };
    allDismissArgs.add(lastDismissArgs!);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  required NeedsReviewRepository reviews,
  CommitmentsRepository? commitments,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith((ref) async => const []),
        needsReviewRepositoryProvider.overrideWithValue(reviews),
        if (commitments != null)
          commitmentsRepositoryProvider.overrideWithValue(commitments),
      ],
      child: const MaterialApp(home: NeedsReviewScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  late NeedsReviewRepository reviews;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    reviews = NeedsReviewRepository(
      namespace: 'user:test',
      loadDatabase: () async => db,
    );
  });
  tearDown(() => db.close());

  testWidgets('shows an empty state when nothing needs review', (tester) async {
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);
    expect(find.text('Nothing needs review'), findsOneWidget);
  });

  testWidgets('shows the raw sender and body for a queued item', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent at AMAZON',
        reason: 'unparseable_amount',
        receivedAt: DateTime.now(),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    expect(find.text('VM-HDFCBK'), findsOneWidget);
    expect(find.text('Rs.499 spent at AMAZON'), findsOneWidget);
  });

  testWidgets('Ignore message removes the item from the queue', (tester) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent on HDFC Bank Card ending 1234 at AMAZON.',
        receivedAt: DateTime.now(),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    await tester.tap(find.text('Ignore message'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing needs review'), findsOneWidget);
    expect(await reviews.fetchAll(), isEmpty);
  });

  testWidgets('Review transaction opens a clear bottom-sheet review form', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'txn-review-1',
        sender: 'VM-HDFCBK',
        body: 'Rs.499 spent at AMAZON',
        reason: 'no_transaction_match',
        receivedAt: DateTime(2026, 10, 1),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    await tester.tap(find.text('Review transaction'));
    await tester.pumpAndSettle();

    expect(find.text('Review this transaction'), findsOneWidget);
    expect(
      find.textContaining('possible transaction in this message'),
      findsOneWidget,
    );
    expect(find.text('Save transaction'), findsOneWidget);
    expect(find.text('Amount (₹)'), findsOneWidget);
    expect(find.text('Merchant or sender'), findsOneWidget);
  });

  testWidgets('Dismiss all clears every queued item at once', (tester) async {
    await reviews.add(
      NeedsReviewItem(
        id: '1',
        sender: 'VM-HDFCBK',
        body: 'Rs.100 spent on HDFC Bank Card ending 1234 at FIRST SHOP.',
        receivedAt: DateTime.now(),
      ),
    );
    await reviews.add(
      NeedsReviewItem(
        id: '2',
        sender: 'VM-HDFCBK',
        body: 'Rs.200 spent on HDFC Bank Card ending 5678 at SECOND SHOP.',
        receivedAt: DateTime.now(),
      ),
    );
    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    await tester.tap(find.text('Dismiss all'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing needs review'), findsOneWidget);
    expect(await reviews.fetchAll(), isEmpty);
  });

  testWidgets('Save bill opens a review sheet and only then persists it', (
    tester,
  ) async {
    final future = DateTime.now().add(const Duration(days: 10));
    final dueOn = DateTime(future.year, future.month, future.day);
    final dueDateText = '${dueOn.year}-${dueOn.month.toString().padLeft(2, '0')}-${dueOn.day.toString().padLeft(2, '0')}';
    await reviews.add(
      NeedsReviewItem(
        id: 'bill-1',
        sender: 'JX-MYTNEU-S',
        body:
            'Your HDFC BANK CREDIT CARD bill of Rs. 10148.00 is ready. Pay by $dueDateText.',
        receivedAt: DateTime.now(),
        kind: NeedsReviewKind.commitment,
      ),
    );
    final commitments = CommitmentsRepository(namespace: 'user:test');
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      commitments: commitments,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save bill'));
    await tester.pumpAndSettle();

    expect(find.text('Review bill details'), findsOneWidget);
    expect(
      find.textContaining('Nothing is saved until you tap Save bill.'),
      findsOneWidget,
    );
    expect(await commitments.fetchAll(), isEmpty);

    final sheetSave = find.widgetWithText(FilledButton, 'Save bill');
    await tester.tap(sheetSave.last);
    await tester.pumpAndSettle();

    final saved = await commitments.fetchAll();
    expect(saved, hasLength(1));
    expect(saved.single.amount?.paise, 1014800);
    expect(saved.single.dueOn, dueOn);
    expect(saved.single.isUserConfirmed, isTrue);
    expect(await reviews.fetchAll(), isEmpty);
  });

  testWidgets('a commitment can be dismissed from its own close action', (
    tester,
  ) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'bill-2',
        sender: 'HDFCBK',
        body: 'Your bill of Rs. 2000 is generated. Due date 28-10-2026',
        receivedAt: DateTime(2026, 10, 1),
        kind: NeedsReviewKind.commitment,
      ),
    );
    final commitments = CommitmentsRepository(namespace: 'user:test');
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(),
      reviews: reviews,
      commitments: commitments,
    );

    await tester.tap(find.byTooltip('Dismiss message'));
    await tester.pumpAndSettle();

    expect(await reviews.fetchAll(), isEmpty);
    final tombstones = await commitments.fetchAll();
    expect(tombstones.single.status, CommitmentStatus.dismissed);
  });

  testWidgets(
    'screenshot security case (HDFC Transaction Check Alert) is filtered out and not shown',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'sec-1',
          sender: 'VM-HDFCBK-S',
          body:
              'Transaction Check Alert! We tried to contact you twice to confirm the following txn: Rs.2,000.00 on Card XX4321 at AMAZON on 16-10-26. If this was not you, call 1860-266-2661',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Security or service alert'), findsNothing);
      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'pure service alerts (ViCARE call forwarding) are filtered out and not shown',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'serv-1',
          sender: 'ViCARE',
          body: 'Call Forwarding is now active',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Security or service alert'), findsNothing);
      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'screenshot investment settlement case (Kotak Neo) shows Review transfer and is actionable',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'kotak-1',
          sender: 'KOTAKN',
          body:
              'Kotak Neo: Running A/c settlement payout of INR 15,500.00 initiated for your demat account. You should receive funds in A/c XX1234 by EOD.',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Investment settlement payout'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
      expect(find.text('Review transfer'), findsOneWidget);

      await tester.tap(find.text('Review transfer'));
      await tester.pumpAndSettle();

      expect(find.text('Review this transaction'), findsOneWidget);
      expect(find.text('Save transaction'), findsOneWidget);
    },
  );

  testWidgets(
    'ambiguous account debit shows Choose card/account action label',
    (tester) async {
      await reviews.add(
        NeedsReviewItem(
          id: 'ambig-1',
          sender: 'HDFCBK',
          body: 'Rs.500 spent',
          reason: 'ambiguous_account_debit',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Choose card/account'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
    },
  );

  testWidgets(
    'saving reviewed transaction syncs structured fact override for 64-char source key',
    (tester) async {
      final key = 'f' * 64;
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'VM-HDFCBK',
          body: 'Rs.499 spent at AMAZON',
          reason: 'no_transaction_match',
          receivedAt: DateTime(2026, 10, 1),
        ),
      );
      final repo = _FakeUserCardsRepository();
      await _pump(tester, repo: repo, reviews: reviews);

      await tester.tap(find.text('Review transaction'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save transaction'));
      await tester.pumpAndSettle();

      expect(repo.lastOverrideArgs, isNotNull);
      expect(repo.lastOverrideArgs!['sourceKey'], key);
      expect(repo.lastOverrideArgs!['factIndex'], 0);
      expect((repo.lastOverrideArgs!['patch'] as Map)['amountRole'], 'posted');
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'balance_snapshot AI suggestion shows Confirm balance and persists observation on confirm',
    (tester) async {
      final key = 'b' * 64;
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'HDFCBK',
          body: 'Available balance in A/c 1234 is INR 12500.50',
          receivedAt: DateTime(2026, 10, 10),
          aiSuggestions: [
            {
              'factIndex': 0,
              'factType': 'balance_snapshot',
              'payload': {
                'availableBalanceInr': 12500.50,
                'accountLast4': '1234',
                'asOfAt': '2026-10-10T12:00:00.000Z',
              },
            },
          ],
        ),
      );
      final repo = _FakeUserCardsRepository();
      await _pump(tester, repo: repo, reviews: reviews);

      expect(find.text('Confirm balance'), findsOneWidget);
      await tester.tap(find.text('Confirm balance'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm bank balance'), findsOneWidget);
      expect(find.text('12500.50'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Confirm balance').last);
      await tester.pumpAndSettle();

      expect(repo.lastOverrideArgs, isNotNull);
      expect(repo.lastOverrideArgs!['sourceKey'], key);
      expect(repo.lastOverrideArgs!['factIndex'], 0);
      expect((repo.lastOverrideArgs!['patch'] as Map)['availableBalanceInr'], 12500.50);
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'bill_obligation AI suggestion shows Review bill and persists commitment on save',
    (tester) async {
      final key = 'c' * 64;
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'AIRTEL',
          body: 'Bill of Rs.1499.00 due on 2026-11-05 for Broadband',
          receivedAt: DateTime(2026, 10, 10),
          aiSuggestions: [
            {
              'factIndex': 0,
              'factType': 'bill_obligation',
              'payload': {
                'billerName': 'Airtel Broadband',
                'amountDueInr': 1499.00,
                'dueDate': '2026-11-05T00:00:00.000Z',
                'last4': '5678',
              },
            },
          ],
        ),
      );
      final repo = _FakeUserCardsRepository();
      final commitments = CommitmentsRepository(namespace: 'user:test');
      await _pump(tester, repo: repo, reviews: reviews, commitments: commitments);

      expect(find.text('Review bill'), findsOneWidget);
      await tester.tap(find.text('Review bill'));
      await tester.pumpAndSettle();

      expect(find.text('Review bill details'), findsOneWidget);
      expect(find.text('Airtel Broadband'), findsOneWidget);
      expect(find.text('1499.00'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Save bill').last);
      await tester.pumpAndSettle();

      expect(repo.lastOverrideArgs, isNotNull);
      expect(repo.lastOverrideArgs!['sourceKey'], key);
      expect(repo.lastOverrideArgs!['factIndex'], 0);
      expect(await reviews.fetchAll(), isEmpty);
      final savedBills = await commitments.fetchAll();
      expect(savedBills, hasLength(1));
      expect(savedBills.single.title, 'Airtel Broadband');
    },
  );

  testWidgets(
    'multi-fact SMS resolves individual facts sequentially without dropping remaining ones',
    (tester) async {
      final key = 'd' * 64;
      await reviews.add(
        NeedsReviewItem(
          id: key,
          sender: 'HDFCBK',
          body: 'Rs.499.00 spent at SWIGGY. Avail Bal INR 12500.50 in A/c 1234',
          receivedAt: DateTime(2026, 10, 10),
          aiSuggestions: [
            {
              'factIndex': 0,
              'factType': 'posted_movement',
              'payload': {
                'amountInr': 499.00,
                'merchant': 'SWIGGY',
                'instrument': 'upi_bank',
                'entryKind': 'spend',
              },
            },
            {
              'factIndex': 1,
              'factType': 'balance_snapshot',
              'payload': {
                'availableBalanceInr': 12500.50,
                'accountLast4': '1234',
                'asOfAt': '2026-10-10T12:00:00.000Z',
              },
            },
          ],
        ),
      );
      final repo = _FakeUserCardsRepository();
      await _pump(tester, repo: repo, reviews: reviews);

      // Both suggestions should be visible in multi-suggestion mode
      expect(find.text('Transaction: ₹499.00'), findsOneWidget);
      expect(find.text('Balance: ₹12500.50'), findsOneWidget);
      expect(find.text('Review transaction'), findsOneWidget);

      // Resolve first fact (transaction) via primary button
      await tester.tap(find.text('Review transaction'));
      await tester.pumpAndSettle();

      expect(find.text('Review this transaction'), findsOneWidget);
      await tester.tap(find.text('Save transaction'));
      await tester.pumpAndSettle();

      // Transaction override recorded for fact 0
      expect(repo.allOverrideArgs, hasLength(1));
      expect(repo.allOverrideArgs[0]['factIndex'], 0);

      // Item must NOT be removed from queue; it now has 1 remaining suggestion (balance)
      final remainingItems = await reviews.fetchAll();
      expect(remainingItems, hasLength(1));
      expect(remainingItems.single.aiSuggestions, hasLength(1));
      expect(remainingItems.single.aiSuggestions!.single['factType'], 'balance_snapshot');

      // The button now says Confirm balance
      expect(find.text('Confirm balance'), findsOneWidget);

      // Resolve remaining fact (balance)
      await tester.tap(find.text('Confirm balance'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm bank balance'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm balance').last);
      await tester.pumpAndSettle();

      // Balance override recorded for fact 1
      expect(repo.allOverrideArgs, hasLength(2));
      expect(repo.allOverrideArgs[1]['factIndex'], 1);

      // Now all facts resolved, review queue is empty
      expect(await reviews.fetchAll(), isEmpty);
      expect(find.text('Nothing needs review'), findsOneWidget);
    },
  );

  testWidgets(
    'dismisses an AI promotion fact without treating it as a transaction',
    (tester) async {
      final id = List.filled(64, 'e').join();
      await reviews.add(
        NeedsReviewItem(
          id: id,
          sender: 'VM-HDFCBK',
          body: 'INR 499 spent at STORE. Get cashback on your next purchase.',
          receivedAt: DateTime(2026, 10, 10),
          aiSuggestions: [
            {'factIndex': 0, 'factType': 'promotion', 'payload': <String, dynamic>{}},
            {
              'factIndex': 1,
              'factType': 'posted_movement',
              'payload': {
                'amountInr': 499.0,
                'merchant': 'STORE',
                'instrument': 'credit_card',
                'entryKind': 'spend',
              },
            },
          ],
        ),
      );
      await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

      expect(find.text('Promotional message'), findsOneWidget);
      expect(find.text('Not a transaction'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Dismiss'));
      await tester.pumpAndSettle();

      final remaining = await reviews.fetchAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.aiSuggestions, hasLength(1));
      expect(remaining.single.aiSuggestions!.single['factType'], 'posted_movement');
    },
  );

    testWidgets(
      'dismissing not-a-transaction preserves immediate optimistic UI dismissal and calls dismissSms',
      (tester) async {
        final repo = _FakeUserCardsRepository();
        await reviews.add(
          NeedsReviewItem(
            id: 'txn-item-123',
            sender: 'VM-HDFCBK',
            body: 'Debited Rs. 500 at Store',
            receivedAt: DateTime(2026, 10, 22),
          ),
        );
        await _pump(tester, repo: repo, reviews: reviews);

        expect(find.text('Debited Rs. 500 at Store'), findsOneWidget);

        // Tap Ignore message (_dismissNotATransaction)
        await tester.tap(find.text('Ignore message'));
        await tester.pumpAndSettle();

        // 1. Immediate optimistic UI dismissal: item is gone immediately
        expect(find.text('Debited Rs. 500 at Store'), findsNothing);
        expect(find.text('Nothing needs review'), findsOneWidget);
        expect(await reviews.fetchAll(), isEmpty);

        // 2. repository.dismissSms was invoked with expected parameters
        expect(repo.lastDismissArgs, isNotNull);
        expect(repo.lastDismissArgs!['sourceKey'], 'txn-item-123');
        expect(repo.lastDismissArgs!['sender'], 'VM-HDFCBK');
        expect(repo.lastDismissArgs!['reason'], 'user_dismissed');
        expect(repo.lastDismissArgs!['family'], 'ignore_noise');
      },
    );

    testWidgets(
      'dismissing commitment item preserves immediate optimistic dismissal and calls dismissSms',
      (tester) async {
        final repo = _FakeUserCardsRepository();
        final commitments = CommitmentsRepository(namespace: 'user:test');
        await reviews.add(
          NeedsReviewItem(
            id: 'bill-item-456',
            sender: 'HDFCBK',
            body: 'Your bill of Rs. 2000 is generated. Due date 28-10-2026',
            receivedAt: DateTime(2026, 10, 22),
            kind: NeedsReviewKind.commitment,
          ),
        );
        await _pump(
          tester,
          repo: repo,
          reviews: reviews,
          commitments: commitments,
        );

        expect(find.byTooltip('Dismiss message'), findsOneWidget);

        // Tap dismiss button (_dismiss)
        await tester.tap(find.byTooltip('Dismiss message'));
        await tester.pumpAndSettle();

        // 1. Immediate optimistic UI dismissal
        expect(await reviews.fetchAll(), isEmpty);
        expect(find.text('Nothing needs review'), findsOneWidget);

        // 2. repository.dismissSms was invoked
        expect(repo.lastDismissArgs, isNotNull);
        expect(repo.lastDismissArgs!['sourceKey'], 'bill-item-456');
        expect(repo.lastDismissArgs!['sender'], 'HDFCBK');
        expect(repo.lastDismissArgs!['reason'], 'user_dismissed');
        expect(repo.lastDismissArgs!['family'], 'ignore_noise');
      },
    );

    testWidgets(
      'Dismiss all calls dismissSms for all queued items and immediately clears screen',
      (tester) async {
        final repo = _FakeUserCardsRepository();
        await reviews.add(
          NeedsReviewItem(
            id: 'item-1',
            sender: 'VM-HDFCBK',
            body: 'Rs.100 spent on HDFC Bank Card ending 1234 at FIRST SHOP.',
            receivedAt: DateTime.now(),
          ),
        );
        await reviews.add(
          NeedsReviewItem(
            id: 'item-2',
            sender: 'VM-HDFCBK',
            body: 'Rs.200 spent on HDFC Bank Card ending 5678 at SECOND SHOP.',
            receivedAt: DateTime.now(),
          ),
        );
        await _pump(tester, repo: repo, reviews: reviews);

        await tester.tap(find.text('Dismiss all'));
        await tester.pumpAndSettle();

        expect(find.text('Nothing needs review'), findsOneWidget);
        expect(await reviews.fetchAll(), isEmpty);
        expect(repo.allDismissArgs, hasLength(2));
        expect(repo.allDismissArgs.map((a) => a['sourceKey']).toSet(), {'item-1', 'item-2'});
      },
    );

    test(
      'UserCardsRepository.dismissSms handles offline network error gracefully by recording to retry queue',
      () async {
        final failingClient = MockClient((request) async {
          throw http.ClientException('Network is unreachable / device offline');
        });

        final repo = UserCardsRepository(
          apiBaseUrl: 'https://api.pandapay.test',
          accessToken: 'test-token',
          client: failingClient,
        );

        expect(repo.dismissalRetryQueue, isEmpty);

        // Calling dismissSms when offline must return false gracefully and record into local retry queue
        final result = await repo.dismissSms(
          sourceKey: 'abc' * 21 + 'd',
          sender: 'AD-HDFCBK',
          sampleBody: 'Sample SMS text',
          reason: 'user_dismissed',
          family: 'ignore_noise',
        );

        expect(result, isFalse);
        expect(repo.dismissalRetryQueue, hasLength(1));
        final entry = repo.dismissalRetryQueue.first;
        expect(entry.sourceKey, 'abc' * 21 + 'd');
        expect(entry.sender, 'AD-HDFCBK');
        expect(entry.reason, 'user_dismissed');
        expect(entry.family, 'ignore_noise');
      },
    );

    test(
      'UserCardsRepository.flushDismissalQueue retries offline queued dismissals upon reconnection',
      () async {
        var isOnline = false;

        final mockClient = MockClient((request) async {
          if (!isOnline) {
            throw http.ClientException('Connection reset');
          }
          return http.Response(jsonEncode({'ok': true}), 200);
        });

        final repo = UserCardsRepository(
          apiBaseUrl: 'https://api.pandapay.test',
          accessToken: 'test-token',
          client: mockClient,
        );

        // Initially offline
        await repo.dismissSms(
          sourceKey: 'key-offline-1',
          sender: 'AD-HDFCBK',
          reason: 'user_dismissed',
        );
        expect(repo.dismissalRetryQueue, hasLength(1));

        // Still offline: flush fails, entries remain
        final flushedOffline = await repo.flushDismissalQueue();
        expect(flushedOffline, 0);
        expect(repo.dismissalRetryQueue, hasLength(1));

        // Device reconnects
        isOnline = true;
        final flushedOnline = await repo.flushDismissalQueue();
        expect(flushedOnline, 1);
        expect(repo.dismissalRetryQueue, isEmpty);
      },
    );

  testWidgets('displays formatted timestamps and orders latest-first by default', (tester) async {
    final olderDate = DateTime(2026, 8, 15, 10, 30);
    final newerDate = DateTime(2026, 10, 4, 9, 53);

    await reviews.add(
      NeedsReviewItem(
        id: 'old-1',
        sender: 'VM-WELFOR',
        body: 'Rs.200 spent on card',
        receivedAt: olderDate,
      ),
    );
    await reviews.add(
      NeedsReviewItem(
        id: 'new-1',
        sender: 'AD-HDFCBK',
        body: 'Rs.500 spent on card',
        receivedAt: newerDate,
      ),
    );

    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    expect(find.text('Oct 4, 2026 • 9:53 AM'), findsOneWidget);
    expect(find.text('Aug 15, 2026 • 10:30 AM'), findsOneWidget);

    final newPos = tester.getTopLeft(find.text('AD-HDFCBK')).dy;
    final oldPos = tester.getTopLeft(find.text('VM-WELFOR')).dy;
    expect(newPos, lessThan(oldPos));
  });

  testWidgets('filter chips filter by month and show clean empty state when no items in month', (tester) async {
    await reviews.add(
      NeedsReviewItem(
        id: 'oct-1',
        sender: 'AD-HDFCBK',
        body: 'Rs.500 spent on card',
        reason: 'unparseable_amount',
        receivedAt: DateTime(2026, 10, 4, 9, 53),
      ),
    );
    await reviews.add(
      NeedsReviewItem(
        id: 'sep-1',
        sender: 'VA-CANBNK',
        body: 'Rs.300 spent on card',
        reason: 'unparseable_amount',
        receivedAt: DateTime(2026, 9, 10, 14, 0),
      ),
    );

    await _pump(tester, repo: _FakeUserCardsRepository(), reviews: reviews);

    expect(find.text('All time'), findsOneWidget);
    expect(find.text('Oct 2026 (1)'), findsOneWidget);
    expect(find.text('Sep 2026 (1)'), findsOneWidget);

    await tester.tap(find.text('Oct 2026 (1)'));
    await tester.pumpAndSettle();

    expect(find.text('AD-HDFCBK'), findsOneWidget);
    expect(find.text('VA-CANBNK'), findsNothing);

    await tester.tap(find.text('Bills & Mandates'));
    await tester.pumpAndSettle();

    expect(find.text('No review items in Oct 2026'), findsOneWidget);

    await tester.tap(find.text('All types'));
    await tester.pumpAndSettle();
    expect(find.text('AD-HDFCBK'), findsOneWidget);

    await tester.tap(find.text('All time'));
    await tester.pumpAndSettle();
    expect(find.text('AD-HDFCBK'), findsOneWidget);
    expect(find.text('VA-CANBNK'), findsOneWidget);
  });
}
