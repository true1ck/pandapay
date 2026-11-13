import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const namespace = 'acct-R';

AppDatabase freshTargetDatabase() {
  final db = AppDatabase.forTesting(sqlite.sqlite3.openInMemory());
  db.db.execute('''
    CREATE TABLE financial_entities (
      namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
      payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
      pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
      occurred_at INTEGER, amount_paise INTEGER,
      PRIMARY KEY(namespace, entity, id)
    );
    CREATE TABLE IF NOT EXISTS local_commitments (
      namespace TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
      PRIMARY KEY(namespace, id)
    );
  ''');
  return db;
}

AppDatabase seededDatabase() {
  final db = AppDatabase.forTesting(sqlite.sqlite3.openInMemory());
  db.db.execute('''
    CREATE TABLE financial_entities (
      namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
      payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
      pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
      occurred_at INTEGER, amount_paise INTEGER,
      PRIMARY KEY(namespace, entity, id)
    );
    CREATE TABLE IF NOT EXISTS local_commitments (
      namespace TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
      PRIMARY KEY(namespace, id)
    );
  ''');
  void entity(
    String entity,
    String id,
    Map<String, Object?> payload, {
    int pending = 0,
  }) => db.db.execute(
    'INSERT INTO financial_entities(namespace,entity,id,payload,observed_at,pending) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [namespace, entity, id, jsonEncode(payload), 1700000000000, pending],
  );
  entity('transactions', 'txn-1', {
    'note': 'Swiggy',
    'amount_inr': '249.00',
    'occurred_at': '2023-11-01T10:00:00.000Z',
  });
  entity('cards', 'card-1', {'bank': 'HDFC', 'last4': '1234'});
  entity('sms_observations', 'obs-1', {'sender': 'HDFCBK', 'amount': 249});
  db.db.execute(
    'INSERT INTO local_user_cards(id, card_product_id, nickname, last4, is_default, '
    'is_archived, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    [
      'luc-1',
      'card_product-1',
      'Daily driver',
      '5678',
      1,
      0,
      1.5,
      1700000000000,
    ],
  );
  db.db.execute(
    'INSERT INTO user_categories(namespace,id,name,slug,match_terms_json,created_at,updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?)',
    [
      namespace,
      'lc-1',
      'Groceries',
      'groceries',
      '["big","basket"]',
      1700000000000,
      1700000000000,
    ],
  );
  db.db.execute(
    'INSERT INTO transaction_tags(namespace,id,name,normalized_name,updated_at) '
    'VALUES (?, ?, ?, ?, ?)',
    [namespace, 'tag-1', 'Vacation', 'vacation', '2026-01-01T00:00:00.000Z'],
  );
  db.db.execute(
    'INSERT INTO transaction_tag_links(namespace,transaction_id,tag_id,updated_at) '
    'VALUES (?, ?, ?, ?)',
    [namespace, 'txn-1', 'tag-1', '2026-01-01T00:00:00.000Z'],
  );
  db.db.execute(
    'INSERT INTO local_commitments(namespace,id,payload) VALUES (?, ?, ?)',
    [
      namespace,
      'cm-1',
      jsonEncode({'card': 'card-1', 'due_day': 5}),
    ],
  );
  db.db.execute(
    'INSERT INTO local_needs_review(namespace,id,payload) VALUES (?, ?, ?)',
    [
      namespace,
      'nr-1',
      jsonEncode({'reason': 'amount_mismatch'}),
    ],
  );
  db.db.execute(
    'INSERT INTO transaction_attachments(id, transaction_id, file_name, local_path, mime_type, '
    'created_at) VALUES (?, ?, ?, ?, ?, ?)',
    [
      'att-1',
      'txn-1',
      'receipt.png',
      'docs/att-1.png',
      'image/png',
      1700000000000,
    ],
  );
  return db;
}

Future<Map<String, File>> runCapture(AppDatabase db, Directory staging) =>
    LocalPortableSnapshotSource(
      appDb: db,
      namespace: namespace,
    ).capturePortableSections(stagingDirectory: staging);
