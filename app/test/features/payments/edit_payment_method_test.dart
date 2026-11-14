import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart';
import 'package:pandapay/features/payments/payment_method_command.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Edit transaction "Paid with": the same chips as Quick Add, and a saved
/// payment method is only ever changed when the person changes it.
class _Repo implements UserCardsRepository {
  final TransactionEntry entry;
  int editCalls = 0;
  Map<String, Object?>? last;
  _Repo(this.entry);

  @override
  Future<TransactionEntry> fetchTransaction(String id) async => entry;

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
    last = {
      'instrument': instrument,
      'paymentMethod': paymentMethod,
      'clearPaymentMethod': clearPaymentMethod,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TransactionEntry _entry({
  TxnInstrument instrument = TxnInstrument.upiBank,
  String? method,
  TxnEntryKind kind = TxnEntryKind.spend,
  bool instrumentKnown = true,
  int pipelineVersion = 1,
  double amount = 5000,
}) => TransactionEntry(
  id: 't1',
  amount: Money.fromRupees(amount),
  occurredAt: DateTime(2026, 3, 1),
  merchantName: 'Landlord',
  instrument: instrument,
  instrumentKnown: instrumentKnown,
  paymentMethod: method,
  entryKind: kind,
  pipelineVersion: pipelineVersion,
  source: 'manual',
  status: 'active',
);

late AppDatabase _db;
_Repo? _repoUnderTest;
bool _onlineUnderTest = true;

Future<void> _pump(
  WidgetTester tester,
  _Repo repo, {
  bool online = true,
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = const Size(2400, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _db = openInMemoryForTesting();
  _repoUnderTest = repo;
  _onlineUnderTest = online;
  addTearDown(_db.close);
  final editor = EditTransactionScreen(
    transactionId: 't1',
    initialEntry: repo.entry,
  );
  final router = GoRouter(
    initialLocation: '/edit',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(),
        routes: [GoRoute(path: 'edit', builder: (context, state) => editor)],
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cacheNamespaceProvider.overrideWithValue('user:test'),
        responseCacheProvider.overrideWith((ref) async => ResponseCache(_db)),
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith((ref) async => const []),
        isOnlineProvider.overrideWith((ref) => Stream.value(online)),
        ...extra,
      ],
      // The app keeps the connectivity provider alive; do the same here so
      // the screen's one-off read sees the emitted value.
      child: Consumer(
        builder: (context, ref, _) {
          ref.watch(isOnlineProvider);
          return MaterialApp.router(routerConfig: router);
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?>? _queued() {
  final pending = SyncQueue(_db, namespace: 'user:test').pending();
  return _mergeTyped(_db.db, pending.isEmpty ? null : pending.single.payload);
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


bool _selected(WidgetTester tester, String key) {
  final chip = find.byKey(ValueKey(key));
  final semantics = tester.widget<Semantics>(
    find.descendant(of: chip, matching: find.byType(Semantics)).first,
  );
  return semantics.properties.selected ?? false;
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// The save is local first: it queues commands and the outbox delivers them
/// when online. Online, deliver them now and fold the PATCH calls into one
/// logical call so the assertions read the same as before.
Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
  final repo = _repoUnderTest;
  if (!_onlineUnderTest || repo == null) return;
  final rows = _db.db.select(
    "SELECT kind, payload_json FROM command_outbox ORDER BY rowid",
  );
  if (rows.isEmpty) return;
  final handlers = paymentMethodCommandHandlers(repo);
  Object? instrument;
  Object? method;
  var clear = false;
  for (final r in rows) {
    await handlers[r['kind'] as String]!(
      jsonDecode(r['payload_json'] as String) as Map<String, dynamic>,
    );
    instrument ??= repo.last!['instrument'];
    method ??= repo.last!['paymentMethod'];
    clear = clear || repo.last!['clearPaymentMethod'] == true;
  }
  _db.db.execute('DELETE FROM command_outbox');
  repo.editCalls = 1;
  repo.last = {
    'instrument': instrument,
    'paymentMethod': method,
    'clearPaymentMethod': clear,
  };
}

void main() {
  testWidgets('shows the saved instrument and method as selected', (
    tester,
  ) async {
    await _pump(tester, _Repo(_entry(method: 'cheque')));
    expect(_selected(tester, 'payment-chip-instrument-upi_bank'), isTrue);
    expect(_selected(tester, 'payment-chip-method-cheque'), isTrue);
    expect(find.text('Paid with'), findsOneWidget);
  });

  testWidgets('an untouched edit of a row with a method sends no method', (
    tester,
  ) async {
    final repo = _Repo(_entry(method: 'cheque'));
    await _pump(tester, repo);
    await tester.enterText(find.widgetWithText(TextField, 'Merchant'), 'New');
    await _save(tester);

    expect(repo.editCalls, 0, reason: 'a plain edit still goes through the queue');
    final queued = _queued()!;
    expect(queued['merchant_name'], 'New');
    expect(queued.containsKey('payment_method'), isFalse);
    expect(queued.containsKey('instrument'), isFalse);
  });

  testWidgets('a row with no method edits exactly as before', (tester) async {
    final repo = _Repo(_entry());
    await _pump(tester, repo);
    expect(_selected(tester, 'payment-chip-instrument-upi_bank'), isTrue);
    await _tapKey(tester, 'payment-chip-instrument-cash');
    await _save(tester);

    // WP-C5: while online an instrument change goes through the domain PATCH
    // route (the sync writer may refuse typed columns), so it is never lost.
    expect(repo.editCalls, 1);
    expect(repo.last!['instrument'], TxnInstrument.cash);
    expect(repo.last!['paymentMethod'], isNull);
    expect(_queued(), isNull);
  });

  testWidgets('choosing NEFT from More saves it through the direct update', (
    tester,
  ) async {
    final repo = _Repo(_entry());
    await _pump(tester, repo);
    await _tapKey(tester, 'payment-more-chip');
    await _tapKey(tester, 'payment-more-option-neft');
    await _save(tester);

    expect(repo.editCalls, 1);
    expect(repo.last!['paymentMethod'], 'neft');
    expect(repo.last!['clearPaymentMethod'], isFalse);
    // Only what changed travels; the unchanged instrument is not re-sent.
    expect(repo.last!['instrument'], isNull);
    expect(_queued(), isNull);
  });

  testWidgets('choosing Cheque on a row with no method sends cheque', (
    tester,
  ) async {
    final repo = _Repo(_entry());
    await _pump(tester, repo);
    await _tapKey(tester, 'payment-chip-method-cheque');
    await _save(tester);

    expect(repo.last!['paymentMethod'], 'cheque');
  });

  testWidgets('switching a cheque to cash clears the saved method', (
    tester,
  ) async {
    final repo = _Repo(_entry(method: 'cheque'));
    await _pump(tester, repo);
    await _tapKey(tester, 'payment-chip-instrument-cash');
    await _save(tester);

    expect(repo.editCalls, 1);
    expect(repo.last!['instrument'], TxnInstrument.cash);
    expect(repo.last!['paymentMethod'], isNull);
    expect(repo.last!['clearPaymentMethod'], isTrue);
  });

  testWidgets('removing the method from More clears it', (tester) async {
    final repo = _Repo(_entry(method: 'neft'));
    await _pump(tester, repo);
    await _tapKey(tester, 'payment-more-chip');
    await _tapKey(tester, 'payment-more-clear');
    await _save(tester);

    expect(repo.last!['clearPaymentMethod'], isTrue);
    expect(repo.last!['paymentMethod'], isNull);
  });

  testWidgets('a method change offline is queued as a command, never dropped', (
    tester,
  ) async {
    final repo = _Repo(_entry());
    await _pump(tester, repo, online: false);
    await _tapKey(tester, 'payment-chip-method-cheque');
    await _save(tester);

    expect(repo.editCalls, 0);
    final commands = _db.db.select(
      'SELECT kind, target, payload_json FROM command_outbox',
    );
    expect(commands, hasLength(1));
    expect(commands.single['kind'], 'transaction_payment_method');
    expect(commands.single['target'], 't1');
    expect(jsonDecode(commands.single['payload_json'] as String)['paymentMethod'], 'cheque');
    expect(find.textContaining('Connect to the internet'), findsNothing);
  });

  testWidgets('the queued method command sends the same PATCH when delivered', (
    tester,
  ) async {
    final repo = _Repo(_entry());
    final handlers = paymentMethodCommandHandlers(repo);
    await handlers[PaymentMethodCommand.set]!({'id': 't1', 'paymentMethod': 'neft'});
    expect(repo.last!['paymentMethod'], 'neft');
    expect(repo.last!['clearPaymentMethod'], isFalse);
    await handlers[PaymentMethodCommand.set]!({'id': 't1', 'paymentMethod': null});
    expect(repo.last!['clearPaymentMethod'], isTrue);
  });

  testWidgets('instrument change while offline is queued for the sync writer', (
    tester,
  ) async {
    final repo = _Repo(_entry());
    await _pump(tester, repo, online: false);
    await _tapKey(tester, 'payment-chip-instrument-cash');
    await _save(tester);

    expect(repo.editCalls, 0);
    expect(_queued()!['instrument'], 'cash');
  });

  testWidgets('self-transfer confirm offline is refused in plain words', (
    tester,
  ) async {
    final repo = _Repo(
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(10000),
        occurredAt: DateTime(2026, 11, 1),
        merchantName: 'Transfer to slice small finance bank',
        accountLast4: '1797',
        instrument: TxnInstrument.upiBank,
        source: 'sms',
        status: 'active',
      ),
    );
    await _pump(
      tester,
      repo,
      online: false,
      extra: [
        bankAccountSummariesProvider.overrideWith(
          (ref) async => const [
            BankAccountSummary(
              accountLast4: '5799',
              availableBalance: null,
              latestSmsAt: null,
              smsCount: 1,
              issuerSlug: 'slcbnk',
            ),
          ],
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('self-transfer-account:null')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Slice •5799').last);
    await tester.pumpAndSettle();
    await _save(tester);

    expect(repo.editCalls, 0);
    expect(_queued(), isNull);
    expect(find.textContaining('You are offline'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
  });

  testWidgets('a legacy UPI row keeps its method on an unrelated edit', (
    tester,
  ) async {
    final repo = _Repo(_entry(method: 'upi'));
    await _pump(tester, repo);
    await tester.enterText(find.widgetWithText(TextField, 'Merchant'), 'New');
    await _save(tester);

    expect(repo.editCalls, 0);
    expect(_queued()!.containsKey('payment_method'), isFalse);
  });

  testWidgets('an unknown-instrument row still shows its hint and sends nothing',
      (tester) async {
    final repo = _Repo(_entry(instrumentKnown: false));
    await _pump(tester, repo);
    expect(find.text('Unknown — choose a method'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Merchant'), 'New');
    await _save(tester);
    expect(_queued()!.containsKey('instrument'), isFalse);
  });

  testWidgets('an SMS-ledger row offers instruments only (no method)', (
    tester,
  ) async {
    await _pump(tester, _Repo(_entry(pipelineVersion: 2, method: 'upi')));
    expect(find.byKey(const ValueKey('payment-more-chip')), findsNothing);
    expect(find.byKey(const ValueKey('payment-chip-method-cheque')), findsNothing);
    expect(find.byKey(const ValueKey('payment-chip-instrument-cash')), findsOneWidget);
  });

  testWidgets('tapping away and back to the saved instrument keeps the method', (
    tester,
  ) async {
    final repo = _Repo(_entry(method: 'cheque'));
    await _pump(tester, repo);
    await _tapKey(tester, 'payment-chip-instrument-cash');
    await _tapKey(tester, 'payment-chip-instrument-upi_bank');
    await tester.enterText(find.widgetWithText(TextField, 'Merchant'), 'New');
    await _save(tester);

    // Same instrument and method as saved: an ordinary offline-capable edit.
    expect(repo.editCalls, 0);
    expect(_queued()!.containsKey('payment_method'), isFalse);
    expect(_queued()!.containsKey('instrument'), isFalse);
  });

  testWidgets('switching a legacy UPI row to cash offline still queues the edit', (
    tester,
  ) async {
    final repo = _Repo(_entry(method: 'upi'));
    await _pump(tester, repo, online: false);
    await _tapKey(tester, 'payment-chip-instrument-cash');
    await _save(tester);

    expect(
      find.text('Connect to the internet to change how this was paid.'),
      findsNothing,
    );
    expect(repo.editCalls, 0);
    expect(_queued(), isNotNull);
    expect(_queued()!.containsKey('payment_method'), isFalse);
  });

  testWidgets('clearing a method on the same instrument stays cleared', (
    tester,
  ) async {
    final repo = _Repo(_entry(method: 'cheque'));
    await _pump(tester, repo);
    await _tapKey(tester, 'payment-chip-method-cheque');
    await _save(tester);

    expect(repo.last!['clearPaymentMethod'], isTrue);
  });
}
