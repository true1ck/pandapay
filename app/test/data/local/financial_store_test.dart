import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry row(String id, {int day = 15, String? key, String? note}) =>
    TransactionEntry(
      id: id,
      amount: Money.fromPaise(12345),
      occurredAt: DateTime(2026, 10, day),
      sourceKey: key,
      merchantName: 'Shop',
      source: 'sms',
      status: 'active',
      note: note,
    );

void main() {
  late AppDatabase db;
  late FinancialStore store;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });
  const all = TransactionQuery();
  test(
    'targeted detail reads retain queued corrections and account isolation',
    () {
      store.saveTransactions('a', [row('one'), row('two')]);
      SyncQueue(db, namespace: 'a').enqueueUpdate(
        entity: 'transactions',
        entityId: 'one',
        fields: {'note': 'offline edit'},
      );
      final detail = store.entities('a', 'transactions', id: 'one');
      expect(detail, hasLength(1));
      expect(detail.single['note'], 'offline edit');
      expect(store.entities('b', 'transactions', id: 'one'), isEmpty);
    },
  );

  test('large-history duplicate replay stays quiet', () async {
    final history = [for (var i = 0; i < 3000; i++) row('transaction-$i')];
    store.saveTransactions('a', history, completeQuery: all);
    await Future<void>.delayed(Duration.zero);
    final events = <FinancialChange>[];
    final subscription = store.changes.listen(events.add);
    final watch = Stopwatch()..start();
    store.saveTransactions('a', history.take(200).toList());
    for (var i = 0; i < 200; i++) {
      store.discardProvisional('a', 'already-confirmed-$i');
    }
    watch.stop();
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    expect(store.transactions('a', all)!.rows, hasLength(3000));
    // Diagnostic only: device frame timings are validated separately.
    print(
      '3000-row history / 200-row replay and acknowledgements: ${watch.elapsedMilliseconds} ms (host)',
    );
    await subscription.cancel();
  });
  test(
    'duplicate acknowledgements do not invalidate transaction readers',
    () async {
      store.saveTransactions('a', [row('server', key: 'known')]);
      await Future<void>.delayed(Duration.zero);
      final events = <FinancialChange>[];
      final subscription = store.changes.listen(events.add);
      store.discardProvisional('a', 'known', confirmedId: 'server');
      store.discardProvisional('a', 'unknown');
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      expect(store.hasReceipt('a', 'known'), isTrue);
      expect(store.transactions('a', all)!.rows.single.id, 'server');
      await subscription.cancel();
    },
  );

  test(
    'bulk provisional acknowledgements publish one committed change',
    () async {
      store.saveProvisional('a', row('local-1', key: 'one'));
      store.saveProvisional('a', row('local-2', key: 'two'));
      await Future<void>.delayed(Duration.zero);
      final events = <FinancialChange>[];
      final subscription = store.changes.listen(events.add);
      store.batch(() {
        store.discardProvisional('a', 'one');
        store.discardProvisional('a', 'two');
        store.discardProvisional('a', 'missing');
      });
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(store.transactions('a', all), isNull);
      await subscription.cancel();
    },
  );

  test('older unchanged responses do not notify but newer edits do', () async {
    final now = DateTime(2026, 10, 18);
    store.saveTransactions('a', [row('one', note: 'current')], at: now);
    await Future<void>.delayed(Duration.zero);
    final events = <FinancialChange>[];
    final subscription = store.changes.listen(events.add);
    store.saveTransactions('a', [
      row('one', note: 'old'),
    ], at: now.subtract(const Duration(days: 1)));
    store.saveTransactions('a', [row('one', note: 'current')], at: now);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    store.saveTransactions('a', [
      row('one', note: 'updated'),
    ], at: now.add(const Duration(seconds: 1)));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(store.transactions('a', all)!.rows.single.note, 'updated');
    await subscription.cancel();
  });
  test('screens query one record and account boundaries are enforced', () {
    store.saveTransactions('user:a', [row('one')], completeQuery: all);
    expect(
      store
          .transactions(
            'user:a',
            TransactionQuery(from: DateTime(2026, 10, 1)),
          )!
          .rows
          .single
          .id,
      'one',
    );
    expect(store.transactions('user:b', all), isNull);
  });
  test(
    'successful empty response removes stale rows and remains known empty',
    () {
      store.saveTransactions('a', [row('old')], completeQuery: all);
      store.saveTransactions('a', [], completeQuery: all);
      final result = store.transactions('a', all)!;
      expect(result.rows, isEmpty);
      expect(result.complete, isTrue);
    },
  );
  test('range replacement cannot remove rows outside its scope', () {
    store.saveTransactions('a', [
      row('early', day: 1),
      row('late', day: 25),
    ], completeQuery: all);
    store.saveTransactions(
      'a',
      [],
      completeQuery: TransactionQuery(from: DateTime(2026, 10, 20)),
    );
    expect(store.transactions('a', all)!.rows.map((r) => r.id), ['early']);
  });
  test('partial observations retain their real age', () {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    store.saveTransactions('a', [row('one')], at: yesterday);
    final result = store.transactions('a', all)!;
    expect(result.complete, isFalse);
    expect(
      result.fetchedAt.millisecondsSinceEpoch,
      yesterday.millisecondsSinceEpoch,
    );
  });
  test(
    'same SMS identity is replaced by the confirmed server row exactly once',
    () {
      store.saveProvisional('a', row('local-sms:abc', key: 'abc'));
      store.saveProvisional('a', row('local-sms:abc', key: 'abc'));
      store.saveTransactions('a', [row('server-id', key: 'abc')]);
      store.saveProvisional('a', row('local-sms:abc', key: 'abc'));
      expect(store.transactions('a', all)!.rows.map((r) => r.id), [
        'server-id',
      ]);
    },
  );
  test('server refresh preserves pending device transactions', () {
    store.saveProvisional('a', row('local-sms:abc', key: 'abc'));
    store.saveTransactions('a', [], completeQuery: all);
    expect(store.transactions('a', all)!.rows.single.id, 'local-sms:abc');
  });

  test('removed server rows cannot be resurrected by an old SMS replay', () {
    store.saveTransactions('a', [
      row('server', key: 'message'),
    ], completeQuery: all);
    store.saveTransactions('a', [], completeQuery: all);
    store.saveProvisional('a', row('local-sms:message', key: 'message'));
    expect(store.transactions('a', all)!.rows, isEmpty);
  });

  test(
    'a late older response cannot overwrite a newer record or sync time',
    () {
      final newer = DateTime(2026, 10, 18);
      store.saveTransactions(
        'a',
        [row('id', note: 'new')],
        completeQuery: all,
        at: newer,
      );
      store.saveTransactions(
        'a',
        [row('id', note: 'old')],
        completeQuery: all,
        at: DateTime(2026, 10, 17),
      );
      final result = store.transactions('a', all)!;
      expect(result.rows.single.note, 'new');
      expect(result.fetchedAt, newer);
    },
  );
  test('queued correction overlays server state until acknowledged', () {
    store.saveTransactions('a', [row('id', note: 'old')], completeQuery: all);
    final queue = SyncQueue(db, namespace: 'a');
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'id',
      fields: {'note': 'edited offline'},
    );
    store.saveTransactions('a', [row('id', note: 'remote')]);
    expect(store.transactions('a', all)!.rows.single.note, 'edited offline');
    queue.remove(queue.pending().single.clientSeq);
    expect(store.transactions('a', all)!.rows.single.note, 'remote');
  });
  test('local search matches notes as well as merchants', () {
    store.saveTransactions('a', [row('id', note: 'Insurance renewal')]);
    expect(
      store
          .transactions('a', const TransactionQuery(query: 'insurance'))!
          .rows
          .single
          .id,
      'id',
    );
  });
  test(
    'legacy snapshots migrate once without resurrecting removed records',
    () {
      db.db.execute('INSERT INTO cached_responses VALUES (?,?,?)', [
        'a:transactions:all',
        jsonEncode({
          'transactions': [row('old').toJson()],
        }),
        1,
      ]);
      store.migrateLegacy('a');
      expect(store.transactions('a', all)!.rows.single.id, 'old');
      store.saveTransactions('a', [], completeQuery: all);
      store.migrateLegacy('a');
      expect(store.transactions('a', all)!.rows, isEmpty);
    },
  );
  test('clear removes one account without affecting another', () {
    store.saveTransactions('a', [row('a')], completeQuery: all);
    store.saveTransactions('b', [row('b')], completeQuery: all);
    store.clear('a');
    expect(store.transactions('a', all), isNull);
    expect(store.transactions('b', all)!.rows.single.id, 'b');
  });
  test(
    'commits notify consumers but identical server rows do not loop',
    () async {
      final events = <String>[];
      final subscription = store.changes.listen(
        (change) => events.add(change.namespace),
      );
      store.saveTransactions('a', [row('one')], completeQuery: all);
      store.saveTransactions('a', [row('one')], completeQuery: all);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['a']);
      await subscription.cancel();
    },
  );
}
