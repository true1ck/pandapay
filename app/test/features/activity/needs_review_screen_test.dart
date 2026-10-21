import 'package:flutter/material.dart';
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
  }) async {
    lastOverrideArgs = {
      'sourceKey': sourceKey,
      'factIndex': factIndex,
      'patch': patch,
      'reason': reason,
    };
    allOverrideArgs.add(lastOverrideArgs!);
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
        body: 'not really a txn',
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
        sender: 's1',
        body: 'b1',
        receivedAt: DateTime.now(),
      ),
    );
    await reviews.add(
      NeedsReviewItem(
        id: '2',
        sender: 's2',
        body: 'b2',
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
        sender: 'VZ-VICARE-S',
        body: 'Your mobile invoice is ready for download.',
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
    'screenshot security case (HDFC Transaction Check Alert) shows Dismiss alert and not Review transaction',
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

      expect(find.text('Security or service alert'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
      expect(find.text('Dismiss alert'), findsOneWidget);

      await tester.tap(find.text('Dismiss alert'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing needs review'), findsOneWidget);
      expect(await reviews.fetchAll(), isEmpty);
    },
  );

  testWidgets(
    'screenshot service case (ViCARE call forwarding) shows Dismiss alert and not Review transaction',
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

      expect(find.text('Security or service alert'), findsOneWidget);
      expect(find.text('Review transaction'), findsNothing);
      expect(find.text('Dismiss alert'), findsOneWidget);
    },
  );

  testWidgets(
    'screenshot investment settlement case (Kotak Neo) shows Review transfer and not Review transaction',
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
}
