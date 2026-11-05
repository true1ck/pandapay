import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/account_recovery_operation_gate.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_schema.dart';
import 'package:sqlite3/sqlite3.dart';

const accountA = 'user:11111111-1111-4111-8111-111111111111';
const accountB = 'user:22222222-2222-4222-8222-222222222222';
const contextId = '33333333-3333-4333-8333-333333333333';
const op1 = '44444444-4444-4444-8444-444444444444';
const op2 = '55555555-5555-4555-8555-555555555555';
SharedCommand command([String id = op1]) => SharedCommand(
  operationId: id,
  kind: 'context.create',
  payload: {'contextId': contextId, 'title': 'Flatmates'},
);
SharedOperationReceipt receipt(SharedCommand c) => SharedOperationReceipt(
  operationId: c.operationId,
  kind: c.kind,
  requestHash: c.requestHash,
  contextId: contextId,
  result: {'created': true},
);
SharedProjection projection({String title = 'Flatmates', int revision = 1}) =>
    SharedProjection(
      entity: 'contexts',
      id: contextId,
      contextId: contextId,
      revision: revision,
      payload: {'title': title},
    );

void main() {
  final vectors =
      jsonDecode(
            File(
              '../contracts/shared_expenses/v1/command_vectors.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final vector in vectors['cases'] as List) {
    test('cross-runtime canonical/hash fixture ${vector['id']}', () {
      final canonical = sharedCanonicalJson(vector['input']);
      expect(canonical, vector['canonical']);
      expect(
        sha256.convert(utf8.encode(canonical)).toString(),
        vector['sha256'],
      );
      if (sharedCommandKinds.contains((vector['input'] as Map)['kind'])) {
        expect(
          SharedCommand.fromJson(vector['input']).requestHash,
          vector['sha256'],
        );
      }
    });
  }
  late Directory temp;
  late AppDatabase db;
  late SharedExpensesStore store;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('p05-shared-');
    db = AppDatabase.forTesting(sqlite3.open('${temp.path}/data.sqlite'));
    store = SharedExpensesStore(db, namespace: accountA);
  });
  tearDown(() {
    db.close();
    temp.deleteSync(recursive: true);
  });

  test(
    'canonical request hash includes operation ID, preserves arrays and freezes payload',
    () {
      final payload = <String, Object?>{
        'title': 'Flatmates',
        'contextId': contextId,
        'nested': {'b': '2', 'a': '1'},
        'ids': ['b', 'a'],
      };
      final c = SharedCommand(
        operationId: op1,
        kind: 'context.create',
        payload: payload,
      );
      final same = SharedCommand(
        operationId: op1,
        kind: 'context.create',
        payload: {
          'ids': ['b', 'a'],
          'nested': {'a': '1', 'b': '2'},
          'contextId': contextId,
          'title': 'Flatmates',
        },
      );
      expect(c.requestHash, same.requestHash);
      payload['title'] = 'changed';
      expect(c.toJson()['payload'], isNot(containsPair('title', 'changed')));
      expect(command(op2).requestHash, isNot(command().requestHash));
    },
  );

  test(
    'canonical limits reject depth, huge node graphs, key newlines and cycles',
    () {
      Object? deep = 'value';
      for (var i = 0; i < 17; i++) {
        deep = {'child': deep};
      }
      final cycle = <Object?>[];
      cycle.add(cycle);
      for (final value in [
        deep,
        cycle,
        List.generate(9, (_) => List.filled(1000, null)),
        {'bad\n': 'x'},
      ]) {
        expect(() => sharedCanonicalJson(value), throwsFormatException);
      }
    },
  );

  test('database trigger blocks immutable payload mutation', () async {
    await store.enqueue(command());
    expect(
      () => db.db.execute(
        'UPDATE shared_commands SET request_json=? WHERE namespace=? AND operation_id=?',
        ['{}', accountA, op1],
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(store.operation(op1)!.command.requestHash, command().requestHash);
  });

  test(
    'future module schema is passive for core app but strict for shared writes',
    () {
      db.db.execute(
        "INSERT INTO cached_responses VALUES('personal-history','{}',1)",
      );
      db.db.execute(
        "UPDATE shared_schema_version SET version=999 WHERE module='shared_expenses'",
      );
      final before = db.db
          .select("SELECT name,sql FROM sqlite_master ORDER BY name")
          .map((row) => row.values.toList())
          .toList();
      expect(
        SharedExpensesSchema.ensure(db.db, allowNewerVersion: true),
        isFalse,
      );
      expect(
        db.db
            .select(
              "SELECT version FROM shared_schema_version WHERE module='shared_expenses'",
            )
            .single['version'],
        999,
      );
      expect(
        db.db
            .select("SELECT name,sql FROM sqlite_master ORDER BY name")
            .map((row) => row.values.toList())
            .toList(),
        before,
      );
      expect(
        db.db.select(
          "SELECT * FROM cached_responses WHERE key='personal-history'",
        ),
        hasLength(1),
      );
      expect(() => SharedExpensesSchema.ensure(db.db), throwsFormatException);
      expect(
        () => SharedExpensesStore(db, namespace: accountA),
        throwsFormatException,
      );
    },
  );

  test(
    'version one file upgrades indexes without changing pending financial bytes',
    () async {
      final expected = command();
      await store.enqueue(expected, provisional: {'title': 'Pending'});
      db.db.execute('DROP INDEX shared_projection_overview');
      db.db.execute('DROP INDEX shared_command_context');
      db.db.execute('DROP TABLE shared_editor_drafts');
      db.db.execute('DROP TABLE shared_editor_receipts');
      db.db.execute(
        "UPDATE shared_schema_version SET version=1 WHERE module='shared_expenses'",
      );
      db.close();
      db = AppDatabase.forTesting(sqlite3.open('${temp.path}/data.sqlite'));
      SharedExpensesSchema.ensure(db.db);
      store = SharedExpensesStore(db, namespace: accountA);
      expect(
        store.operation(op1)!.command.canonicalJson,
        expected.canonicalJson,
      );
      expect(store.provisional(op1), {'title': 'Pending'});
      expect(
        db.db.select(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='shared_projection_overview'",
        ),
        hasLength(1),
      );
    },
  );

  test(
    'an identical retained receipt reconciles a restored pending command once',
    () async {
      await store.enqueue(command());
      final first = (await store.claim(now: 0, leaseId: 'worker'))!;
      await store.complete(first, receipt(command()), [projection()]);
      // Recovery can retain a confirmed receipt while resetting uncertain local
      // delivery metadata. The server lookup is still authoritative on replay.
      db.db.execute(
        "UPDATE shared_commands SET state='pending' WHERE namespace=? AND operation_id=?",
        [accountA, op1],
      );
      final retry = (await store.claim(now: 1, leaseId: 'worker'))!;
      expect(
        await store.complete(retry, receipt(command()), [projection()]),
        isTrue,
      );
      expect(
        db.db.select(
          'SELECT * FROM shared_operation_receipts WHERE namespace=?',
          [accountA],
        ),
        hasLength(1),
      );
    },
  );

  test(
    'revocation atomically purges private cached scope and fences retained commands',
    () async {
      await store.enqueue(
        command(),
        provisional: {'title': 'Private proposal'},
      );
      await store.applyPage(
        SharedChangePage(records: [projection()], nextCursor: 'before'),
        expectedCursor: null,
      );
      await store.applyPage(
        SharedChangePage(
          records: [],
          nextCursor: 'revoked',
          revokedContextIds: [contextId],
        ),
        expectedCursor: 'before',
      );
      expect(store.isContextRevoked(contextId), isTrue);
      expect(store.readContexts().items, isEmpty);
      expect(store.provisional(op1), isNull);
      expect(store.readPendingOperations().items, isEmpty);
      expect(
        store.operation(op1),
        isNotNull,
        reason: 'Immutable authored command remains recoverable',
      );
      expect(await store.claim(now: 999999, leaseId: 'worker'), isNull);
      await store.applyPage(
        SharedChangePage(
          records: [projection(revision: 2)],
          nextCursor: 'granted',
          grantedContextIds: [contextId],
        ),
        expectedCursor: 'revoked',
      );
      expect(store.isContextRevoked(contextId), isFalse);
      expect(store.readContexts().items, hasLength(1));
      expect(
        (await store.claim(
          now: 999999,
          leaseId: 'worker',
        ))!.command.operationId,
        op1,
      );
    },
  );

  test(
    'paginated regrant stays hidden through restart and renewed revocation',
    () async {
      await store.applyPage(
        SharedChangePage(
          records: [],
          nextCursor: 'revoked',
          revokedContextIds: [contextId],
        ),
        expectedCursor: null,
      );
      await store.applyPage(
        SharedChangePage(
          records: [projection(revision: 2)],
          nextCursor: 'partial',
          hasMore: true,
        ),
        expectedCursor: 'revoked',
      );
      expect(store.readContexts().items, isEmpty);
      db.close();
      db = AppDatabase.forTesting(sqlite3.open('${temp.path}/data.sqlite'));
      store = SharedExpensesStore(db, namespace: accountA);
      expect(store.cursor, 'partial');
      expect(store.readContexts().items, isEmpty);
      await store.applyPage(
        SharedChangePage(
          records: [],
          nextCursor: 'again',
          revokedContextIds: [contextId],
        ),
        expectedCursor: 'partial',
      );
      expect(
        db.db.select('SELECT * FROM shared_projections WHERE namespace=?', [
          accountA,
        ]),
        isEmpty,
      );
      await store.applyPage(
        SharedChangePage(
          records: [projection(revision: 3)],
          nextCursor: 'full',
          hasMore: true,
        ),
        expectedCursor: 'again',
      );
      expect(store.readContexts().items, isEmpty);
      await store.applyPage(
        SharedChangePage(
          records: [],
          nextCursor: 'grant',
          grantedContextIds: [contextId],
        ),
        expectedCursor: 'full',
      );
      expect(store.readContexts().items.single.revision, 3);
    },
  );

  test(
    'explicit retryable serialization conflict reuses immutable operation',
    () async {
      await store.enqueue(command());
      final claim = (await store.claim(now: 0, leaseId: 'worker'))!;
      await store.fail(claim, statusCode: 409, retryable: true, now: 0);
      expect(store.operation(op1)!.state, SharedCommandState.retry);
      expect(
        (await store.claim(
          now: 999999,
          leaseId: 'worker',
        ))!.command.requestHash,
        command().requestHash,
      );
    },
  );

  test(
    'hub context and pending operation reads use bounded namespace keysets',
    () async {
      await store.enqueue(command(), provisional: {'title': 'Pending'});
      await store.enqueue(command(op2), createdAt: 1);
      final first = store.readPendingOperations(limit: 1);
      expect(first.items, hasLength(1));
      expect(first.items.single.provisional, {'title': 'Pending'});
      expect(
        store
            .readPendingOperations(afterId: first.nextId, limit: 1)
            .items
            .single
            .command
            .operationId,
        op2,
      );
      await store.applyPage(
        SharedChangePage(
          records: [
            projection(),
            SharedProjection(
              entity: 'contexts',
              id: op2,
              contextId: op2,
              revision: 1,
              payload: {'title': 'Trip'},
            ),
          ],
          nextCursor: 'c1',
        ),
        expectedCursor: null,
      );
      final contexts = store.readContexts(limit: 1);
      expect(contexts.items, hasLength(1));
      expect(
        store
            .readContexts(afterId: contexts.nextId, limit: 1)
            .items
            .single
            .payload['title'],
        'Trip',
      );
      final other = SharedExpensesStore(db, namespace: accountB);
      expect(other.readContexts().items, isEmpty);
      expect(other.readPendingOperations().items, isEmpty);
    },
  );

  test(
    'observer failure cannot turn a committed enqueue into a retryable failure',
    () async {
      final previous = FlutterError.onError;
      final errors = <FlutterErrorDetails>[];
      FlutterError.onError = errors.add;
      try {
        final observed = SharedExpensesStore(
          db,
          namespace: accountA,
          onChanged: () => throw StateError('private input'),
        );
        await observed.enqueue(command());
        expect(observed.operation(op1), isNotNull);
        expect(errors, hasLength(1));
        expect(
          errors.single.exception.toString(),
          isNot(contains('private input')),
        );
      } finally {
        FlutterError.onError = previous;
      }
    },
  );

  test('same worker label cannot acknowledge a replacement lease', () async {
    await store.enqueue(command());
    final old = (await store.claim(
      now: 0,
      leaseId: 'same',
      leaseDurationMs: 10,
    ))!;
    final replacement = (await store.claim(now: 11, leaseId: 'same'))!;
    expect(replacement.leaseId, isNot(old.leaseId));
    expect(
      await store.complete(old, receipt(command()), [projection()]),
      isFalse,
    );
    expect(
      await store.complete(replacement, receipt(command()), [projection()]),
      isTrue,
    );
  });

  test(
    'mid-projection failure rolls back every accepted row and receipt',
    () async {
      await store.enqueue(command(), provisional: {'title': 'Pending'});
      final claim = (await store.claim(now: 0, leaseId: 'worker'))!;
      expect(
        () => store.complete(claim, receipt(command()), [
          projection(),
          projection(title: 'Duplicate'),
        ]),
        throwsA(isA<SharedLocalException>()),
      );
      expect(store.receipt(op1), isNull);
      expect(store.provisional(op1), isNotNull);
      expect(
        store.readPage(entity: 'contexts', contextId: contextId).items,
        isEmpty,
      );
    },
  );

  test('401 waits for explicit same-account reauthentication', () async {
    await store.enqueue(command());
    final claim = (await store.claim(now: 0, leaseId: 'worker'))!;
    await store.fail(claim, statusCode: 401, now: 0);
    expect(store.operation(op1)!.state, SharedCommandState.awaitingAuth);
    expect(await store.claim(now: 999999, leaseId: 'worker'), isNull);
    await store.resumeAuthentication();
    expect(
      (await store.claim(now: 999999, leaseId: 'worker'))!.command.requestHash,
      command().requestHash,
    );
  });

  test(
    'projection paging is scoped, bounded and does not infer absent deletions',
    () async {
      await store.applyPage(
        SharedChangePage(
          records: List.generate(
            100,
            (i) => SharedProjection(
              entity: 'expenses',
              id: 'e${i.toString().padLeft(3, '0')}',
              contextId: contextId,
              revision: 1,
              payload: {'number': i},
            ),
          ),
          nextCursor: 'p1',
          hasMore: true,
        ),
        expectedCursor: null,
      );
      final first = store.readPage(
        entity: 'expenses',
        contextId: contextId,
        limit: 50,
      );
      expect(first.items, hasLength(50));
      expect(first.nextId, 'e049');
      expect(
        store
            .readPage(
              entity: 'expenses',
              contextId: contextId,
              afterId: first.nextId,
              limit: 50,
            )
            .items,
        hasLength(50),
      );
      await store.applyPage(
        SharedChangePage(records: [], nextCursor: 'done'),
        expectedCursor: 'p1',
      );
      expect(
        store
            .readPage(entity: 'expenses', contextId: contextId, limit: 100)
            .items,
        hasLength(100),
      );
      final other = SharedExpensesStore(db, namespace: accountB);
      expect(
        other.readPage(entity: 'expenses', contextId: contextId).items,
        isEmpty,
      );
      expect(
        () => store.readPage(
          entity: 'expenses',
          contextId: contextId,
          limit: 101,
        ),
        throwsA(isA<SharedLocalException>()),
      );
    },
  );

  test(
    'recovery admission and account fencing stop new local side effects',
    () async {
      final gate = AccountRecoveryOperationGate();
      var current = true;
      final scoped = SharedExpensesStore(
        db,
        namespace: accountA,
        recoveryGate: gate,
        isCurrent: () => current,
      );
      await gate.exclusive(() async {
        expect(
          () => scoped.enqueue(command()),
          throwsA(isA<AccountRecoveryBusy>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(scoped.operation(op1), isNull);
      });
      current = false;
      await expectLater(
        () => scoped.enqueue(command()),
        throwsA(isA<SharedLocalException>()),
      );
      expect(scoped.operation(op1), isNull);
    },
  );
  test(
    'command rejects nonJSON, unsafe numbers, numeric money, deep and oversized content',
    () {
      for (final value in <Object?>[
        double.nan,
        1.1,
        BigInt.one,
        DateTime.now(),
        9007199254740992,
      ]) {
        expect(
          () => SharedCommand(
            operationId: op1,
            kind: 'context.create',
            payload: {'contextId': contextId, 'value': value},
          ),
          throwsFormatException,
        );
      }
      expect(
        () => SharedCommand(
          operationId: op1,
          kind: 'settlement.report',
          payload: {'contextId': contextId, 'amountMinor': 30000},
        ),
        throwsFormatException,
      );
      expect(
        () => SharedCommand(
          operationId: op1,
          kind: 'context.create',
          payload: {'contextId': contextId, 'title': 'x' * 66000},
        ),
        throwsFormatException,
      );
      expect(
        () => SharedCommand(
          operationId: op1,
          kind: 'context.create',
          payload: {
            'contextId': contextId,
            'title': String.fromCharCode(0xd800),
          },
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'upgrade preserves legacy rows and module version never changes user_version',
    () {
      db.db.execute("INSERT INTO cached_responses VALUES ('old','{}',1)");
      final original = db.db.select('PRAGMA user_version').single.values.single;
      SharedExpensesStore(db, namespace: accountA);
      expect(db.db.select('SELECT * FROM cached_responses'), hasLength(1));
      expect(
        db.db.select('PRAGMA user_version').single.values.single,
        original,
      );
    },
  );
  test(
    'immutable command and provisional overlay persist through file reopen',
    () async {
      final c = command();
      await store.enqueue(c, provisional: {'title': 'Offline proposal'});
      db.close();
      db = AppDatabase.forTesting(sqlite3.open('${temp.path}/data.sqlite'));
      store = SharedExpensesStore(db, namespace: accountA);
      expect(store.operation(op1)!.command.requestHash, c.requestHash);
      expect(store.provisional(op1), {'title': 'Offline proposal'});
      expect(store.operation(op1)!.state, SharedCommandState.pending);
      final other = SharedExpensesStore(db, namespace: accountB);
      expect(other.operation(op1), isNull);
      expect(other.provisional(op1), isNull);
    },
  );
  test('a command the server refused for good is not "syncing"', () async {
    await store.enqueue(command());
    expect(store.waitingCount, 1);
    db.db.execute(
      "UPDATE shared_commands SET state='rejected',error_code='http_403' WHERE namespace=?",
      [accountA],
    );
    expect(store.waitingCount, 0);
    expect(store.pendingCount, 1);
  });
  test(
    'reusing an ID is idempotent for same bytes and rejects changed payload',
    () async {
      await store.enqueue(command());
      await store.enqueue(command());
      expect(store.pendingCount, 1);
      expect(
        () => store.enqueue(
          SharedCommand(
            operationId: op1,
            kind: 'context.create',
            payload: {'contextId': contextId, 'title': 'Other'},
          ),
        ),
        throwsA(isA<SharedLocalException>()),
      );
    },
  );
  test(
    'durable lease prevents a second connection and recovers after expiry',
    () async {
      await store.enqueue(command());
      final first = await store.claim(
        now: 1000,
        leaseId: 'worker-one',
        leaseDurationMs: 100,
      );
      final secondDb = AppDatabase.forTesting(
        sqlite3.open('${temp.path}/data.sqlite'),
      );
      try {
        final second = SharedExpensesStore(secondDb, namespace: accountA);
        expect(await second.claim(now: 1001, leaseId: 'worker-two'), isNull);
        final reclaimed = await second.claim(now: 1101, leaseId: 'worker-two');
        expect(reclaimed!.command.operationId, first!.command.operationId);
        expect(reclaimed.command.requestHash, first.command.requestHash);
        expect(
          await store.complete(first, receipt(command()), [projection()]),
          isFalse,
        );
      } finally {
        secondDb.close();
      }
    },
  );
  test(
    'source and operation dependencies block without rewriting original command',
    () async {
      await store.enqueue(command(), sourceDependencies: ['source-pending']);
      await store.enqueue(command(op2), dependsOn: [op1]);
      expect(await store.claim(now: 1, leaseId: 'worker'), isNull);
      await store.resolveSourceDependency('source-pending');
      final claim = await store.claim(now: 2, leaseId: 'worker');
      expect(claim!.command.operationId, op1);
      expect(claim.command.requestHash, command().requestHash);
      await store.complete(claim, receipt(command()), [projection()]);
      expect(
        (await store.claim(now: 3, leaseId: 'worker'))!.command.operationId,
        op2,
      );
    },
  );
  test(
    'receipt, projection and provisional cleanup commit atomically',
    () async {
      final c = command();
      await store.enqueue(c, provisional: {'title': 'Pending'});
      final claim = (await store.claim(now: 1, leaseId: 'worker'))!;
      expect(await store.complete(claim, receipt(c), [projection()]), isTrue);
      expect(store.operation(op1)!.state, SharedCommandState.committed);
      expect(store.provisional(op1), isNull);
      expect(store.receipt(op1)!.requestHash, c.requestHash);
      expect(
        store
            .readPage(entity: 'contexts', contextId: contextId)
            .items
            .single
            .payload['title'],
        'Flatmates',
      );
    },
  );
  test('wrong receipt scope or hash cannot publish accepted content', () async {
    await store.enqueue(command(), provisional: {'title': 'Pending'});
    final claim = (await store.claim(now: 1, leaseId: 'worker'))!;
    final wrong = SharedOperationReceipt(
      operationId: op1,
      kind: 'context.create',
      requestHash: 'a' * 64,
      contextId: contextId,
      result: {},
    );
    expect(
      () => store.complete(claim, wrong, [projection()]),
      throwsA(isA<SharedLocalException>()),
    );
    expect(store.provisional(op1), isNotNull);
    expect(store.receipt(op1), isNull);
    expect(
      store.readPage(entity: 'contexts', contextId: contextId).items,
      isEmpty,
    );
  });
  test(
    '409 conflict is durable and never auto-retries a modified payload',
    () async {
      await store.enqueue(command());
      final claim = (await store.claim(now: 1, leaseId: 'worker'))!;
      await store.fail(claim, statusCode: 409, now: 1);
      expect(store.operation(op1)!.state, SharedCommandState.conflict);
      db.close();
      db = AppDatabase.forTesting(sqlite3.open('${temp.path}/data.sqlite'));
      store = SharedExpensesStore(db, namespace: accountA);
      expect(await store.claim(now: 999999, leaseId: 'other'), isNull);
      expect(store.operation(op1)!.command.requestHash, command().requestHash);
    },
  );
  test(
    'pull page and cursor commit together, old revision never overwrites newer',
    () async {
      await store.applyPage(
        SharedChangePage(records: [projection(revision: 2)], nextCursor: 'c2'),
        expectedCursor: null,
      );
      expect(store.cursor, 'c2');
      await store.applyPage(
        SharedChangePage(
          records: [projection(title: 'Old', revision: 1)],
          nextCursor: 'c3',
        ),
        expectedCursor: 'c2',
      );
      expect(
        store
            .readPage(entity: 'contexts', contextId: contextId)
            .items
            .single
            .payload['title'],
        'Flatmates',
      );
      expect(
        () => store.applyPage(
          SharedChangePage(
            records: [projection(title: 'Wrong', revision: 3)],
            nextCursor: 'bad',
          ),
          expectedCursor: 'stale',
        ),
        throwsA(isA<SharedLocalException>()),
      );
      expect(store.cursor, 'c3');
      expect(
        store
            .readPage(entity: 'contexts', contextId: contextId)
            .items
            .single
            .revision,
        2,
      );
    },
  );
}
