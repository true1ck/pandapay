import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_read_worker.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/portable_backup/account_recovery_operation_gate.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry transaction(String id, {int day = 1}) => TransactionEntry(
  id: id,
  amount: Money.fromPaise(100),
  occurredAt: DateTime(2026, 11, day),
  source: 'manual',
  status: 'active',
);

void main() {
  late Directory directory;
  late AppDatabase database;
  late FinancialStore store;
  late FinancialReadWorker worker;
  late AccountRecoveryOperationGate gate;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pandapay-read-worker-');
    database = AppDatabase.openFile('${directory.path}/financial.sqlite');
    store = FinancialStore(database);
    gate = AccountRecoveryOperationGate();
    worker = FinancialReadWorker(database.filePath!, recoveryGate: gate);
  });

  tearDown(() async {
    await worker.close();
    store.dispose();
    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'returns bounded stable pages with pending edits and account isolation',
    () async {
      store.saveTransactions('user:a', [
        transaction('older', day: 1),
        transaction('a', day: 2),
        transaction('b', day: 2),
        transaction('c', day: 2),
      ], completeQuery: const TransactionQuery());
      store.saveTransactions('user:b', [transaction('private', day: 3)]);
      SyncQueue(database, namespace: 'user:a').enqueueUpdate(
        entity: 'transactions',
        entityId: 'c',
        fields: {'note': 'offline edit'},
      );
      final first = await worker.readTransactions(
        'user:a',
        const TransactionQuery(),
        limit: 2,
      );
      expect(first.rows.map((row) => row.id), ['c', 'b']);
      expect(first.rows.first.note, 'offline edit');
      expect(first.hasStoredCoverage, isTrue);
      expect(first.hasMore, isTrue);
      expect(first.nextCursor, isNotNull);
      final second = await worker.readTransactions(
        'user:a',
        const TransactionQuery(),
        limit: 2,
        cursor: first.nextCursor,
      );
      expect(second.rows.map((row) => row.id), ['a', 'older']);
      expect(second.hasMore, isFalse);
      expect(second.nextCursor, isNull);
      expect(() => first.rows.clear(), throwsUnsupportedError);
    },
  );

  test(
    'cursor cannot cross an account or query and bounds fail before admission',
    () async {
      store.saveTransactions('user:a', [transaction('a'), transaction('b')]);
      final first = await worker.readTransactions(
        'user:a',
        const TransactionQuery(),
        limit: 1,
      );
      await expectLater(
        worker.readTransactions(
          'user:b',
          const TransactionQuery(),
          cursor: first.nextCursor,
        ),
        throwsArgumentError,
      );
      await expectLater(
        worker.readTransactions(
          'user:a',
          const TransactionQuery(source: 'sms'),
          cursor: first.nextCursor,
        ),
        throwsArgumentError,
      );
      await expectLater(
        worker.readTransactions('user:a', const TransactionQuery(), limit: 201),
        throwsArgumentError,
      );
      expect(gate.activeOperations, 0);
    },
  );

  test(
    'recovery drains admitted reads and refuses new reads while exclusive',
    () async {
      store.saveTransactions('user:a', [transaction('one')]);
      final read = worker.readTransactions('user:a', const TransactionQuery());
      expect(gate.activeOperations, 1);
      var enteredRecovery = false;
      final recovery = gate.exclusive(() async {
        enteredRecovery = true;
        await expectLater(
          worker.readTransactions('user:a', const TransactionQuery()),
          throwsA(isA<AccountRecoveryBusy>()),
        );
      });
      expect(enteredRecovery, isFalse);
      expect((await read).rows.single.id, 'one');
      await recovery;
      expect(enteredRecovery, isTrue);
      expect(gate.activeOperations, 0);
    },
  );

  test(
    'stale account results are rejected and close drains the worker',
    () async {
      store.saveTransactions('user:a', [transaction('one')]);
      var current = true;
      final read = worker.readTransactions(
        'user:a',
        const TransactionQuery(),
        isCurrent: () => current,
      );
      current = false;
      await expectLater(read, throwsStateError);
      await worker.close();
      expect(gate.activeOperations, 0);
      await expectLater(
        worker.readTransactions('user:a', const TransactionQuery()),
        throwsStateError,
      );
    },
  );

  test('missing history differs from a saved empty snapshot', () async {
    final missing = await worker.readTransactions(
      'user:a',
      const TransactionQuery(),
    );
    expect(missing.fetchedAt, isNull);
    expect(missing.hasStoredCoverage, isFalse);
    store.saveTransactions(
      'user:a',
      [],
      completeQuery: const TransactionQuery(),
    );
    final empty = await worker.readTransactions(
      'user:a',
      const TransactionQuery(),
    );
    expect(empty.rows, isEmpty);
    expect(empty.fetchedAt, isNotNull);
    expect(empty.hasStoredCoverage, isTrue);
  });

  test('keyset cursor retains sub-millisecond transaction ordering', () async {
    final base = DateTime(2026, 11, 1);
    TransactionEntry precise(String id, int micros) => TransactionEntry(
      id: id,
      amount: Money.fromPaise(100),
      occurredAt: base.add(Duration(microseconds: micros)),
      source: 'manual',
      status: 'active',
    );
    store.saveTransactions('user:a', [precise('a', 200), precise('z', 100)]);
    final first = await worker.readTransactions(
      'user:a',
      const TransactionQuery(),
      limit: 1,
    );
    final second = await worker.readTransactions(
      'user:a',
      const TransactionQuery(),
      limit: 1,
      cursor: first.nextCursor,
    );
    expect(first.rows.single.id, 'a');
    expect(second.rows.single.id, 'z');
  });
}
