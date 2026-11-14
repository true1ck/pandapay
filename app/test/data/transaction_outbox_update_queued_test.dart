// Editing a transaction that is still only a queued quick-add rewrites the
// queued entry (it has no server id to patch). Synthetic data only.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test('updateQueued rewrites the queued entry and the list row', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final store = FinancialStore(db);
    final outbox = TransactionOutboxRepository(
      db,
      namespace: 'user:a',
      financialStore: store,
    );
    await outbox.enqueue(
      amount: Money.fromRupees(500),
      merchantName: 'Synthetic Shop',
      clientMutationId: 'mutation-1',
    );

    final changed = await outbox.updateQueued('mutation-1', {
      'amount_paise': Money.fromRupees(700).paise,
      'merchant_name': 'Other Shop',
    });

    expect(changed, isTrue);
    final entry = (await outbox.all()).single;
    expect(entry.amountPaise, 70000);
    expect(entry.merchantName, 'Other Shop');
    final row = store
        .entities('user:a', 'transactions')
        .firstWhere((r) => r['id'] == 'local-outbox:mutation-1');
    expect(row['amount_inr'], 700);
  });

  test('updateQueued says false once the entry was delivered', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final outbox = TransactionOutboxRepository(db, namespace: 'user:a');
    expect(await outbox.updateQueued('gone', {'amount_paise': 100}), isFalse);
  });
}
