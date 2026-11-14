import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/card_bill_payment.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// V5: a manual card-bill payment must survive a complete-query refresh and be
/// queued for the server; undo removes it.
void main() {
  const ns = 'user:a';
  late AppDatabase db;
  late FinancialStore store;
  late TransactionOutboxRepository outbox;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    outbox = TransactionOutboxRepository(db, namespace: ns, financialStore: store);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  const all = TransactionQuery();
  Future<void> pay() => enqueueCardBillPayment(
    outbox,
    txnId: 'payment-card-2026-11',
    amount: Money.fromRupees(500),
    cardId: 'card',
    cardName: 'Synthetic Card',
    last4: '0000',
  );

  test('payment survives a full refresh and is queued once', () async {
    await pay();
    await pay(); // saving twice replays the same mutation
    store.saveTransactions(ns, [], completeQuery: all);
    final rows = store.transactions(ns, all)!.rows;
    expect(rows, hasLength(1));
    expect(rows.single.entryKind, TxnEntryKind.transfer);
    expect(rows.single.userCardId, 'card');
    expect(await outbox.all(), hasLength(1));
    expect(
      (await outbox.all()).single.clientMutationId,
      cardBillPaymentMutationId('payment-card-2026-11'),
    );
  });

  test('undo removes the queued payment', () async {
    await pay();
    undoCardBillPayment(outbox, store, ns, 'payment-card-2026-11');
    expect(await outbox.all(), isEmpty);
    expect(store.transactions(ns, all)?.rows ?? const [], isEmpty);
  });
}
