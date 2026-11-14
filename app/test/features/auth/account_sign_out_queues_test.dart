import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/connectivity/known_connectivity.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/queue_registry.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/statement_import_outbox.dart';
import 'package:pandapay/data/local/transaction_attachments_repository.dart';
import 'package:pandapay/data/secure_storage/statement_import_batch_cipher.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/auth/account_sign_out.dart';
import 'package:pandapay/features/auth/account_sign_out_provider.dart';
import 'package:pandapay/features/auth/sign_out_queues.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sync/sync_engine.dart';

/// WP-C3 / L-02 / Q-11: the sign-out report and flush read every queue from
/// QueueRegistry. Synthetic ids only.
const _a = 'user:11111111-1111-4111-8111-111111111111';
const _b = 'user:22222222-2222-4222-8222-222222222222';

class _NoCipher implements StatementImportBatchCipher {
  @override
  Future<Uint8List> encrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List plaintext,
  }) => throw UnimplementedError();

  @override
  Future<Uint8List> decrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List ciphertext,
  }) => throw UnimplementedError();
}

class _FakeEngine implements SyncEngine {
  _FakeEngine({this.completes = true});
  final bool completes;
  int calls = 0;

  @override
  Future<SyncResult> sync() async {
    calls++;
    return SyncResult(
      pushed: 0,
      pulled: 0,
      conflicts: 0,
      ranToCompletion: completes,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeRepo implements UserCardsRepository {
  final ignored = <String>[];

  @override
  Future<void> ignoreTransaction(String id, {required String reason}) async {
    ignored.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;

  void run(String sql, [List<Object?> args = const []]) =>
      db.db.execute(sql, args);

  /// Creates the tables that their owners create lazily, through the owners.
  void createLazyTables() {
    SmsV2Schema.ensure(db.db);
    ensureForeignPaymentsSchema(db);
    SmsIntakeRepository(db);
    StatementImportOutbox(db.db, namespace: _a, cipher: _NoCipher());
    run('''CREATE TABLE IF NOT EXISTS split_documents (
      namespace TEXT NOT NULL, transaction_id TEXT NOT NULL,
      document_json TEXT NOT NULL, pending INTEGER NOT NULL DEFAULT 0,
      version INTEGER NOT NULL DEFAULT 0, fetched_at INTEGER NOT NULL,
      error TEXT, blocked INTEGER NOT NULL DEFAULT 0,
      attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(namespace, transaction_id))''');
    run('''CREATE TABLE IF NOT EXISTS command_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT, namespace TEXT NOT NULL,
      kind TEXT NOT NULL, target TEXT NOT NULL, payload_json TEXT NOT NULL,
      created_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT, next_attempt_at INTEGER NOT NULL DEFAULT 0,
      parked INTEGER NOT NULL DEFAULT 0)''');
  }

  /// One waiting entry in every send queue of [ns] (statement import gets a
  /// stored batch of an open session).
  void seedEveryQueue(String ns) {
    run(
      'INSERT INTO sync_pending_changes '
      '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
      "VALUES (?, 'transactions', 'e1', 'update', '{}', '{}', 1)",
      [ns],
    );
    run(
      'INSERT INTO transaction_outbox_entries '
      '(namespace, client_mutation_id, amount_paise, created_at) VALUES (?, ?, 1, 1)',
      [ns, 'm-$ns'],
    );
    run(
      'INSERT INTO duplicate_resolution_outbox '
      '(namespace, candidate_id, resolution, created_at) VALUES (?, ?, ?, 1)',
      [ns, 'p1', 'kept_both'],
    );
    run(
      'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
      "VALUES (?, 'x', 't1', '{}', 1)",
      [ns],
    );
    run(
      'INSERT INTO transaction_tag_outbox (namespace, mutation_id, payload_json) '
      "VALUES (?, 'm1', '{}')",
      [ns],
    );
    run(
      'INSERT INTO foreign_payments_outbox (namespace, source_key, kind, payload) '
      "VALUES (?, 's1', 'k', '{}')",
      [ns],
    );
    run(
      'INSERT INTO shared_commands '
      '(namespace, operation_id, context_id, kind, request_json, request_hash, state, created_at) '
      "VALUES (?, 'op1', 'c', 'k', '{}', 'h', 'pending', 1)",
      [ns],
    );
    run(
      'INSERT INTO split_documents (namespace, transaction_id, document_json, pending, fetched_at) '
      "VALUES (?, 't1', '{}', 1, 1)",
      [ns],
    );
    run(
      "INSERT INTO v2_outbox (namespace, id, kind, payload) VALUES (?, 'k:1', 'k', '{}')",
      [ns],
    );
    run(
      "INSERT INTO sms_intake (namespace, id, sender, body, received_at) VALUES (?, 'i1', 'S', 'b', 1)",
      [ns],
    );
    run(
      'INSERT INTO statement_import_sessions '
      '(namespace, session_id, plan_hash, batch_count, state, created_at_ms, updated_at_ms, expires_at_ms) '
      "VALUES (?, 's-open', ?, 1, 'pending', 1, 1, 9)",
      [ns, 'a' * 64],
    );
    run(
      'INSERT INTO statement_import_batches '
      '(namespace, session_id, ordinal, import_key, payload_hash, payload_bytes, ciphertext) '
      "VALUES (?, 's-open', 1, ?, ?, 10, ?)",
      [ns, '01${'k' * 62}', 'h' * 64, Uint8List.fromList([1, 2, 3])],
    );
  }

  setUp(() {
    db = openInMemoryForTesting();
    createLazyTables();
    KnownConnectivity.reset();
  });
  tearDown(() {
    KnownConnectivity.reset();
    db.close();
  });

  group('other accounts on the same database (H1-6)', () {
    test('their unsent work is counted and named in the warning', () {
      seedEveryQueue(_b);
      final registry = QueueRegistry(db);
      expect(unsentInOtherAccounts(registry, db.db, _a), 11);
      expect(unsentInOtherAccounts(registry, db.db, _b), 0);

      final report = SignOutReport(
        unsynced: 0,
        phoneOnlyReceipts: 0,
        phoneOnlyReviewItems: 0,
        otherAccountsUnsent: 11,
      );
      expect(report.losesSomething, isTrue);
      expect(
        signOutWarningMessage(report),
        'Another account on this phone has 11 unsent changes that will also be deleted.',
      );
    });

    test('own and other losses are both in one message', () {
      final text = signOutWarningMessage(
        const SignOutReport(
          unsynced: 2,
          phoneOnlyReceipts: 0,
          phoneOnlyReviewItems: 0,
          otherAccountsUnsent: 1,
        ),
      );
      expect(text, contains('2 changes haven'));
      expect(
        text,
        endsWith(
          'Another account on this phone has 1 unsent change that will also be deleted.',
        ),
      );
    });
  });

  group('scanSignOutQueues', () {
    test('counts every registered send queue, in words', () {
      seedEveryQueue(_a);
      final scan = scanSignOutQueues(QueueRegistry(db), _a);

      // 11 entries; the two Split queues share one label.
      expect(scan.unsent, 11);
      final byLabel = {for (final k in scan.kinds) k.singular: k.count};
      expect(byLabel, {
        'edit': 1,
        'new expense': 1,
        'duplicate decision': 1,
        'queued change': 1,
        'tag change': 1,
        'foreign payment update': 1,
        'statement upload': 1,
        'Split change': 2,
        'SMS update': 1,
        'message waiting to be read': 1,
      });
    });

    test('every registered send queue has plain words for the warning', () {
      final sendQueues = QueueRegistry(
        db,
      ).queues.where((q) => q.kind == QueueKind.outbox).map((q) => q.name);
      expect(signOutQueueLabels.keys, containsAll(sendQueues));
    });

    test('another account, history and applied changes are not counted', () {
      seedEveryQueue(_b);
      run(
        'INSERT INTO sync_pending_changes '
        '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at, in_flight) '
        "VALUES (?, 'transactions', 'x', 'update', '{}', '{}', 1, 2)",
        [_a],
      );
      run(
        'INSERT INTO shared_commands '
        '(namespace, operation_id, context_id, kind, request_json, request_hash, state, created_at) '
        "VALUES (?, 'done', 'c', 'k', '{}', 'h', 'committed', 1)",
        [_a],
      );
      final scan = scanSignOutQueues(QueueRegistry(db), _a);
      expect(scan.unsent, 0, reason: 'applied rows are on the server');
      expect(scan.kinds, isEmpty);
    });

    test('parked rows are lost on sign-out, so they are counted', () {
      run(
        'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at, parked) '
        "VALUES (?, 'x', 't', '{}', 1, 1)",
        [_a],
      );
      final scan = scanSignOutQueues(QueueRegistry(db), _a);
      expect(scan.unsent, 1);
      expect(scan.pending, 0, reason: 'parked says nothing about the network');
    });
  });

  group('accountSignOutProvider', () {
    late _FakeEngine engine;
    late _FakeRepo repo;

    Future<ProviderContainer> build({
      bool online = true,
      bool engineCompletes = true,
    }) async {
      engine = _FakeEngine(completes: engineCompletes);
      repo = _FakeRepo();
      final cache = ResponseCache(db);
      final container = ProviderContainer(
        overrides: [
          cacheNamespaceProvider.overrideWithValue(_a),
          appDatabaseProvider.overrideWith((ref) async => db),
          responseCacheProvider.overrideWith((ref) async => cache),
          isOnlineProvider.overrideWith((ref) => Stream.value(online)),
          syncEngineProvider.overrideWithValue(engine),
          smsV2RuntimeProvider.overrideWith((ref) async => null),
          userCardsRepositoryProvider.overrideWithValue(repo),
          transactionTagsProvider.overrideWith((ref) => null),
        ],
      );
      addTearDown(() {
        container.dispose();
        cache.financialStore.dispose();
      });
      container.listen(isOnlineProvider, (_, _) {});
      await container.read(isOnlineProvider.future);
      return container;
    }

    test('flushOutboxes sends the command outbox too (L-02)', () async {
      final container = await build();
      final signOut = container.read(accountSignOutProvider);
      run(
        'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
        "VALUES (?, 'ignore_transaction', 'txn-9', '{\"id\":\"txn-9\",\"reason\":\"duplicate\"}', 1)",
        [_a],
      );

      await signOut.flushOutboxes();

      expect(repo.ignored, ['txn-9']);
      expect(
        QueueRegistry(db).countsFor('command_outbox', _a).total,
        0,
        reason: 'delivered, so nothing is lost on sign-out',
      );
      expect(engine.calls, 1);
    });

    test('flushOutboxes leaves other accounts alone', () async {
      final container = await build();
      run(
        'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
        "VALUES (?, 'ignore_transaction', 'other', '{\"id\":\"other\",\"reason\":\"duplicate\"}', 1)",
        [_b],
      );
      await container.read(accountSignOutProvider).flushOutboxes();
      expect(repo.ignored, isEmpty);
      expect(QueueRegistry(db).countsFor('command_outbox', _b).total, 1);
    });

    test('report lists every registered queue with its kind', () async {
      final container = await build();
      seedEveryQueue(_a);
      seedEveryQueue(_b);

      final report = await container.read(accountSignOutProvider).report();

      expect(report.unsynced, 11);
      expect(report.pendingKinds.map((k) => k.singular), [
        'edit',
        'new expense',
        'duplicate decision',
        'queued change',
        'tag change',
        'foreign payment update',
        'Split change',
        'statement upload',
        'SMS update',
        'message waiting to be read',
      ]);
    });

    test('changes the server already applied are not reported lost', () async {
      final container = await build();
      run(
        'INSERT INTO sync_pending_changes '
        '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at, in_flight) '
        "VALUES (?, 'transactions', 'x', 'update', '{}', '{}', 1, 2), "
        "(?, 'transactions', 'y', 'update', '{}', '{}', 1, 0)",
        [_a, _a],
      );
      final report = await container.read(accountSignOutProvider).report();
      expect(report.unsynced, 1);
    });

    test('offline with changes waiting says so', () async {
      final container = await build(online: false);
      run(
        'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
        "VALUES (?, 'x', 't1', '{}', 1), (?, 'x', 't2', '{}', 1)",
        [_a, _a],
      );
      run(
        'INSERT INTO sync_pending_changes '
        '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
        "VALUES (?, 'transactions', 'e1', 'update', '{}', '{}', 1)",
        [_a],
      );
      final signOut = container.read(accountSignOutProvider);

      final report = await signOut.prepare();

      expect(report.connection, SignOutConnection.offline);
      expect(report.unsynced, 3);
      expect(report.unsentBecauseNoConnection, isTrue);
      expect(signOutWarningMessage(report), startsWith('Your phone is offline'));
    });

    test('online but the send does not finish: PandaPay unreachable', () async {
      final container = await build(engineCompletes: false);
      run(
        'INSERT INTO sync_pending_changes '
        '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
        "VALUES (?, 'transactions', 'x', 'update', '{}', '{}', 1)",
        [_a],
      );

      final report = await container.read(accountSignOutProvider).prepare();

      expect(report.connection, SignOutConnection.unreachable);
    });

    test('online and everything sent: nothing to warn about', () async {
      final container = await build();
      final report = await container.read(accountSignOutProvider).prepare();
      expect(report.unsynced, 0);
      expect(report.losesSomething, isFalse);
      expect(report.connection, SignOutConnection.ok);
    });

    test('receipts are counted for the signed-in account only', () async {
      final container = await build();
      final mine = TransactionAttachmentsRepository.accountFolderFor(_a);
      final theirs = TransactionAttachmentsRepository.accountFolderFor(_b);
      run(
        'INSERT INTO transaction_attachments VALUES '
        "('1','t1','a.jpg','$mine/t1/1.pprc','image/jpeg',1),"
        "('2','t2','b.jpg','$mine/t2/2.pprc','image/jpeg',2),"
        "('3','t3','c.jpg','$theirs/t3/3.pprc','image/jpeg',3),"
        "('4','t4','d.jpg','/data/app/receipts/$theirs/t4/4.pprc','image/jpeg',4),"
        "('5','t5','e.jpg','/data/app/receipts/$mine/t5/5.pprc','image/jpeg',5)",
      );
      final report = await container.read(accountSignOutProvider).report();
      expect(report.phoneOnlyReceipts, 3);
    });
  });

  group('warning copy', () {
    const kinds = [
      PendingKind(singular: 'new expense', plural: 'new expenses', count: 3),
      PendingKind(
        singular: 'queued change',
        plural: 'queued changes',
        count: 2,
      ),
    ];

    test('offline: plain loss warning that names the kinds', () {
      const report = SignOutReport(
        unsynced: 5,
        phoneOnlyReceipts: 0,
        phoneOnlyReviewItems: 0,
        pendingKinds: kinds,
        connection: SignOutConnection.offline,
      );
      final text = signOutWarningMessage(report);
      expect(text, contains('Your phone is offline'));
      expect(text, contains('5 changes (3 new expenses, 2 queued changes)'));
      expect(text, contains('will all be lost if you sign out now'));
      expect(text, contains('deletes them from this phone for good'));
    });

    test('one change, unreachable server', () {
      const report = SignOutReport(
        unsynced: 1,
        phoneOnlyReceipts: 0,
        phoneOnlyReviewItems: 0,
        pendingKinds: [PendingKind(singular: 'edit', plural: 'edits', count: 1)],
        connection: SignOutConnection.unreachable,
      );
      final text = signOutWarningMessage(report);
      expect(text, startsWith('PandaPay could not be reached'));
      expect(
        text,
        contains('1 change (1 edit) has not been sent and will be lost'),
      );
    });

    test('online: the usual sentence, now with the kinds', () {
      const report = SignOutReport(
        unsynced: 5,
        phoneOnlyReceipts: 1,
        phoneOnlyReviewItems: 0,
        pendingKinds: kinds,
      );
      expect(
        signOutWarningMessage(report),
        "5 changes haven't reached PandaPay yet (3 new expenses, 2 queued changes), "
        'and 1 receipt is stored only on this phone. '
        'Signing out deletes them from this phone.',
      );
    });

    test('a phone with no connection but nothing queued is not a warning', () {
      const report = SignOutReport(
        unsynced: 0,
        phoneOnlyReceipts: 0,
        phoneOnlyReviewItems: 0,
        connection: SignOutConnection.offline,
      );
      expect(report.losesSomething, isFalse);
      expect(report.unsentBecauseNoConnection, isFalse);
      expect(signOutWarningMessage(report), isEmpty);
    });
  });
}
