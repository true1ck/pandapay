import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const namespace = 'acct-E';

AppDatabase _db() {
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

void _seed(AppDatabase db, String sourceLocalPath) {
  db.db.execute(
    'INSERT INTO financial_entities(namespace,entity,id,payload,observed_at,pending) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [
      namespace,
      'transactions',
      'txn-1',
      jsonEncode({
        'note': 'Swiggy',
        'amount_inr': '249.00',
        'occurred_at': '2023-11-01T10:00:00.000Z',
      }),
      1700000000000,
      0,
    ],
  );
  db.db.execute(
    'INSERT INTO financial_entities(namespace,entity,id,payload,observed_at,pending) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [
      namespace,
      'cards',
      'card-1',
      jsonEncode({'bank': 'HDFC'}),
      1700000000000,
      0,
    ],
  );
  db.db.execute(
    'INSERT INTO local_commitments(namespace,id,payload) VALUES (?, ?, ?)',
    [
      namespace,
      'cm-1',
      jsonEncode({'card': 'card-1'}),
    ],
  );
  db.db.execute(
    'INSERT INTO transaction_attachments(id, transaction_id, file_name, local_path, mime_type, '
    'created_at) VALUES (?, ?, ?, ?, ?, ?)',
    [
      'att-1',
      'txn-1',
      'receipt.png',
      '$sourceLocalPath/att-1.png',
      'image/png',
      1700000000000,
    ],
  );
}

String _sha256(File file) => sha256.convert(file.readAsBytesSync()).toString();

void main() {
  late Directory stagingA;
  late Directory stagingB;
  late Directory attachmentsDir;
  late Directory attachmentsSourceDir;

  setUp(() async {
    stagingA = Directory.systemTemp.createTempSync('e2e-src-');
    stagingB = Directory.systemTemp.createTempSync('e2e-dst-');
    attachmentsDir = Directory.systemTemp.createTempSync('e2e-att-');
    attachmentsSourceDir = Directory.systemTemp.createTempSync('e2e-att-src-');
  });

  tearDown(() async {
    for (final dir in [
      stagingA,
      stagingB,
      attachmentsDir,
      attachmentsSourceDir,
    ]) {
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

  test(
    'source -> archive -> stage -> finalize -> recapture is byte-identical',
    () async {
      final sourceDb = _db();
      _seed(sourceDb, attachmentsSourceDir.path);
      final sourceBytes = File('${attachmentsSourceDir.path}/att-1.png')
        ..writeAsBytesSync(List<int>.generate(64, (i) => i));

      final source = LocalPortableSnapshotSource(
        appDb: sourceDb,
        namespace: namespace,
      );
      final sections = await source.capturePortableSections(
        stagingDirectory: stagingA,
      );
      final attachments = await source.listPortableAttachments();
      expect(attachments.single.id, 'att-1');

      final collector = PortableAttachmentCollector();
      final collected = await collector.collect(
        sources: attachments,
        stagingDirectory: stagingA,
      );
      final attachmentId = collected.single.metadata.id;
      expect(collected.single.metadata.sha256, _sha256(sourceBytes));

      final manifest = PortableBackupManifest(
        formatVersion: 1,
        schemaVersion: 'v1',
        backupId: 'e2e-backup',
        accountBinding: namespace,
        createdAt: DateTime.utc(2026),
        snapshotAt: DateTime.utc(2026),
        appVersion: 'test',
        serverVersion: 'test',
        complete: true,
        serverRevision: null,
        sections: [
          for (final entry in sections.entries)
            PortableBackupSection(
              name: entry.key,
              path: 'sections/${entry.key}.ndjson',
              recordCount: utf8
                  .decode(entry.value.readAsBytesSync())
                  .trim()
                  .split('\n')
                  .length,
              byteLength: entry.value.lengthSync(),
              sha256: _sha256(entry.value),
            ),
        ],
        attachments: [collected.single.metadata],
        requiredCapabilities: const [],
        declaredExclusions: const [],
      );

      final archive = File('${stagingA.path}/backup.pandapay-backup');
      await PortableArchiveWriter(
        encryptor: const Argon2idSecretStreamEncryptor(),
      ).write(
        manifest: manifest,
        sectionFiles: sections,
        attachments: collected,
        output: archive,
        passphrase: 'correct-horse',
        stagingDirectory: stagingA,
      );
      expect(await archive.exists(), isTrue);

      // Restore side: fresh target database.
      final targetDb = _db();
      final writer = LocalPortableRestoreWriter(
        appDb: targetDb,
        namespace: namespace,
        attachmentsDirectory: attachmentsDir,
      );
      final inspector = PortableRestoreInspector();
      final staged = await inspector.inspectAndStage(
        backupFile: archive,
        passphrase: 'correct-horse',
        stagingDirectory: stagingB,
        expectedAccountBinding: namespace,
      );
      expect(staged.sectionFiles.containsKey('transactions'), isTrue);

      final finalizer = PortableLocalRestoreFinalizer(
        writer: writer,
        target: LocalPortableRestoreTargetInspector(
          appDb: targetDb,
          namespace: namespace,
        ),
      );
      final result = await finalizer.finalize(
        staged: staged,
        serverCommit: const PortableRestoreServerCommit(
          serverRevision: 'e2e-rev',
          committed: true,
        ),
      );
      expect(result.sectionRows, greaterThan(0));
      expect(result.attachments, 1);
      await staged.cleanup();

      // The restored device recaptures an identical snapshot.
      final restoredSource = LocalPortableSnapshotSource(
        appDb: targetDb,
        namespace: namespace,
      );
      final recaptured = await restoredSource.capturePortableSections(
        stagingDirectory: stagingB,
      );
      expect(recaptured.keys, sections.keys);
      for (final name in sections.keys) {
        expect(
          sections[name]!.readAsBytesSync(),
          recaptured[name]!.readAsBytesSync(),
          reason: 'section $name must survive the archive round trip',
        );
      }

      final sourceFile = File('${attachmentsSourceDir.path}/att-1.png');
      final restoredAttachment = File('${attachmentsDir.path}/$attachmentId');
      expect(await restoredAttachment.exists(), isTrue);
      expect(
        await restoredAttachment.readAsBytes(),
        sourceFile.readAsBytesSync(),
      );

      final restoredMeta = targetDb.db
          .select(
            'SELECT transaction_id, file_name, local_path FROM transaction_attachments',
          )
          .single;
      expect(restoredMeta['transaction_id'], 'txn-1');
      expect(restoredMeta['file_name'], 'receipt.png');
      expect(restoredMeta['local_path'], attachmentId);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('populated target refuses staging', () async {
    final targetDb = _db();
    final writer = LocalPortableRestoreTargetInspector(
      appDb: targetDb,
      namespace: namespace,
    );
    final state = await writer.inspectFreshNamespace();
    expect(state.isFresh, isTrue);

    _seed(targetDb, '');
    final occupied = await writer.inspectFreshNamespace();
    expect(occupied.isFresh, isFalse);
    await expectLater(
      requireFreshPortableNamespace(writer),
      throwsA(isA<PortablePopulatedTargetException>()),
    );
  });
}
