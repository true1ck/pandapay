import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/sync_transaction_delta.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry row(String id, {String status = 'active'}) => TransactionEntry(
  id: id,
  amount: Money.fromPaise(100),
  occurredAt: DateTime(2026, 11, 1),
  source: 'manual',
  status: status,
);

void main() {
  late AppDatabase db;
  late FinancialStore store;
  late SyncQueue queue;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    queue = SyncQueue(db, namespace: 'user:a');
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  test(
    'coalesces IDs, retains inactive rows, and never deletes by absence',
    () async {
      store.saveTransactions('user:a', [row('older')]);
      final fetched = <String>[];
      final delta = await fetchSyncTransactionDelta(
        [
          {'entity_id': 'ignored', 'op': 'update'},
          {'entity_id': 'ignored', 'op': 'update'},
          {'entity_id': 'deleted', 'op': 'delete'},
        ],
        fetch: (id) async {
          fetched.add(id);
          return row(id, status: id);
        },
        isCurrent: () => true,
      );
      store.commitTransactionDelta(
        'user:a',
        delta.rows,
        delta.deletedIds,
        serverSeq: 7,
      );
      expect(fetched, ['ignored', 'deleted']);
      expect(
        store.entities('user:a', 'transactions').map((r) => r['id']).toSet(),
        {'older', 'ignored', 'deleted'},
      );
      expect(queue.lastServerSeq, 7);
      expect(
        store.transactions('user:a', const TransactionQuery())!.complete,
        isFalse,
      );
    },
  );

  test(
    'only explicit delete 404 removes a row and pending edits survive',
    () async {
      store.saveTransactions('user:a', [row('removed'), row('pending')]);
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'pending',
        fields: {'note': 'local'},
      );
      final delta = await fetchSyncTransactionDelta(
        [
          {'entity_id': 'removed', 'op': 'delete'},
          {'entity_id': 'pending', 'op': 'delete'},
        ],
        fetch: (_) async =>
            throw ApiException('GET /transactions/:id failed: 404 {}'),
        isCurrent: () => true,
      );
      store.commitTransactionDelta(
        'user:a',
        delta.rows,
        delta.deletedIds,
        serverSeq: 8,
      );
      expect(store.entities('user:a', 'transactions', id: 'removed'), isEmpty);
      expect(
        store.entities('user:a', 'transactions', id: 'pending').single['note'],
        'local',
      );
      expect(queue.pendingCount, 1);
    },
  );

  test('a 404 for an insert/update is skipped, not fatal (Q-10)', () async {
    store.saveTransactions('user:a', [row('still-here')]);
    final delta = await fetchSyncTransactionDelta(
      [
        {'entity_id': 'gone', 'op': 'update'},
        {'entity_id': 'new-one', 'op': 'insert'},
        {'entity_id': 'still-here', 'op': 'update'},
      ],
      fetch: (id) async {
        if (id == 'gone') {
          throw ApiException('GET /transactions/:id failed: 404 {}');
        }
        return row(id);
      },
      isCurrent: () => true,
    );
    expect(delta.rows.map((r) => r.id), ['new-one', 'still-here']);
    expect(delta.skippedIds, {'gone'});
    expect(delta.deletedIds, isEmpty);
    // The skipped row is not deleted locally either.
    store.saveTransactions('user:a', [row('gone')]);
    store.commitTransactionDelta(
      'user:a',
      delta.rows,
      delta.deletedIds,
      serverSeq: 9,
    );
    expect(store.entities('user:a', 'transactions', id: 'gone'), isNotEmpty);
  });

  test('non-404 failures still abort so the cursor is replayed', () async {
    for (final status in [401, 403, 500, 503]) {
      await expectLater(
        fetchSyncTransactionDelta(
          [
            {'entity_id': 'x', 'op': 'update'},
          ],
          fetch: (_) async =>
              throw ApiException('GET /transactions/:id failed: $status {}'),
          isCurrent: () => true,
        ),
        throwsA(isA<ApiException>()),
        reason: '$status',
      );
    }
  });

  test('failed cursor commit rolls back affected rows', () {
    db.db.execute(
      "CREATE TRIGGER fail_cursor BEFORE INSERT ON account_sync_state BEGIN SELECT RAISE(ABORT, 'disk full'); END;",
    );
    expect(
      () => store.commitTransactionDelta(
        'user:a',
        [row('new')],
        {},
        serverSeq: 9,
      ),
      throwsException,
    );
    expect(store.entities('user:a', 'transactions', id: 'new'), isEmpty);
    expect(queue.lastServerSeq, 0);
  });

  test('stale account response fails before publication', () async {
    var current = true;
    await expectLater(
      fetchSyncTransactionDelta(
        [
          {'entity_id': 'id', 'op': 'update'},
        ],
        fetch: (id) async {
          current = false;
          return row(id);
        },
        isCurrent: () => current,
      ),
      throwsStateError,
    );
    expect(queue.lastServerSeq, 0);
  });

  test('bounded fetch concurrency and ID cap prevent request bursts', () async {
    var active = 0;
    var peak = 0;
    var calls = 0;
    final changes = [
      for (var i = 0; i < 10; i++) {'entity_id': '$i', 'op': 'update'},
    ];
    await fetchSyncTransactionDelta(
      changes,
      concurrency: 2,
      fetch: (id) async {
        calls++;
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        return row(id);
      },
      isCurrent: () => true,
    );
    expect(peak, 2);
    expect(calls, 10);
    await expectLater(
      fetchSyncTransactionDelta(
        changes,
        maxIds: 3,
        fetch: (_) async => throw StateError('should not fetch'),
        isCurrent: () => true,
      ),
      throwsStateError,
    );
  });
}
