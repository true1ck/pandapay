import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/token_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _FakeUserCardsRepository implements UserCardsRepository {
  final TransactionEntry entry;
  final Object? fetchError;
  Map<String, dynamic>? lastEditArgs;
  int editCalls = 0;
  bool failFirstEditWithAuth = false;
  _FakeUserCardsRepository(this.entry, {this.fetchError});

  @override
  Future<TransactionEntry> fetchTransaction(String id) async {
    if (fetchError != null) throw fetchError!;
    return entry;
  }

  @override
  Future<void> editTransaction(
    String id, {
    double? amountInr,
    DateTime? occurredAt,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    TxnRail? rail,
    String? userCardId,
    TxnInstrument? instrument,
    TxnEntryKind? entryKind,
    Map<String, dynamic>? selfTransfer,
    bool clearCategory = false,
    String? paymentMethod,
    bool clearPaymentMethod = false,
  }) async {
    editCalls++;
    if (failFirstEditWithAuth && editCalls == 1) {
      throw ApiException(
        'PATCH /transactions/:id failed: 401 {"error":"unauthorized"}',
      );
    }
    lastEditArgs = {
      'id': id,
      'amountInr': amountInr,
      'merchantName': merchantName,
      'categoryId': categoryId,
      'userCardId': userCardId,
      'instrument': instrument,
      'entryKind': entryKind,
      'selfTransfer': selfTransfer,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SuccessfulRefreshCoordinator extends SessionRefreshCoordinator {
  _SuccessfulRefreshCoordinator()
    : super(
        loadStore: () async => TokenStore(const FlutterSecureStorage()),
        authApi: AuthApi(authBaseUrl: 'https://unused.invalid'),
        readAccessToken: () => 'old-token',
        writeAccessToken: (_) {},
      );

  @override
  Future<String?> refresh({String? expectedAccessToken}) async => 'new-token';
}

AppDatabase? _lastDb;

/// The one queued change for [namespace], i.e. what the save will send.
Map<String, Object?>? _queued(AppDatabase db, String namespace) {
  final pending = SyncQueue(db, namespace: namespace).pending();
  return _mergeTyped(db.db, pending.isEmpty ? null : pending.single.payload);
}

/// Sync-queue fields plus the typed fields that travel as their own command
/// (amount, category, card, rail, instrument...), keyed like the wire fields.
Map<String, Object?>? _mergeTyped(dynamic db, Map<String, Object?>? queued) {
  const snake = {
    'amountInr': 'amount_inr',
    'occurredAt': 'occurred_at',
    'categoryId': 'category_id',
    'userCategoryId': 'user_category_id',
    'userCardId': 'user_card_id',
    'entryKind': 'entry_kind',
  };
  final rows = db.select(
    "SELECT payload_json FROM command_outbox WHERE kind = 'transaction_typed_fields'",
  );
  if (rows.isEmpty) return queued;
  final merged = <String, Object?>{...?queued};
  for (final r in rows) {
    final p = jsonDecode(r['payload_json'] as String) as Map<String, dynamic>;
    p.remove('id');
    p.forEach((k, v) => merged[snake[k] ?? k] = v);
  }
  return merged;
}


Future<void> _pump(
  WidgetTester tester, {
  required _FakeUserCardsRepository repo,
  List<UserCard> cards = const [],
  TransactionEntry? initialEntry,
  List<Override> overrides = const [],
  bool withRouter = false,
}) async {
  final editor = EditTransactionScreen(
    transactionId: 't1',
    initialEntry: initialEntry,
  );
  final router = withRouter
      ? GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const Scaffold(),
              routes: [GoRoute(path: 'edit', builder: (context, state) => editor)],
            ),
          ],
        )
      : null;
  // A plain save is local first: it queues the change on the phone's own
  // database. Every pump gets one so the screen can resolve its queue.
  final db = openInMemoryForTesting();
  addTearDown(db.close);
  _lastDb = db;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cacheNamespaceProvider.overrideWithValue('user:test'),
        responseCacheProvider.overrideWith((ref) async => ResponseCache(db)),
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => cards),
        categoriesProvider.overrideWith((ref) async => const []),
        ...overrides,
      ],
      child: router == null
          ? MaterialApp(home: editor)
          : MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('reopening a self-transfer retains its destination for undo', (tester) async {
    final repo = _FakeUserCardsRepository(TransactionEntry(
      id: 't1', amount: Money.fromRupees(10000), occurredAt: DateTime(2026, 11, 1),
      merchantName: 'Self-transfer to Slice •5799', accountLast4: '1797',
      instrument: TxnInstrument.upiBank, entryKind: TxnEntryKind.transfer,
      source: 'sms', status: 'active',
      selfTransferRule: const {'destination': {'bank': 'slcbnk', 'accountLast4': '5799'}},
    ));
    await _pump(tester, repo: repo, withRouter: true, overrides: [
      bankAccountSummariesProvider.overrideWith((ref) async => const [
        BankAccountSummary(accountLast4: '5799', availableBalance: null,
          latestSmsAt: null, smsCount: 1, issuerSlug: 'slcbnk'),
      ]),
    ]);
    await tester.tap(find.byKey(const ValueKey(TxnEntryKind.transfer)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(TxnEntryKind.spend.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(repo.lastEditArgs?['entryKind'], TxnEntryKind.spend);
    expect(repo.lastEditArgs?['selfTransfer'], {
      'bank': 'slcbnk', 'accountLast4': '5799', 'action': 'disable',
    });
  });
  testWidgets('confirms the receiving owned account and saves a neutral self-transfer', (tester) async {
    final repo = _FakeUserCardsRepository(TransactionEntry(
      id: 't1', amount: Money.fromRupees(10000), occurredAt: DateTime(2026, 11, 1),
      merchantName: 'Transfer to slice small finance bank', accountLast4: '1797',
      instrument: TxnInstrument.upiBank, source: 'sms', status: 'active',
    ));
    await _pump(tester, repo: repo, withRouter: true, overrides: [
      bankAccountSummariesProvider.overrideWith((ref) async => const [
        BankAccountSummary(accountLast4: '5799', availableBalance: null,
          latestSmsAt: null, smsCount: 1, issuerSlug: 'slcbnk'),
      ]),
    ]);
    await tester.tap(find.byKey(const ValueKey('self-transfer-account:null')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Slice •5799').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(repo.lastEditArgs?['entryKind'], TxnEntryKind.transfer);
    expect(repo.lastEditArgs?['merchantName'], 'Self-transfer to Slice •5799');
    expect(repo.lastEditArgs?['selfTransfer'], {'bank': 'slcbnk', 'accountLast4': '5799', 'remember': false});
  });

  testWidgets('pre-fills amount and merchant from the existing transaction', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Old Merchant',
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    final amountField = tester.widget<TextField>(
      find.byType(TextField).at(0),
    );
    expect(amountField.controller!.text, '1250.00');
    final merchantField = tester.widget<TextField>(
      find.byType(TextField).at(1),
    );
    expect(merchantField.controller!.text, 'Old Merchant');
  });

  testWidgets('keeps an unknown payment method unset during unrelated edits', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Unknown Source',
        instrumentKnown: false,
        source: 'sms',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    expect(find.text('Unknown — choose a method'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).at(1),
      'Renamed merchant',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final queued = _queued(_lastDb!, 'user:test');
    expect(queued?['merchant_name'], 'Renamed merchant');
    // Only what changed is sent, so an unknown payment method stays unset.
    expect(queued?.containsKey('instrument'), isFalse);
    expect(repo.editCalls, 0, reason: 'a plain edit must not wait on the API');
  });

  testWidgets('rejects non-finite amounts before saving', (tester) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(100),
        occurredAt: DateTime(2026, 3, 1),
        source: 'sms',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);
    await tester.enterText(find.byType(TextField).at(0), 'NaN');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a valid amount greater than zero.'),
      findsOneWidget,
    );
    expect(repo.lastEditArgs, isNull);
  });

  testWidgets('keeps the tapped row editable when the edit fetch loses auth', (
    tester,
  ) async {
    final entry = TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(1250),
      occurredAt: DateTime(2026, 3, 1),
      merchantName: 'Offline Merchant',
      userCardId: 'uc1',
      source: 'manual',
      status: 'active',
    );
    await _pump(
      tester,
      repo: _FakeUserCardsRepository(
        entry,
        fetchError: ApiException(
          'GET /transactions/:id failed: 401 {"error":"Missing or invalid access token"}',
        ),
      ),
      initialEntry: entry,
    );

    // The route now passes the tapped row into the edit screen, so a token
    // refresh race cannot turn the form into a blank error state.
    expect(
      tester
          .widget<TextField>(find.byType(TextField).at(1))
          .controller!
          .text,
      'Offline Merchant',
    );
  });

  testWidgets('rejects a zero amount without calling the repository', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 3, 1),
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    await tester.enterText(find.byType(TextField).at(0), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.lastEditArgs, isNull);
    expect(find.textContaining('valid amount'), findsOneWidget);
  });

  testWidgets('Save sends the edited amount and merchant to the repository', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(1250),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Old Merchant',
        userCardId: 'uc1',
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    await tester.enterText(
      find.byType(TextField).at(0),
      '2000',
    );
    await tester.enterText(
      find.byType(TextField).at(1),
      'New Merchant',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final queued = _queued(_lastDb!, 'user:test');
    expect(queued?['amount_inr'], 2000.0);
    expect(queued?['merchant_name'], 'New Merchant');
    expect(queued?.containsKey('category_id'), isFalse);
    expect(repo.editCalls, 0);
  });

  testWidgets('an edit on a synced SMS row is queued without calling the API', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    const namespace = 'user:test';
    final cache = ResponseCache(database);
    final receivedAt = DateTime.utc(2026, 10, 28, 10);
    final sourceKey = SmsIntakeRepository(database).capture(
      namespace,
      QueuedSms(
        sender: 'AD-HDFCBK',
        body: 'Rs 500 debited at Store on 28-10-2026',
        receivedAt: receivedAt,
      ),
    );
    final entry = TransactionEntry(
      id: 't-sms',
      sourceKey: sourceKey,
      amount: Money.fromRupees(500),
      occurredAt: receivedAt,
      merchantName: 'Store',
      source: 'sms',
      status: 'active',
    );
    final repo = _FakeUserCardsRepository(entry)..failFirstEditWithAuth = true;

    await _pump(
      tester,
      repo: repo,
      initialEntry: entry,
      overrides: [
        sessionRefreshCoordinatorProvider.overrideWithValue(
          _SuccessfulRefreshCoordinator(),
        ),
        cacheNamespaceProvider.overrideWithValue(namespace),
        responseCacheProvider.overrideWith((ref) async => cache),
        isOnlineProvider.overrideWith((ref) => Stream.value(true)),
      ],
    );

    await tester.enterText(
      find.byType(TextField).at(1),
      'Correct Store',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.editCalls, 0, reason: 'the save never waits on the API');
    expect(_queued(database, namespace)?['merchant_name'], 'Correct Store');
  });

  testWidgets('a normal SMS edit saves and leaves the editor', (
    tester,
  ) async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    const namespace = 'user:normal-edit';
    final receivedAt = DateTime.utc(2026, 10, 28, 10);
    final sourceKey = SmsIntakeRepository(database).capture(
      namespace,
      QueuedSms(
        sender: 'AD-HDFCBK',
        body: 'Rs 500 debited at Store on 28-10-2026',
        receivedAt: receivedAt,
      ),
    );
    final entry = TransactionEntry(
      id: 't-sms',
      sourceKey: sourceKey,
      amount: Money.fromRupees(500),
      occurredAt: receivedAt,
      merchantName: 'Store',
      source: 'sms',
      status: 'active',
    );
    final repo = _FakeUserCardsRepository(entry);
    await _pump(
      tester,
      repo: repo,
      initialEntry: entry,
      withRouter: true,
      overrides: [
        cacheNamespaceProvider.overrideWithValue(namespace),
        responseCacheProvider.overrideWith(
          (ref) async => ResponseCache(database),
        ),
        isOnlineProvider.overrideWith((ref) => Stream.value(false)),
      ],
    );
    await tester.enterText(find.byType(TextField).at(0), '555');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.editCalls, 0);
    expect(_queued(database, namespace)?['amount_inr'], 555.0);
    expect(find.byType(EditTransactionScreen), findsNothing);
    expect(
      find.textContaining('Saved'),
      findsOneWidget,
      reason: 'Save must always say it worked; closing silently looked like nothing happened',
    );
  });

  testWidgets('a transfer on an SMS payment can be set to a credit card bill', (tester) async {
    final entry = TransactionEntry(
      id: 'v2:e1',
      eventId: 'e1',
      sourceKey: 's' * 64,
      pipelineVersion: 2,
      amount: Money.fromRupees(500),
      occurredAt: DateTime.utc(2026, 10, 28, 10),
      merchantName: 'Transfer',
      source: 'sms',
      status: 'active',
      instrument: TxnInstrument.upiBank,
      entryKind: TxnEntryKind.transfer,
    );
    await _pump(tester, repo: _FakeUserCardsRepository(entry), initialEntry: entry);
    expect(find.text('Transfer type'), findsOneWidget);
    expect(find.text('Between my accounts'), findsOneWidget);
    await tester.tap(find.text('Between my accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Credit card bill'), findsWidgets);
  });

  testWidgets('a transfer on a manual entry has no card-bill choice', (tester) async {
    final entry = TransactionEntry(
      id: 't-manual',
      amount: Money.fromRupees(500),
      occurredAt: DateTime.utc(2026, 10, 28, 10),
      merchantName: 'Savings',
      source: 'manual',
      status: 'active',
      instrument: TxnInstrument.upiBank,
      entryKind: TxnEntryKind.transfer,
    );
    await _pump(tester, repo: _FakeUserCardsRepository(entry), initialEntry: entry);
    expect(find.text('Transfer type'), findsNothing);
  });

  testWidgets('income transactions keep their kind editable without a card', (
    tester,
  ) async {
    final repo = _FakeUserCardsRepository(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(90000),
        occurredAt: DateTime(2026, 3, 1),
        merchantName: 'Employer',
        instrument: TxnInstrument.upiBank,
        entryKind: TxnEntryKind.income,
        source: 'manual',
        status: 'active',
      ),
    );
    await _pump(tester, repo: repo);

    expect(find.text('Money in'), findsOneWidget);
    expect(find.text('Card'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '95000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final queued = _queued(_lastDb!, 'user:test');
    expect(queued?['amount_inr'], 95000.0);
    // The kind was not touched, so it is not re-sent.
    expect(queued?.containsKey('entry_kind'), isFalse);
  });
}
