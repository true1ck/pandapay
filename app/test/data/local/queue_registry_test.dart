import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/queue_registry.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/statement_import_outbox.dart';
import 'package:pandapay/data/secure_storage/statement_import_batch_cipher.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:sqlite3/sqlite3.dart';

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

void main() {
  late AppDatabase db;
  late QueueRegistry registry;
  setUp(() {
    db = openInMemoryForTesting();
    registry = QueueRegistry(db);
  });
  tearDown(() => db.close());

  /// Creates the tables that their owners create lazily, through the owners.
  void createLazyTables() {
    SmsV2Schema.ensure(db.db);
    ensureForeignPaymentsSchema(db);
    SmsIntakeRepository(db);
    StatementImportOutbox(db.db, namespace: _a, cipher: _NoCipher());
    db.db.execute('''CREATE TABLE IF NOT EXISTS split_documents (
      namespace TEXT NOT NULL, transaction_id TEXT NOT NULL,
      document_json TEXT NOT NULL, pending INTEGER NOT NULL DEFAULT 0,
      version INTEGER NOT NULL DEFAULT 0, fetched_at INTEGER NOT NULL,
      error TEXT, blocked INTEGER NOT NULL DEFAULT 0,
      attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(namespace, transaction_id))''');
  }

  test('registers every queue of the storage audit, once each', () {
    final names = registry.queues.map((q) => q.name).toList();
    expect(names, hasLength(names.toSet().length));
    expect(
      names,
      containsAll(const [
        'sync_pending_changes',
        'transaction_outbox_entries',
        'duplicate_resolution_outbox',
        'command_outbox',
        'transaction_tag_outbox',
        'foreign_payments_outbox',
        'statement_import',
        'shared_commands',
        'split_documents',
        'v2_outbox',
        'sms_intake',
        'sms_captured_messages',
      ]),
    );
    expect(registry.allTables, containsAll(const [
      'statement_import_sessions',
      'statement_import_batches',
      'shared_commands',
      'v2_outbox',
    ]));
  });

  test('a duplicate queue name is refused', () {
    expect(
      () => QueueRegistry(
        db,
        queues: const [
          QueueSpec(name: 'x', table: 'a'),
          QueueSpec(name: 'x', table: 'b'),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('tables that do not exist yet count as 0, never throw', () {
    // A fresh database has no lazily created tables at all.
    final counts = registry.countAll(_a);
    expect(counts.keys, registry.queues.map((q) => q.name));
    expect(counts['statement_import'], QueueCounts.zero);
    expect(counts['split_documents'], QueueCounts.zero);
    expect(registry.hasUnsent(_a), isFalse);
    expect(registry.unsent(_a).total, 0);
  });

  test('a missing parked column counts rows as pending, not 0', () {
    final raw = sqlite3.openInMemory();
    addTearDown(raw.dispose);
    raw.execute(
      'CREATE TABLE tq (namespace TEXT NOT NULL, id INTEGER PRIMARY KEY)',
    );
    raw.execute("INSERT INTO tq(namespace) VALUES ('a'), ('a'), ('b')");
    final scoped = QueueRegistry(
      AppDatabase.forTesting(raw),
      queues: const [
        QueueSpec(
          name: 'tq',
          table: 'tq',
          parkedWhere: 'parked = 1',
          parkedColumns: {'parked'},
        ),
      ],
    );
    expect(scoped.countsFor('tq', 'a'), const QueueCounts(pending: 2));
    raw.execute('ALTER TABLE tq ADD COLUMN parked INTEGER NOT NULL DEFAULT 0');
    raw.execute("UPDATE tq SET parked = 1 WHERE id = 1");
    expect(
      scoped.countsFor('tq', 'a'),
      const QueueCounts(pending: 1, parked: 1),
    );
  });

  test('an unknown queue name is an error, not an empty count', () {
    expect(() => registry.countsFor('nope', _a), throwsArgumentError);
    expect(() => registry.attachFlush('nope', () async => 0), throwsArgumentError);
  });

  group('counts per queue and account', () {
    setUp(createLazyTables);

    test('sync_pending_changes: attempts >= 5 is parked', () {
      for (final attempts in [0, 2, 5]) {
        db.db.execute(
          'INSERT INTO sync_pending_changes '
          '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at, attempts) '
          "VALUES (?, 'transactions', ?, 'update', '{}', '{}', 1, ?)",
          [_a, 'e$attempts', attempts],
        );
      }
      db.db.execute(
        'INSERT INTO sync_pending_changes '
        '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
        "VALUES (?, 'transactions', 'other', 'update', '{}', '{}', 1)",
        [_b],
      );
      expect(
        registry.countsFor('sync_pending_changes', _a),
        const QueueCounts(pending: 2, parked: 1),
      );
      expect(
        registry.countsFor('sync_pending_changes', _b),
        const QueueCounts(pending: 1),
      );
    });

    test('transaction_outbox_entries: parked column and backoff', () {
      db.db.execute(
        'INSERT INTO transaction_outbox_entries '
        '(namespace, client_mutation_id, amount_paise, created_at, parked, next_attempt_at) '
        "VALUES (?, 'due', 1, 1, 0, 0), (?, 'backoff', 1, 1, 0, 99999999999999), (?, 'parked', 1, 1, 1, 0)",
        [_a, _a, _a],
      );
      expect(
        registry.countsFor('transaction_outbox_entries', _a),
        const QueueCounts(pending: 2, parked: 1),
      );
    });

    test('duplicate_resolution_outbox and command_outbox', () {
      db.db.execute(
        'INSERT INTO duplicate_resolution_outbox '
        '(namespace, candidate_id, resolution, created_at, attempts) '
        "VALUES (?, 'p1', 'kept_both', 1, 0), (?, 'p2', 'kept_both', 1, 5)",
        [_a, _a],
      );
      db.db.execute(
        'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at, parked) '
        "VALUES (?, 'ignore', 't1', '{}', 1, 0), (?, 'ignore', 't2', '{}', 1, 1), (?, 'ignore', 't3', '{}', 1, 1)",
        [_a, _a, _a],
      );
      expect(
        registry.countsFor('duplicate_resolution_outbox', _a),
        const QueueCounts(pending: 1, parked: 1),
      );
      expect(
        registry.countsFor('command_outbox', _a),
        const QueueCounts(pending: 1, parked: 2),
      );
    });

    test('transaction_tag_outbox and foreign_payments_outbox', () {
      db.db.execute(
        'INSERT INTO transaction_tag_outbox (namespace, mutation_id, payload_json) '
        "VALUES (?, 'm1', '{}'), (?, 'm2', '{}')",
        [_a, _b],
      );
      db.db.execute(
        'INSERT INTO foreign_payments_outbox (namespace, source_key, kind, payload) '
        "VALUES (?, 's1', 'k', '{}')",
        [_a],
      );
      expect(
        registry.countsFor('transaction_tag_outbox', _a),
        const QueueCounts(pending: 1),
      );
      expect(
        registry.countsFor('foreign_payments_outbox', _a),
        const QueueCounts(pending: 1),
      );
    });

    test('shared_commands: committed is history, awaitingAuth blocks', () {
      const states = [
        'pending',
        'retry',
        'sending',
        'awaitingAuth',
        'rejected',
        'conflict',
        'committed',
      ];
      for (final state in states) {
        db.db.execute(
          'INSERT INTO shared_commands '
          '(namespace, operation_id, context_id, kind, request_json, request_hash, state, created_at) '
          "VALUES (?, ?, 'c', 'k', '{}', 'h', ?, 1)",
          [_a, 'op-$state', state],
        );
      }
      expect(
        registry.countsFor('shared_commands', _a),
        const QueueCounts(pending: 3, parked: 2, blocked: 1),
      );
    });

    test('split_documents: only pending=1 counts, blocked is parked', () {
      db.db.execute(
        'INSERT INTO split_documents (namespace, transaction_id, document_json, pending, blocked, fetched_at) '
        "VALUES (?, 't1', '{}', 1, 0, 1), (?, 't2', '{}', 1, 1, 1), (?, 't3', '{}', 0, 0, 1)",
        [_a, _a, _a],
      );
      expect(
        registry.countsFor('split_documents', _a),
        const QueueCounts(pending: 1, parked: 1),
      );
    });

    test('v2_outbox, sms_intake and sms_captured_messages', () {
      db.db.execute(
        "INSERT INTO v2_outbox (namespace, id, kind, payload) VALUES (?, 'k:1', 'k', '{}'), (?, 'k:2', 'k', '{}')",
        [_a, _a],
      );
      db.db.execute(
        "INSERT INTO sms_intake (namespace, id, sender, body, received_at) VALUES (?, 'i1', 'S', 'b', 1)",
        [_a],
      );
      db.db.execute(
        "INSERT INTO sms_captured_messages (namespace, id, sender, body, received_at) VALUES (?, 'c1', 'S', 'b', 1)",
        [_a],
      );
      expect(registry.countsFor('v2_outbox', _a).pending, 2);
      expect(registry.countsFor('sms_intake', _a).pending, 1);
      expect(registry.countsFor('sms_captured_messages', _a).pending, 1);
      // Captured history is local-only data, not an unsent queue.
      expect(registry.localOnly(_a).total, 1);
      expect(registry.unsent(_a).total, 3);
    });

    test('statement_import: stored batches of open sessions', () {
      db.db.execute(
        'INSERT INTO statement_import_sessions '
        '(namespace, session_id, plan_hash, batch_count, state, created_at_ms, updated_at_ms, expires_at_ms) '
        "VALUES (?, 's-open', ?, 2, 'pending', 1, 1, 9), (?, 's-review', ?, 1, 'needs_review', 1, 1, 9), (?, 's-done', ?, 1, 'complete', 1, 1, 9)",
        [_a, 'a' * 64, _a, 'b' * 64, _a, 'c' * 64],
      );
      var n = 0;
      void batch(String session, {required bool stored}) {
        n++;
        db.db.execute(
          'INSERT INTO statement_import_batches '
          '(namespace, session_id, ordinal, import_key, payload_hash, payload_bytes, ciphertext, completed_summary, completed_at_ms) '
          'VALUES (?, ?, ?, ?, ?, 10, ?, ?, ?)',
          [
            _a,
            session,
            n,
            '${n.toString().padLeft(2, '0')}${'k' * 62}',
            'h' * 64,
            stored ? Uint8List.fromList([1, 2, 3]) : null,
            stored ? null : '{}',
            stored ? null : 1,
          ],
        );
      }

      batch('s-open', stored: true);
      batch('s-open', stored: false); // already uploaded
      batch('s-review', stored: true);
      batch('s-done', stored: false);
      expect(
        registry.countsFor('statement_import', _a),
        const QueueCounts(pending: 1, parked: 1),
      );
      expect(registry.countsFor('statement_import', _b), QueueCounts.zero);
    });

    test('unsent sums send queues only, across accounts separately', () {
      db.db.execute(
        'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
        "VALUES (?, 'ignore', 't1', '{}', 1), (?, 'ignore', 't2', '{}', 1)",
        [_a, _b],
      );
      db.db.execute(
        'INSERT INTO transaction_outbox_entries (namespace, client_mutation_id, amount_paise, created_at, parked) '
        "VALUES (?, 'm', 1, 1, 1)",
        [_a],
      );
      expect(registry.unsent(_a), const QueueCounts(pending: 1, parked: 1));
      expect(registry.unsent(_b), const QueueCounts(pending: 1));
      expect(registry.hasUnsent(_a), isTrue);
      expect(registry.hasUnsent('user:nobody'), isFalse);
    });
  });

  group('flush callbacks', () {
    test('flushAll runs attached flushers in order and survives a failure',
        () async {
      final order = <String>[];
      registry.attachFlush('sync_pending_changes', () async {
        order.add('sync');
        return 3;
      });
      registry.attachFlush('command_outbox', () async {
        order.add('commands');
        throw StateError('server down');
      });
      registry.attachFlush('v2_outbox', () async {
        order.add('v2');
        return 1;
      });
      final report = await registry.flushAll();
      expect(order, ['sync', 'commands', 'v2']);
      expect(report.delivered, {'sync_pending_changes': 3, 'v2_outbox': 1});
      expect(report.failures.keys, ['command_outbox']);
      expect(report.totalDelivered, 4);
      expect(registry.hasFlush('command_outbox'), isTrue);
      expect(registry.hasFlush('shared_commands'), isFalse);
    });

    test('flushAll(only:) limits which queues run', () async {
      final order = <String>[];
      registry.attachFlush('sync_pending_changes', () async {
        order.add('sync');
        return 0;
      });
      registry.attachFlush('v2_outbox', () async {
        order.add('v2');
        return 0;
      });
      await registry.flushAll(only: ['v2_outbox']);
      expect(order, ['v2']);
    });
  });
}