/// Paths use the platform separator; compare them with `/` so the tests agree on Windows.
String _slash(String p) => p.replaceAll(r'\', '/');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory stagingA;
  late Directory stagingB;
  late Directory attachmentsDir;

  setUp(() async {
    stagingA = await Directory.systemTemp.createTemp('restore-src-');
    stagingB = await Directory.systemTemp.createTemp('restore-dst-');
    attachmentsDir = await Directory.systemTemp.createTemp('restore-att-');
  });

  tearDown(() async {
    for (final dir in [stagingA, stagingB, attachmentsDir]) {
      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  });

  test('restore replays a captured snapshot byte-identically', () async {
    final sourceDb = seededDatabase();
    final sections = await runCapture(sourceDb, stagingA);

    final targetDb = freshTargetDatabase();
    final writer = LocalPortableRestoreWriter(
      appDb: targetDb,
      namespace: namespace,
      receipts: _FakeReceiptStore(attachmentsDir),
    );
    await writer.beginFreshNamespace();
    for (final entry in sections.entries) {
      final file = entry.value;
      final rows = utf8
          .decode(file.readAsBytesSync())
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map<String, dynamic>);
      if (entry.key.contains('sms')) {
        await writer.insertHistoricalSmsRows(
          entry.key,
          Stream.fromIterable(rows),
        );
      } else {
        await writer.insertPortableRows(entry.key, Stream.fromIterable(rows));
      }
    }
    await writer.rebuildDeclaredProjections();
    await writer.commit();

    final recaptured = await runCapture(targetDb, stagingB);
    expect(recaptured.keys, sections.keys);
    for (final name in sections.keys) {
      expect(
        recaptured[name]!.readAsBytesSync(),
        sections[name]!.readAsBytesSync(),
        reason: 'section $name must round-trip byte-identically',
      );
    }
  });

  test('restored transaction projections match a live import', () async {
    final sourceDb = seededDatabase();
    final sections = await runCapture(sourceDb, stagingA);

    final targetDb = freshTargetDatabase();
    final writer = LocalPortableRestoreWriter(
      appDb: targetDb,
      namespace: namespace,
      receipts: _FakeReceiptStore(attachmentsDir),
    );
    await writer.beginFreshNamespace();
    final rows = utf8
        .decode(sections['transactions']!.readAsBytesSync())
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>);
    await writer.insertPortableRows('transactions', Stream.fromIterable(rows));
    await writer.rebuildDeclaredProjections();
    await writer.commit();

    final restored = targetDb.db.select(
      'SELECT id, occurred_at, amount_paise FROM financial_entities WHERE entity = ? ORDER BY id',
      ['transactions'],
    ).single;
    expect(restored['id'], 'txn-1');
    expect(restored['amount_paise'], 24900);
    expect(
      restored['occurred_at'],
      DateTime.parse('2023-11-01T10:00:00.000Z').millisecondsSinceEpoch,
    );
  });

  test('restore wipes the target namespace before replay', () async {
    final targetDb = freshTargetDatabase();
    final writer = LocalPortableRestoreWriter(
      appDb: targetDb,
      namespace: namespace,
      receipts: _FakeReceiptStore(attachmentsDir),
    );
    targetDb.db.execute(
      'INSERT INTO transaction_attachments(id, transaction_id, file_name, local_path, mime_type, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?)',
      ['stale', 'txn-old', 'old.png', 'docs/old.png', 'image/png', 1],
    );
    await writer.beginFreshNamespace();
    await writer.commit();
    expect(
      targetDb.db
          .select('SELECT COUNT(*) AS c FROM transaction_attachments')
          .first['c'],
      0,
    );
  });

  test('rollback discards partial restore', () async {
    final sourceDb = seededDatabase();
    final sections = await runCapture(sourceDb, stagingA);
    final targetDb = freshTargetDatabase();
    final writer = LocalPortableRestoreWriter(
      appDb: targetDb,
      namespace: namespace,
      receipts: _FakeReceiptStore(attachmentsDir),
    );
    await writer.beginFreshNamespace();
    final rows = utf8
        .decode(sections['transactions']!.readAsBytesSync())
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>);
    await writer.insertPortableRows('transactions', Stream.fromIterable(rows));
    await writer.rollback();
    expect(
      targetDb.db
          .select('SELECT COUNT(*) AS c FROM financial_entities')
          .first['c'],
      0,
    );
  });

  test(
    'installAttachment re-encrypts through the receipt store and records its path',
    () async {
      final targetDb = freshTargetDatabase();
      final receipts = _FakeReceiptStore(attachmentsDir);
      final writer = LocalPortableRestoreWriter(
        appDb: targetDb,
        namespace: namespace,
        receipts: receipts,
      );
      final staged = File('${stagingA.path}/staged.bin')
        ..writeAsBytesSync([1, 2, 3, 4]);
      await writer.beginFreshNamespace();
      await writer.installAttachment(metadata: _attachment, stagedFile: staged);
      await writer.commit();

      final call = receipts.stored.single;
      expect(call.id, 'att-9');
      expect(call.transactionId, 'txn-1');
      expect(call.bytes, [1, 2, 3, 4]);
      final row = targetDb.db
          .select(
            'SELECT transaction_id, file_name, local_path FROM transaction_attachments',
          )
          .single;
      expect(row['transaction_id'], 'txn-1');
      expect(row['file_name'], 'receipt.png');
      expect(_slash(row['local_path'] as String), _slash('${attachmentsDir.path}/att-9.pprc'));
      expect(
        attachmentsDir.listSync().map((e) => _slash(e.path)),
        [_slash('${attachmentsDir.path}/att-9.pprc')],
        reason: 'no plaintext copy next to the encrypted receipt',
      );
    },
  );

  test('a rolled-back restore removes the receipts it encrypted', () async {
    final targetDb = freshTargetDatabase();
    final writer = LocalPortableRestoreWriter(
      appDb: targetDb,
      namespace: namespace,
      receipts: _FakeReceiptStore(attachmentsDir),
    );
    final staged = File('${stagingA.path}/staged.bin')
      ..writeAsBytesSync([1, 2, 3, 4]);
    await writer.beginFreshNamespace();
    await writer.installAttachment(metadata: _attachment, stagedFile: staged);
    await writer.rollback();

    expect(attachmentsDir.listSync(), isEmpty);
    expect(
      targetDb.db
          .select('SELECT COUNT(*) AS c FROM transaction_attachments')
          .first['c'],
      0,
    );
  });

  test('a receipt store failure leaves no row behind', () async {
    final targetDb = freshTargetDatabase();
    final writer = LocalPortableRestoreWriter(
      appDb: targetDb,
      namespace: namespace,
      receipts: _FakeReceiptStore(attachmentsDir, fail: true),
    );
    final staged = File('${stagingA.path}/staged.bin')
      ..writeAsBytesSync([1, 2, 3, 4]);
    await writer.beginFreshNamespace();
    await expectLater(
      writer.installAttachment(metadata: _attachment, stagedFile: staged),
      throwsA(isA<StateError>()),
    );
    await writer.rollback();
    expect(
      targetDb.db
          .select('SELECT COUNT(*) AS c FROM transaction_attachments')
          .first['c'],
      0,
    );
  });

  test('unknown section names are rejected', () async {
    final targetDb = freshTargetDatabase();
    final writer = LocalPortableRestoreWriter(
      appDb: targetDb,
      namespace: namespace,
      receipts: _FakeReceiptStore(attachmentsDir),
    );
    await writer.beginFreshNamespace();
    await expectLater(
      writer.insertPortableRows(
        'cached_responses',
        Stream.fromIterable(const []),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

const _attachment = PortableBackupAttachment(
  id: 'att-9',
  path: 'attachments/att-9.bin',
  transactionId: 'txn-1',
  fileName: 'receipt.png',
  mimeType: 'image/png',
  byteLength: 4,
  sha256: '0000000000000000000000000000000000000000000000000000000000000000',
);

/// Stands in for the per-account encrypted receipt store: "encrypts" by
/// prefixing the PPRC magic, so tests can tell stored files from plaintext.
final class _FakeReceiptStore implements PortableReceiptVault {
  _FakeReceiptStore(this.directory, {this.fail = false});
  final Directory directory;
  final bool fail;
  final stored = <({String id, String transactionId, List<int> bytes})>[];

  @override
  Future<Uint8List> readPlaintext(PortableAttachmentSource source) async =>
      throw UnimplementedError();

  @override
  Future<String> storeEncrypted({
    required String attachmentId,
    required String transactionId,
    required File plaintext,
  }) async {
    if (fail) throw StateError('receipt key locked');
    final bytes = await plaintext.readAsBytes();
    stored.add((id: attachmentId, transactionId: transactionId, bytes: bytes));
    final file = File('${directory.path}/$attachmentId.pprc');
    await file.writeAsBytes([0x50, 0x50, 0x52, 0x43, ...bytes]);
    return file.path;
  }
}
