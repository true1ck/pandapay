import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// A refresh asked for before the server got an edit comes back with the older
/// copy. It must never leave the phone showing the edit as undone: not while
/// the edit waits, and not after it was delivered (the "disappears, then
/// reappears" report).
void main() {
  late AppDatabase db;
  late FinancialStore store;
  late CommandOutbox commands;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    commands = CommandOutbox(db, namespace: 'a');
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  TransactionEntry txn({String category = 'food', String status = 'active'}) =>
      TransactionEntry(
        id: 't1',
        amount: Money.fromPaise(10000),
        occurredAt: DateTime(2026, 11, 1),
        categoryId: category,
        merchantName: 'Shop',
        source: 'manual',
        status: status,
      );

  String? category() =>
      store.entities('a', 'transactions').single['category_id'] as String?;
  String? status() =>
      store.entities('a', 'transactions').single['status'] as String?;

  Future<void> deliver(String kind) => commands.flush({
    kind: (_) async {},
  }, onDelivered: (k, t) => store.settleDelivered('a', k, t));

  test('a category edit survives a stale refresh, before and after delivery', () async {
    store.saveTransactions('a', [txn()], at: DateTime(2026, 11, 1));
    // The edit: stored on the phone, queued for the server.
    store.patchTransaction('a', 't1', {'category_id': 'travel'});
    commands.enqueue(
      kind: 'transaction_typed_fields',
      target: 't1',
      payload: {'id': 't1', 'categoryId': 'travel'},
    );
    final requestedAt = DateTime.now(); // refresh sent, server lacks the edit
    // ...it answers late with the old copy.
    store.saveTransactions('a', [txn()], at: requestedAt);
    expect(category(), 'travel'); // overlay while queued

    await deliver('transaction_typed_fields');
    expect(category(), 'travel'); // the command is gone: the row itself holds it

    // A second stale answer, requested before delivery, arrives afterwards.
    store.saveTransactions('a', [txn()], at: requestedAt);
    expect(category(), 'travel');
  });

  test('a queued delete is not undone by a refresh', () {
    store.saveTransactions('a', [txn()], at: DateTime(2026, 11, 1));
    store.markInactive('a', 't1');
    commands.enqueue(
      kind: 'ignore_transaction',
      target: 't1',
      payload: {'id': 't1', 'reason': 'deleted'},
    );
    store.saveTransactions('a', [txn()], at: DateTime.now());
    expect(status(), 'ignored');
  });

  test('a complete refresh requested before a row was saved does not prune it', () async {
    final requestedAt = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    store.saveTransactions('a', [txn()]); // saved on the phone just after
    store.saveTransactions(
      'a',
      const [],
      completeQuery: const TransactionQuery(),
      at: requestedAt,
    );
    expect(store.entities('a', 'transactions'), hasLength(1));
  });

  group('edit time decides, not arrival time', () {
    TransactionEntry copy(String category, DateTime? editedAt) => TransactionEntry(
      id: 't1',
      amount: Money.fromPaise(10000),
      occurredAt: DateTime(2026, 11, 1),
      categoryId: category,
      merchantName: 'Shop',
      source: 'manual',
      status: 'active',
      editedAt: editedAt,
    );
    final t10 = DateTime.utc(2026, 11, 20, 10);

    test('a server copy of an older edit never replaces the local edit', () {
      store.saveTransactions('a', [copy('food', null)], at: DateTime(2026, 11, 1));
      store.patchTransaction('a', 't1', {'category_id': 'travel'}, editedAt: t10);
      // Arrives long after (far-future request time), yet describes an older edit.
      store.saveTransactions(
        'a',
        [copy('food', t10.subtract(const Duration(seconds: 1)))],
        at: DateTime.now().add(const Duration(days: 1)),
      );
      expect(category(), 'travel');
    });

    test('an undated copy loses while the edit waits, and wins once it is delivered', () async {
      store.saveTransactions('a', [copy('food', null)], at: DateTime(2026, 11, 1));
      store.patchTransaction('a', 't1', {'category_id': 'travel'}, editedAt: t10);
      commands.enqueue(
        kind: 'transaction_typed_fields',
        target: 't1',
        payload: {'id': 't1', 'categoryId': 'travel'},
      );
      final later = DateTime.now().add(const Duration(days: 1));
      // The server has not seen the edit: its copy has no edit time at all.
      store.saveTransactions('a', [copy('food', null)], at: later);
      expect(category(), 'travel');
      await deliver('transaction_typed_fields');
      // Delivered: the server's copy would carry the edit, so a copy is taken.
      store.saveTransactions('a', [copy('fuel', t10)], at: later.add(const Duration(seconds: 1)));
      expect(category(), 'fuel');
    });

    test('a copy with the same or a newer edit time is taken', () {
      store.saveTransactions('a', [copy('food', null)], at: DateTime(2026, 11, 1));
      store.patchTransaction('a', 't1', {'category_id': 'travel'}, editedAt: t10);
      final later = DateTime.now().add(const Duration(days: 1));
      store.saveTransactions('a', [copy('travel', t10)], at: later);
      expect(category(), 'travel');
      store.saveTransactions(
        'a',
        [copy('fuel', t10.add(const Duration(seconds: 5)))],
        at: later.add(const Duration(seconds: 1)),
      );
      expect(category(), 'fuel'); // another device edited after this phone
    });
  });
}
