import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sync_status/saved_data_caption.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test('deleted list is built from local rows ignored on this phone', () {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final store = ResponseCache(database).financialStore;
    TransactionEntry row(String id) => TransactionEntry(
      id: id,
      amount: Money.fromRupees(10),
      occurredAt: DateTime(2026, 10, 1),
      source: 'manual',
      status: 'active',
    );
    store.saveTransactions(
      'ns',
      [row('keep'), row('gone'), row('refund')],
      completeQuery: const TransactionQuery(),
      at: DateTime(2026, 10, 2),
    );
    store.markInactive('ns', 'gone');
    store.markInactive('ns', 'refund', reason: 'refund');

    expect(store.deletedTransactions('ns').map((r) => r.id), ['gone']);
    expect(store.deletedTransactions('other'), isEmpty);
  });

  test('saved-data caption names the time, and the date when not today', () {
    final now = DateTime(2026, 11, 14, 20);
    expect(
      savedDataCaption(DateTime(2026, 11, 14, 18, 40), now: now),
      'Saved data · updated 6:40 PM',
    );
    expect(
      savedDataCaption(DateTime(2026, 11, 12, 9, 5), now: now),
      'Saved data · updated 12 Nov, 9:05 AM',
    );
  });
}
