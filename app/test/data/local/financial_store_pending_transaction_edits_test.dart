import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';

/// F3 / F2: a queued transaction edit (typed PATCH command) is laid over the
/// stored row at read time, so the server's older copy never wins while the
/// edit is waiting, and every reader (rows, totals) sees the same value.
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

  Map<String, dynamic> row(num amount) => {
    'id': 't1',
    'amount_inr': amount,
    'category_id': 'c1',
    'merchant_name': 'Shop A',
    'occurred_at': '2026-11-01T10:00:00.000Z',
  };

  void seed(num amount) {
    db.db.execute(
      "INSERT OR REPLACE INTO financial_entities(namespace, entity, id, payload, observed_at, pending) "
      "VALUES ('a', 'transactions', 't1', ?, 1, 0)",
      [jsonEncode(row(amount))],
    );
  }

  num amount() =>
      store.entities('a', 'transactions').single['amount_inr'] as num;

  test('a queued amount edit still wins after the server copy arrives', () {
    seed(888);
    commands.enqueue(
      kind: 'transaction_typed_fields',
      target: 't1',
      payload: {'id': 't1', 'amountInr': 999},
    );
    expect(amount(), 999);
    seed(888); // an older server copy lands (refresh / detail fetch)
    expect(amount(), 999);
    expect(
      store.entities('a', 'transactions', id: 't1').single['amount_inr'],
      999,
    );
    expect(
      store.hasPendingTransactions('a'),
      isTrue,
      reason: 'reports must rebuild from the local rows, not a cached total',
    );
  });

  test('clearing the category is shown too, and a payment method edit', () {
    seed(100);
    commands.enqueue(
      kind: 'transaction_typed_fields',
      target: 't1',
      payload: {'id': 't1', 'categoryId': null},
    );
    commands.enqueue(
      kind: 'transaction_payment_method',
      target: 't1',
      payload: {'id': 't1', 'paymentMethod': 'upi'},
    );
    final r = store.entities('a', 'transactions').single;
    expect(r.containsKey('category_id'), isFalse);
    expect(r['payment_method'], 'upi');
  });

  test('once delivered (command gone) the stored value shows', () {
    seed(888);
    commands.enqueue(
      kind: 'transaction_typed_fields',
      target: 't1',
      payload: {'id': 't1', 'amountInr': 999},
    );
    db.db.execute('DELETE FROM command_outbox');
    expect(amount(), 888);
    expect(store.hasPendingTransactions('a'), isFalse);
  });
}
