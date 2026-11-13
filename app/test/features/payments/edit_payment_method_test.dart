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

Future<void> _pump(
  WidgetTester tester,
  _Repo repo, {
  bool online = true,
}) async {
  tester.view.physicalSize = const Size(2400, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _db = openInMemoryForTesting();
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
  return pending.isEmpty ? null : pending.single.payload;
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

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
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

    expect(repo.editCalls, 0);
    final queued = _queued()!;
    expect(queued['instrument'], 'cash');
    expect(queued.containsKey('payment_method'), isFalse);
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
    expect(repo.last!['instrument'], TxnInstrument.upiBank);
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

  testWidgets('a method change offline is refused, never dropped', (
    tester,
  ) async {
    final repo = _Repo(_entry());
    await _pump(tester, repo, online: false);
    await _tapKey(tester, 'payment-chip-method-cheque');
    await _save(tester);

    expect(repo.editCalls, 0);
    expect(_queued(), isNull);
    expect(
      find.text('Connect to the internet to change how this was paid.'),
      findsOneWidget,
    );
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
