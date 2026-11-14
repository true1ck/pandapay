import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/data/transaction_tags_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/data/local/split_repository.dart';
import 'package:pandapay/features/activity/transaction_detail_screen.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  TransactionEntry entry;
  final bool failFetch;
  final bool failSplits;
  final bool failIgnore;
  String? lastIgnoreReason;
  String? lastNote;
  List<TransactionSplit> splits;
  _FakeUserCardsRepository(
    this.entry, {
    this.failFetch = false,
    this.failSplits = false,
    this.failIgnore = false,
    this.splits = const [],
  });

  @override
  Future<TransactionEntry> fetchTransaction(String id) async {
    if (failFetch) throw StateError('offline');
    return entry;
  }

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {
    if (failIgnore) {
      throw ApiException(
        'POST /transactions/:id/ignore failed: 500 {"error":"internal_error"}',
      );
    }
    lastIgnoreReason = reason;
    entry = TransactionEntry(
      id: entry.id,
      amount: entry.amount,
      occurredAt: entry.occurredAt,
      merchantName: entry.merchantName,
      categoryId: entry.categoryId,
      categoryName: entry.categoryName,
      cardDisplayName: entry.cardDisplayName,
      userCardId: entry.userCardId,
      source: entry.source,
      status: reason == 'transfer' ? 'deleted' : 'ignored',
    );
  }

  @override
  Future<void> updateTransactionNote(String id, String? note) async {
    lastNote = note;
    entry = TransactionEntry(
      id: entry.id,
      amount: entry.amount,
      occurredAt: entry.occurredAt,
      merchantName: entry.merchantName,
      categoryId: entry.categoryId,
      categoryName: entry.categoryName,
      cardDisplayName: entry.cardDisplayName,
      userCardId: entry.userCardId,
      source: entry.source,
      status: entry.status,
      note: note,
    );
  }

  @override
  Future<TransactionSplitDocument> fetchSplitDocument(
    String transactionId,
  ) async => TransactionSplitDocument(
    await fetchSplits(transactionId),
    fingerprint: SplitRepository.fingerprint(splits),
  );

  @override
  Future<TransactionSplitDocument> saveSplitDocument(
    String transactionId,
    TransactionSplitDocument document,
  ) async => TransactionSplitDocument(
    await saveSplits(transactionId, document.splits),
    fingerprint: SplitRepository.fingerprint(document.splits),
  );

  @override
  Future<List<TransactionSplit>> fetchSplits(String transactionId) async {
    if (failSplits) {
      throw ApiException(
        'GET splits failed: 401 {"error":"Missing or invalid access token"}',
      );
    }
    return splits;
  }

  @override
  Future<List<TransactionSplit>> saveSplits(
    String transactionId,
    List<TransactionSplit> next,
  ) async {
    splits = next;
    return splits;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Ignoring or restoring is local first: the screen queues a command and the
/// outbox sends it later. This runs that delivery against [repo], so the tests
/// still check what the server would be told.
Future<int> _deliver(AppDatabase db, _FakeUserCardsRepository repo) =>
    CommandOutbox(db, namespace: 'user:test').flush(commandHandlersFor(repo));

List<Override> _outboxOverrides(AppDatabase db) => [
  cacheNamespaceProvider.overrideWithValue('user:test'),
  responseCacheProvider.overrideWith((ref) async => ResponseCache(db)),
];

Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  TransactionEntry? initialEntry,
  TransactionTagsRepository? tagsRepository,
  String transactionId = 't1',
  bool shared = false,
  List<Override> extraOverrides = const [],
}) async {
  final router = GoRouter(
    initialLocation: '/activity/$transactionId',
    routes: [
      GoRoute(
        path: '/activity/:id',
        builder: (context, state) => TransactionDetailScreen(
          transactionId: state.pathParameters['id']!,
          initialEntry: initialEntry,
        ),
      ),
      GoRoute(
        path: '/activity/:id/edit',
        builder: (context, state) => const Text('edit screen'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedExpensesEnabledProvider.overrideWithValue(shared),
        if (shared)
          cacheNamespaceProvider.overrideWithValue(
            'user:11111111-1111-4111-8111-111111111111',
          ),
        userCardsRepositoryProvider.overrideWithValue(repo),
        ...extraOverrides,
        if (tagsRepository != null)
          transactionTagsProvider.overrideWith((ref) => tagsRepository),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {

  testWidgets(
    'a saved amount edit that is still waiting beats the older server copy (F3)',
    (tester) async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      const namespace = 'user:test';
      final older = TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(888),
        occurredAt: DateTime(2026, 11, 1),
        merchantName: 'TESTSHOP',
        source: 'manual',
        status: 'active',
      );
      ResponseCache(database).financialStore; // creates the tables
      database.db.execute(
        "INSERT INTO financial_entities(namespace, entity, id, payload, observed_at, pending) "
        "VALUES (?, 'transactions', 't1', ?, 1, 0)",
        [
          namespace,
          jsonEncode({
            'id': 't1',
            'amount_inr': 888,
            'occurred_at': '2026-11-01T00:00:00.000',
            'merchant_name': 'TESTSHOP',
            'status': 'active',
          }),
        ],
      );
      // The edit is saved on the phone; the server keeps refusing it (503), so
      // its own copy of the row still says 888.
      CommandOutbox(database, namespace: namespace).enqueue(
        kind: 'transaction_typed_fields',
        target: 't1',
        payload: {'id': 't1', 'amountInr': 999},
      );
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(older),
        initialEntry: older,
        extraOverrides: _outboxOverrides(database),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('999'), findsWidgets);
      expect(find.textContaining('888'), findsNothing);
    },
  );

  group('SMS evidence privacy notes', () {
    const present = 'The original SMS stays on this phone and is never sent to PandaPay.';
    const missing =
        'The original SMS isn\'t on this phone (it holds 0 saved messages). The details above came from it when it was first read.';

    Future<void> pumpEvidence(
      WidgetTester tester, {
      required bool messageOnPhone,
      bool keyOnEntryOnly = false,
    }) async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      const namespace = 'user:11111111-1111-4111-8111-111111111111';
      final sms = QueuedSms(
        sender: 'TESTBK',
        body: 'Rs 42.50 spent on card ending 4242 at TESTSHOP',
        receivedAt: DateTime(2026, 11, 1, 10),
      );
      final key = smsSourceKey(namespace, sms.sender, sms.body);
      if (messageOnPhone) SmsIntakeRepository(database).remember(namespace, sms);
      final entry = TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(42.5),
        occurredAt: DateTime(2026, 11, 1),
        merchantName: 'TESTSHOP',
        source: 'sms',
        status: 'active',
        // Rows made by the v2 pipeline carry the message key on the row
        // itself and have no observations list.
        sourceKey: keyOnEntryOnly ? key : null,
        smsReceivedAt: keyOnEntryOnly ? DateTime(2026, 11, 1, 10) : null,
        observations: keyOnEntryOnly
            ? const []
            : [
                TransactionObservation(
                  source: 'sms',
                  sourceKey: key,
                  observedAt: DateTime(2026, 11, 1, 10),
                ),
              ],
      );
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(entry),
        extraOverrides: [
          cacheNamespaceProvider.overrideWithValue(namespace),
          responseCacheProvider.overrideWith((ref) async => ResponseCache(database)),
        ],
      );
      final tile = find.text('SMS evidence');
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }

    testWidgets('message present: it stays on the phone and is never sent', (
      tester,
    ) async {
      await pumpEvidence(tester, messageOnPhone: true);
      expect(find.text(present), findsOneWidget);
      expect(find.text(missing), findsNothing);
      expect(find.textContaining('Original SMS captured on this device'), findsOneWidget);
      expect(find.textContaining('screenshot'), findsNothing);
      expect(find.textContaining('not uploaded as transaction evidence'), findsNothing);
    });

    testWidgets('v2 row (key on the row, no observations): finds the message', (
      tester,
    ) async {
      await pumpEvidence(
        tester,
        messageOnPhone: true,
        keyOnEntryOnly: true,
      );
      expect(find.text(present), findsOneWidget);
      expect(find.text(missing), findsNothing);
    });

    testWidgets('message missing: says so, with no screenshot advice', (
      tester,
    ) async {
      await pumpEvidence(tester, messageOnPhone: false);
      expect(find.text(missing), findsOneWidget);
      expect(find.text(present), findsNothing);
      expect(find.textContaining('screenshot'), findsNothing);
      expect(find.textContaining('Attach a screenshot'), findsNothing);
    });
  });

  testWidgets(
    'shared rollout retains private split editing through one contextual action',
    (tester) async {
      final entry = TransactionEntry(
        id: '22222222-2222-4222-8222-222222222222',
        amount: Money.fromRupees(900),
        occurredAt: DateTime(2026, 11, 4),
        merchantName: 'Dinner',
        source: 'manual',
        status: 'active',
      );
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(entry),
        transactionId: entry.id,
        shared: true,
      );
      final action = find.text('Split this expense');
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('With friends'), findsOneWidget);
      expect(find.text('Just for me'), findsOneWidget);
      await tester.tap(find.text('Just for me'));
      await tester.pumpAndSettle();
      expect(find.text('Save split'), findsOneWidget);
    },
  );
  testWidgets(
    'local SMS detail shows the saved card and UPI before server sync',
    (tester) async {
      final entry = TransactionEntry(
        id: 'local-sms:fixture',
        amount: Money.fromRupees(42.5),
        occurredAt: DateTime(2026, 11, 1),
        merchantName: 'TESTTECHNOLOGIES',
        cardDisplayName: 'My SBI PhonePe RuPay card',
        cardLast4: '4242',
        userCardId: 'saved-rupay',
        paymentMethod: 'upi',
        source: 'sms',
        status: 'active',
      );
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(entry),
        initialEntry: entry,
        transactionId: entry.id,
      );
      expect(find.text('My SBI PhonePe RuPay card'), findsOneWidget);
      expect(find.text('UPI'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'UPI credit-card spend shows the matched card without guessing QR',
    (tester) async {
      final database = openInMemoryForTesting();
      final client = MockClient((_) async => http.Response('{}', 200));
      addTearDown(() {
        client.close();
        database.close();
      });
      final tags = TransactionTagsRepository(
        database: database,
        namespace: 'test-user',
        apiBaseUrl: 'http://localhost',
        accessToken: 'test-token',
        client: client,
      );
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(42.5),
          occurredAt: DateTime(2026, 11, 1),
          merchantName: 'TESTTECHNOLOGIES',
          cardDisplayName: 'My SBI PhonePe RuPay card',
          cardLast4: '4242',
          userCardId: 'saved-rupay',
          sourceKey: 'exact-sms-fixture',
          instrument: TxnInstrument.creditCard,
          paymentMethod: 'upi',
          source: 'sms',
          status: 'active',
        ),
      );
      // The server now returns the payment type, so a phone that has never
      // seen the SMS shows it too.
      await _pump(tester, repo: repo, tagsRepository: tags);
      expect(find.text('My SBI PhonePe RuPay card'), findsOneWidget);
      expect(find.text('UPI'), findsOneWidget);
      expect(find.text('UPI QR'), findsNothing);
      expect(find.text('UPI / bank account'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keeps the tapped spending row visible when the detail fetch is offline',
    (tester) async {
      final tapped = TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 10, 17),
        merchantName: 'Offline Merchant',
        categoryName: 'Shopping',
        cardDisplayName: 'HDFC Card',
        userCardId: 'uc1',
        source: 'sms',
        status: 'active',
      );
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(tapped, failFetch: true),
        initialEntry: tapped,
      );

      expect(find.text('Offline Merchant'), findsOneWidget);
      expect(find.text('HDFC Card'), findsOneWidget);
      expect(find.text('Transaction not available offline'), findsNothing);
    },
  );

  testWidgets(
    'shows merchant, card, category, and source for an active transaction',
    (tester) async {
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(750),
          occurredAt: DateTime(2026, 3, 1),
          merchantName: 'Corner Store',
          categoryName: 'Groceries',
          cardDisplayName: 'My Axis Card',
          userCardId: 'uc1',
          source: 'sms',
          status: 'active',
        ),
      );
      await _pump(tester, repo: repo);

      expect(find.text('Corner Store'), findsOneWidget);
      expect(find.text('My Axis Card'), findsOneWidget);
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('SMS'), findsOneWidget);
      expect(
        find.text('Refund, reversal, or delete transaction'),
        findsOneWidget,
      );
      expect(find.text('Edit transaction'), findsOneWidget);
    },
  );

  testWidgets('opens the edit page from the transaction detail action', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Corner Store',
        userCardId: 'uc1',
        source: 'sms',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    final editButton = find.text('Edit transaction');
    await tester.ensureVisible(editButton);
    await tester.tap(editButton);
    await tester.pumpAndSettle();

    expect(find.text('edit screen'), findsOneWidget);
  });

  testWidgets('saves a note and keeps it visible on the transaction', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Corner Store',
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    final noteDb = openInMemoryForTesting();
    addTearDown(noteDb.close);
    await _pump(
      tester,
      repo: repo,
      extraOverrides: [
        cacheNamespaceProvider.overrideWithValue('user:test'),
        responseCacheProvider.overrideWith((ref) async => ResponseCache(noteDb)),
      ],
    );

    final addNote = find.text('Add a note');
    await tester.ensureVisible(addNote);
    await tester.tap(addNote);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Bought for the office');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Local first: the note is queued for sync and the API is not called.
    final queued = SyncQueue(noteDb, namespace: 'user:test').pending();
    expect(queued.single.payload, {'note': 'Bought for the office'});
    expect(repo.lastNote, isNull);
    expect(find.text('Bought for the office'), findsOneWidget);
  });

  testWidgets('saves and displays a split across two people', (tester) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    final splitButton = find.text('Split this expense');
    await tester.ensureVisible(splitButton);
    await tester.tap(splitButton);
    await tester.pumpAndSettle();

    expect(find.text('Split expense'), findsOneWidget);
    final amounts = find.byType(TextField);
    await tester.enterText(amounts.at(0), '400');
    await tester.tap(find.text('Add a share'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(2), '600');
    await tester.enterText(find.byType(TextField).at(1), 'Priya');
    await tester.enterText(find.byType(TextField).at(3), 'Sujay');

    await tester.tap(find.text('Save split'));
    await tester.pumpAndSettle();
    expect(
      find.text("Saved. It will sync in the background."),
      findsOneWidget,
    );
    expect(repo.splits, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(repo.splits, hasLength(2));
    expect(repo.splits[0].amount, Money.fromRupees(400));
    expect(repo.splits[0].note, 'Priya');
    expect(repo.splits[1].amount, Money.fromRupees(600));
    expect(repo.splits[1].note, 'Sujay');
    expect(find.text('Split across 2 shares'), findsOneWidget);
    expect(find.text('Your share: ₹0.00'), findsOneWidget);
  });

  testWidgets(
    'editing shares validates amounts and preserves card and category',
    (tester) async {
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(1000),
          occurredAt: DateTime(2026, 3, 1),
          userCardId: 'uc1',
          source: 'manual',
          status: 'active',
        ),
        splits: [
          TransactionSplit(
            amount: Money.fromRupees(400),
            note: 'Priya',
            userCardId: 'uc1',
            categoryId: 'category1',
          ),
        ],
      );
      await _pump(tester, repo: repo);
      final button = find.text('Split across 1 share');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      for (final invalid in ['-10', '1.001', 'NaN', '1001']) {
        await tester.enterText(find.byType(TextField).at(0), invalid);
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save split'),
              )
              .onPressed,
          isNull,
        );
      }
      await tester.enterText(find.byType(TextField).at(0), '300.25');
      await tester.pump();
      await tester.tap(find.text('Save split'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(repo.splits.single.amount, Money.fromRupees(300.25));
      expect(repo.splits.single.userCardId, 'uc1');
      expect(repo.splits.single.categoryId, 'category1');
    },
  );

  testWidgets('can clear an existing split', (tester) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1000),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
      splits: [TransactionSplit(amount: Money.fromRupees(400), note: 'Priya')],
    );
    await _pump(tester, repo: repo);

    final splitButton = find.text('Split across 1 share');
    await tester.ensureVisible(splitButton);
    await tester.tap(splitButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.tap(find.text('Clear split'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(repo.splits, isEmpty);
    expect(find.text('Split this expense'), findsOneWidget);
  });

  testWidgets(
    'does not expose the raw token error when split loading is rejected',
    (tester) async {
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(1000),
          occurredAt: DateTime(2026, 3, 1),
          userCardId: 'uc1',
          source: 'sms',
          status: 'active',
        ),
        failSplits: true,
      );
      await _pump(tester, repo: repo);

      expect(
        find.textContaining('Missing or invalid access token'),
        findsNothing,
      );
      expect(find.textContaining("We couldn't load this yet"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets(
    'a phone-only v2 payment never asks the server for private splits',
    (tester) async {
      final id = 'v2:${'a' * 64}';
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: id,
          amount: Money.fromRupees(1000),
          occurredAt: DateTime(2026, 3, 1),
          source: 'sms',
          status: 'active',
        ),
        // The real API answers 400 "invalid transaction id" for this shape.
        failSplits: true,
      );
      await _pump(tester, repo: repo, transactionId: id);

      expect(find.textContaining('Could not load split details'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    },
  );

  testWidgets(
    'a phone-only SMS payment can be split privately and the labels stay on the phone',
    (tester) async {
      final id = 'v2:${'b' * 64}';
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: id,
          amount: Money.fromRupees(500),
          occurredAt: DateTime(2026, 11, 4),
          merchantName: 'ZOMATO',
          source: 'sms',
          status: 'active',
        ),
        failSplits: true,
      );
      await _pump(tester, repo: repo, transactionId: id);

      final action = find.text('Split this expense');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.textContaining('once this payment has synced'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('private-amount-0')), '200');
      await tester.enterText(find.byKey(const ValueKey('private-label-0')), 'Priya');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('split-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Split across 1 share'), findsOneWidget);
      expect(find.text('Priya'), findsOneWidget);
      expect(repo.splits, isEmpty, reason: 'never sent to the server');
    },
  );

  testWidgets(
    'an ignored transaction shows the exclusion banner and no ignore action',
    (tester) async {
      final repo = _FakeUserCardsRepository(
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(750),
          occurredAt: DateTime(2026, 3, 1),
          userCardId: 'uc1',
          source: 'manual',
          status: 'ignored',
        ),
      );
      await _pump(tester, repo: repo);

      expect(
        find.textContaining('excluded from caps and rankings'),
        findsOneWidget,
      );
      expect(
        find.text('Refund, reversal, or delete transaction'),
        findsNothing,
      );
    },
  );

  testWidgets('cardless UPI and unknown category are shown honestly', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    final httpClient = MockClient((request) async => http.Response('{}', 200));
    final tagsRepository = TransactionTagsRepository(
      database: database,
      namespace: 'test-user',
      apiBaseUrl: 'http://localhost',
      accessToken: 'test-token',
      client: httpClient,
    );
    addTearDown(() {
      httpClient.close();
      database.close();
    });
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(30),
        occurredAt: DateTime(2026, 10, 5),
        merchantName: 'Balaji enterprises',
        rail: TxnRail.upiQr,
        categoryName: null,
        cardDisplayName: null,
        instrumentKnown: false,
        source: 'sms',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo, tagsRepository: tagsRepository);

    expect(find.text('UPI / bank account'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Assign category'), findsOneWidget);
    expect(find.text('Add tag'), findsOneWidget);
    expect(find.text('—'), findsNothing);

    final categoryLabel = find.text('Category');
    final categoryValue = find.text('Other');
    expect(
      tester.getTopLeft(categoryLabel).dy,
      closeTo(tester.getTopLeft(categoryValue).dy, 1),
    );
    expect(
      tester.getTopLeft(find.widgetWithText(TextButton, 'Assign category')).dx,
      closeTo(tester.getTopLeft(categoryValue).dx, 1),
    );
    expect(
      tester.getCenter(find.text('Tags')).dy,
      closeTo(tester.getCenter(find.text('Add tag')).dy, 1),
    );
    expect(
      tester.getTopLeft(find.widgetWithText(TextButton, 'Add tag')).dx,
      closeTo(tester.getTopLeft(categoryValue).dx, 1),
    );
  });

  testWidgets('marking ignored queues the chosen reason for the server', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    await _pump(tester, repo: repo, extraOverrides: _outboxOverrides(db));

    await tester.tap(find.text('Refund, reversal, or delete transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();

    expect(repo.lastIgnoreReason, isNull, reason: 'the screen does not wait on the API');
    expect(await _deliver(db, repo), 1);
    expect(repo.lastIgnoreReason, 'refund');
  });

  testWidgets('an SMS payment can be marked as an own transfer or a card bill from the action sheet', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 'v2:e1',
        eventId: 'e1',
        sourceKey: 's' * 64,
        pipelineVersion: 2,
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        source: 'sms',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    await tester.tap(find.text('Refund, reversal, or delete transaction'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mark-own-transfer')), findsOneWidget);
    expect(find.text('Transfer between my accounts'), findsOneWidget);
    expect(find.byKey(const Key('mark-card-bill')), findsOneWidget);
    expect(find.text('Credit card bill payment'), findsOneWidget);
  });

  testWidgets('a manual entry does not get the SMS-only transfer and card bill actions', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    await tester.tap(find.text('Refund, reversal, or delete transaction'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mark-own-transfer')), findsNothing);
    expect(find.byKey(const Key('mark-card-bill')), findsNothing);
  });

  testWidgets('labels the transfer action as delete transaction', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    await _pump(tester, repo: repo, extraOverrides: _outboxOverrides(db));

    await tester.tap(find.text('Refund, reversal, or delete transaction'));
    await tester.pumpAndSettle();

    expect(find.text('Delete transaction'), findsOneWidget);
    await tester.tap(find.text('Delete transaction'));
    await tester.pumpAndSettle();
    expect(find.text('Delete transaction?'), findsOneWidget);

    // Cancel and Delete must share one row at equal size: the app-wide
    // FilledButton minimumSize is full-width, which otherwise wraps the
    // default action bar into a stacked full-width Delete.
    final cancelRect = tester.getRect(
      find.widgetWithText(OutlinedButton, 'Cancel'),
    );
    final deleteRect = tester.getRect(
      find.widgetWithText(FilledButton, 'Delete'),
    );
    expect(cancelRect.top, deleteRect.top);
    expect(cancelRect.height, deleteRect.height);
    expect(cancelRect.width, moreOrLessEquals(deleteRect.width));

    await tester.tap(find.text('Delete'), warnIfMissed: false);
    await tester.pumpAndSettle();

    await _deliver(db, repo);
    expect(repo.lastIgnoreReason, 'transfer');
  });

  testWidgets('a delete is saved on the phone and kept for retry when the server is down', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(750),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
      failIgnore: true,
    );
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    await _pump(tester, repo: repo, extraOverrides: _outboxOverrides(db));

    await tester.tap(find.text('Refund, reversal, or delete transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // The person's delete is honoured at once, without waiting on the API.
    expect(find.text('Transaction deleted.'), findsOneWidget);

    // A server that is down does not lose it: delivery fails, the command
    // stays queued, and it is not reported as sent.
    expect(await _deliver(db, repo), 0);
    expect(CommandOutbox(db, namespace: 'user:test').pendingCount, 1);
  });

  group('payment method label', () {
    TransactionEntry entryWith({
      String? method,
      TxnInstrument instrument = TxnInstrument.upiBank,
      String? card,
    }) => TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(5000),
      occurredAt: DateTime(2026, 3, 1),
      merchantName: 'Landlord',
      cardDisplayName: card,
      instrument: instrument,
      paymentMethod: method,
      source: 'manual',
      status: 'active',
    );

    testWidgets('shows Cheque where the bank account label was', (
      tester,
    ) async {
      await _pump(tester, repo: _FakeUserCardsRepository(entryWith(method: 'cheque')));
      expect(find.text('Cheque'), findsOneWidget);
      expect(find.text('UPI / bank account'), findsNothing);
    });

    testWidgets('falls back to the current label when there is no method', (
      tester,
    ) async {
      await _pump(tester, repo: _FakeUserCardsRepository(entryWith()));
      expect(find.text('UPI / bank account'), findsOneWidget);
    });

    testWidgets('a method that does not fit the instrument is not shown', (
      tester,
    ) async {
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(
          entryWith(method: 'cheque', instrument: TxnInstrument.cash),
        ),
      );
      expect(find.text('Cheque'), findsNothing);
      expect(find.text('Cash'), findsOneWidget);
    });

    testWidgets('a card name keeps priority and gains the method', (
      tester,
    ) async {
      await _pump(
        tester,
        repo: _FakeUserCardsRepository(
          entryWith(
            method: 'emi',
            instrument: TxnInstrument.creditCard,
            card: 'My Axis Card',
          ),
        ),
      );
      expect(find.text('My Axis Card · EMI'), findsOneWidget);
    });
  });
}
