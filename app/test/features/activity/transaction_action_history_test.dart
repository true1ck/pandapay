import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/activity/transaction_action_history.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('history keeps newest first, filters by payment, survives undone', () {
    final db = sqlite3.openInMemory()
      ..execute(
        'CREATE TABLE v2_sync_state(namespace TEXT, key TEXT, value TEXT, '
        'PRIMARY KEY(namespace,key))',
      );
    final h = TransactionActionHistory(db, namespace: 'n');
    TxnActionRecord rec(String id, List<String> targets) => TxnActionRecord(
      id: id,
      at: DateTime.utc(2026, 11, 14),
      action: 'refund',
      title: 'Shop',
      amountPaise: 119000,
      scope: 'Only this payment',
      targets: targets,
      undo: const {'kind': 'ignore'},
    );
    h.save(rec('000000000000000001', ['a']));
    h.save(rec('000000000000000002', ['a', 'b']));
    expect(h.list().map((r) => r.id), [
      '000000000000000002',
      '000000000000000001',
    ]);
    expect(h.list(transactionId: 'b'), hasLength(1));

    h.save(h.list().first.markUndone(DateTime.utc(2026, 11, 15)));
    final first = h.list().first;
    expect(first.isUndone, isTrue);
    expect(first.undo['kind'], 'ignore');
    expect(first.amountPaise, 119000);
  });
}
