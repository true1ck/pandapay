import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/queue_registry.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// WP-C3 / L-05 / Q-11: the backup's drain check and restore wipe list come
/// from QueueRegistry, and local-only tables that are not exported are
/// declared. Synthetic data only.
const _ns = 'acct-Q';

void main() {
  late AppDatabase db;

  void run(String sql, [List<Object?> args = const []]) =>
      db.db.execute(sql, args);

  setUp(() {
    db = AppDatabase.forTesting(sqlite.sqlite3.openInMemory());
    // The tables their owners create lazily.
    SmsV2Schema.ensure(db.db);
    ensureForeignPaymentsSchema(db);
    SmsIntakeRepository(db);
    run('''CREATE TABLE IF NOT EXISTS command_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT, namespace TEXT NOT NULL,
      kind TEXT NOT NULL, target TEXT NOT NULL, payload_json TEXT NOT NULL,
      created_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT, next_attempt_at INTEGER NOT NULL DEFAULT 0,
      parked INTEGER NOT NULL DEFAULT 0)''');
    run('''CREATE TABLE IF NOT EXISTS financial_entities (
      namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
      payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
      pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
      occurred_at INTEGER, amount_paise INTEGER,
      PRIMARY KEY(namespace, entity, id))''');
  });
  tearDown(() => db.close());

  LocalPortableSnapshotSource source() =>
      LocalPortableSnapshotSource(appDb: db, namespace: _ns);

  test('every registered send queue is verified, no stale table is', () async {
    final status = await source().drainAndVerifyOutboxes();
    final keys = status.pendingByQueue.keys.toSet();

    final expected = QueueRegistry.defaultQueues
        .where((q) => q.kind == QueueKind.outbox)
        .map((q) => q.name)
        .toSet()
        .difference({'sms_intake', 'split_documents', 'statement_import'});
    expect(keys, containsAll(expected));
    expect(keys, containsAll(<String>['v2_outbox', 'command_outbox']));
    expect(keys, isNot(contains('sms_facts_outbox')));
    expect(keys, isNot(contains('sms_fact_override_outbox')));
    expect(keys, isNot(contains('sms_rule_exposure_outbox')));
    expect(keys, isNot(contains('sms_dismissal_outbox')));
    expect(status.isDrained, isTrue);
  });

  test('unsent SMS uploads and queued commands block the export', () async {
    run(
      "INSERT INTO v2_outbox (namespace, id, kind, payload) VALUES (?, 'k:1', 'k', '{}')",
      [_ns],
    );
    run(
      'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
      "VALUES (?, 'x', 't', '{}', 1)",
      [_ns],
    );
    final status = await source().drainAndVerifyOutboxes();
    expect(status.nonZeroQueues, {'v2_outbox': 1, 'command_outbox': 1});
    expect(status.isDrained, isFalse);
  });

  test('a change the server already applied does not block the export', () async {
    run(
      'INSERT INTO sync_pending_changes '
      '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at, in_flight) '
      "VALUES (?, 'transactions', 'x', 'update', '{}', '{}', 1, 2)",
      [_ns],
    );
    final status = await source().drainAndVerifyOutboxes();
    expect(status.pendingByQueue['sync_pending_changes'], 0);
  });

  test('another account is not counted', () async {
    run(
      'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
      "VALUES ('acct-other', 'x', 't', '{}', 1)",
    );
    expect((await source().drainAndVerifyOutboxes()).isDrained, isTrue);
  });

  test('stored statement import batches still block the export', () async {
    // Same table layout the statement-import gate test uses.
    run('''CREATE TABLE IF NOT EXISTS statement_import_batches (
      namespace TEXT NOT NULL, session_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
      ciphertext BLOB)''');
    run(
      'INSERT INTO statement_import_batches (namespace, session_id, ordinal, ciphertext) '
      "VALUES (?, 's', 1, ?)",
      [_ns, Uint8List.fromList([1])],
    );
    final status = await source().drainAndVerifyOutboxes();
    expect(status.pendingByQueue['statement_import_batches'], 1);
  });

  test('local-only tables that are not exported are declared with a reason', () {
    const tables = [
      'bill_card_assignments',
      'manual_bank_balances',
      'local_past_bill_receipts',
      'user_merchant_category_rules',
      'command_outbox',
    ];
    for (final table in tables) {
      final line = LocalPortableSnapshotSource.declaredExclusions.where(
        (e) => e.startsWith('$table ('),
      );
      expect(line, hasLength(1), reason: '$table must be declared once');
      expect(
        line.single.length,
        greaterThan(table.length + 20),
        reason: '$table needs a reason, not just a name',
      );
    }
  });

  test('the restore wipe list names only registered queues', () {
    final registered = QueueRegistry.defaultQueues.map((q) => q.name).toSet();
    expect(
      LocalPortableRestoreWriter.restoreWipedQueues,
      everyElement(isIn(registered)),
    );
    // Unsent work in queues a restore never wiped is still not wiped.
    expect(
      LocalPortableRestoreWriter.restoreWipedQueues,
      isNot(contains('command_outbox')),
    );
    expect(
      LocalPortableRestoreWriter.restoreWipedQueues,
      isNot(contains('v2_outbox')),
    );
  });

  test('restoring into a fresh namespace keeps unsent commands and uploads', () async {
    run(
      'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
      "VALUES (?, 'x', 't', '{}', 1)",
      [_ns],
    );
    run(
      "INSERT INTO v2_outbox (namespace, id, kind, payload) VALUES (?, 'k:1', 'k', '{}')",
      [_ns],
    );
    run(
      'INSERT INTO sync_pending_changes '
      '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
      "VALUES (?, 'transactions', 'x', 'update', '{}', '{}', 1)",
      [_ns],
    );
    final writer = LocalPortableRestoreWriter(
      appDb: db,
      namespace: _ns,
      receipts: _NoReceipts(),
    );
    await writer.beginFreshNamespace();
    await writer.commit();

    int count(String table) =>
        db.db.select('SELECT COUNT(*) AS n FROM $table').single['n'] as int;
    expect(count('command_outbox'), 1);
    expect(count('v2_outbox'), 1);
    expect(count('sync_pending_changes'), 0, reason: 'wiped, as before');
  });
}

final class _NoReceipts implements PortableReceiptVault {
  @override
  Future<Uint8List> readPlaintext(PortableAttachmentSource source) =>
      throw UnimplementedError();

  @override
  Future<String> storeEncrypted({
    required String attachmentId,
    required String transactionId,
    required File plaintext,
  }) => throw UnimplementedError();
}
