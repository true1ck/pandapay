import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/transaction_attachments_repository.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';
import 'package:pandapay/data/portable_backup/private_temporary_workspace.dart';
import 'package:pandapay/data/secure_storage/encrypted_receipt_file.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';
import 'package:pandapay/data/secure_storage/local_key_provisioning_lease.dart';
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

void _seed(AppDatabase db, {String? attachmentLocalPath}) {
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
  if (attachmentLocalPath == null) return;
  db.db.execute(
    'INSERT INTO transaction_attachments(id, transaction_id, file_name, local_path, mime_type, '
    'created_at) VALUES (?, ?, ?, ?, ?, ?)',
    [
      'att-1',
      'txn-1',
      'receipt.png',
      attachmentLocalPath,
      'image/png',
      1700000000000,
    ],
  );
}

/// The real per-account encrypted receipt store on one simulated phone.
TransactionAttachmentsRepository _receipts(
  AppDatabase db,
  Directory phone, {
  required String installId,
  required _MemoryKeyStore keys,
}) => TransactionAttachmentsRepository(
  db,
  namespace: namespace,
  installId: () async => installId,
  receiptsDirectory: () async => Directory('${phone.path}/receipts'),
  workspace: () =>
      PrivateTemporaryWorkspace.create(Directory('${phone.path}/tmp')),
  keyStore: keys,
  lease: _InlineLease(),
);

bool _isPprc(List<int> bytes) =>
    bytes.length > EncryptedReceiptFileCodec.headerLength &&
    _containsRun(bytes.sublist(0, 4), EncryptedReceiptFileCodec.magic);

bool _containsRun(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length && match; j++) {
      match = haystack[i + j] == needle[j];
    }
    if (match) return true;
  }
  return false;
}

/// Synthetic receipt bytes with a recognisable plaintext run.
final _receipt = Uint8List.fromList(
  List<int>.generate(4096, (i) => 65 + i % 26),
);
final _plainRun = utf8.encode('ABCDEFGHIJKLMNOPQRSTUVWXYZ');

String _sha256(File file) => sha256.convert(file.readAsBytesSync()).toString();

void main() {
  late Directory stagingA;
  late Directory stagingB;
  late Directory sourcePhone;
  late Directory targetPhone;

  setUp(() async {
    stagingA = Directory.systemTemp.createTempSync('e2e-src-');
    stagingB = Directory.systemTemp.createTempSync('e2e-dst-');
    sourcePhone = Directory.systemTemp.createTempSync('e2e-phone-a-');
    targetPhone = Directory.systemTemp.createTempSync('e2e-phone-b-');
  });

  tearDown(() async {
    for (final dir in [stagingA, stagingB, sourcePhone, targetPhone]) {
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
      _seed(sourceDb);
      final sourceReceipts = _receipts(
        sourceDb,
        sourcePhone,
        installId: 'install-A',
        keys: _MemoryKeyStore(),
      );
      final stored = await sourceReceipts.addFromBytes(
        transactionId: 'txn-1',
        bytes: _receipt,
        fileName: 'receipt.png',
        mimeType: 'image/png',
      );
      expect(
        _isPprc(File(stored.localPath).readAsBytesSync()),
        isTrue,
        reason: 'the phone keeps the receipt encrypted at rest',
      );

      final source = LocalPortableSnapshotSource(
        appDb: sourceDb,
        namespace: namespace,
      );
      final sections = await source.capturePortableSections(
        stagingDirectory: stagingA,
      );
      final attachments = await source.listPortableAttachments();
      expect(attachments.single.id, stored.id);

      final collector = PortableAttachmentCollector();
      final collected = await collector.collect(
        sources: attachments,
        stagingDirectory: stagingA,
        receipts: sourceReceipts,
      );
      final attachmentId = collected.single.metadata.id;
      expect(
        collected.single.metadata.sha256,
        sha256.convert(_receipt).toString(),
        reason: 'the backup carries the readable receipt, not ciphertext',
      );
      expect(collected.single.metadata.byteLength, _receipt.length);

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
      expect(
        _containsRun(await archive.readAsBytes(), _plainRun),
        isFalse,
        reason: 'the receipt is only readable inside the encrypted backup',
      );

      // Restore side: a new phone (new install, empty key store), same
      // account, fresh database.
      final targetDb = _db();
      final targetReceipts = _receipts(
        targetDb,
        targetPhone,
        installId: 'install-B',
        keys: _MemoryKeyStore(),
      );
      final writer = LocalPortableRestoreWriter(
        appDb: targetDb,
        namespace: namespace,
        receipts: targetReceipts,
      );
      final inspector = PortableRestoreInspector();
      final staged = await inspector.inspectAndStage(
        backupFile: archive,
        passphrase: 'correct-horse',
        stagingDirectory: stagingB,
        expectedAccountBinding: namespace,
      );
      expect(staged.sectionFiles.containsKey('transactions'), isTrue);
      expect(staged.attachmentFiles[attachmentId]!.readAsBytesSync(), _receipt);

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

      // The receipt is re-encrypted for this phone's account key and opens
      // through the normal viewer path.
      final restored = (await targetReceipts.list('txn-1')).single;
      expect(restored.id, attachmentId);
      expect(restored.fileName, 'receipt.png');
      expect(restored.mimeType, 'image/png');
      expect(restored.localPath, startsWith('${targetPhone.path}/receipts/'));
      final restoredBytes = File(restored.localPath).readAsBytesSync();
      expect(_isPprc(restoredBytes), isTrue);
      expect(_containsRun(restoredBytes, _plainRun), isFalse);
      final viewed = await targetReceipts.decryptForViewing(restored);
      expect(viewed.file.readAsBytesSync(), _receipt);
      await viewed.release();

      // Nothing readable is left on the new phone outside the store.
      final leftovers = targetPhone
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !_isPprc(f.readAsBytesSync()))
          .map((f) => f.path);
      expect(leftovers, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a receipt this account cannot decrypt stops the export, leaving nothing staged',
    () async {
      final sourceDb = _db();
      final keys = _MemoryKeyStore();
      final receipts = _receipts(
        sourceDb,
        sourcePhone,
        installId: 'install-A',
        keys: keys,
      );
      await receipts.addFromBytes(
        transactionId: 'txn-1',
        bytes: _receipt,
        fileName: 'receipt.png',
      );
      await receipts.addFromBytes(
        transactionId: 'txn-1',
        bytes: _receipt,
        fileName: 'second.png',
      );
      final sources = await LocalPortableSnapshotSource(
        appDb: sourceDb,
        namespace: namespace,
      ).listPortableAttachments();
      expect(sources, hasLength(2));
      // Corrupt the second stored file: the first decrypts, the second fails.
      final second = File(sources.last.localPath);
      final bytes = second.readAsBytesSync();
      bytes[bytes.length - 1] ^= 0xff;
      second.writeAsBytesSync(bytes);

      await expectLater(
        PortableAttachmentCollector().collect(
          sources: sources,
          stagingDirectory: stagingA,
          receipts: receipts,
        ),
        throwsA(isA<ReceiptUnavailable>()),
      );
      expect(stagingA.listSync(), isEmpty);

      keys.values.clear(); // A lost key fails the same way.
      await expectLater(
        PortableAttachmentCollector().collect(
          sources: sources.take(1),
          stagingDirectory: stagingA,
          receipts: receipts,
        ),
        throwsA(isA<ReceiptUnavailable>()),
      );
      expect(stagingA.listSync(), isEmpty);
    },
  );

  test('populated target refuses staging', () async {
    final targetDb = _db();
    final writer = LocalPortableRestoreTargetInspector(
      appDb: targetDb,
      namespace: namespace,
    );
    final state = await writer.inspectFreshNamespace();
    expect(state.isFresh, isTrue);

    _seed(targetDb, attachmentLocalPath: 'receipts/att-1.pprc');
    final occupied = await writer.inspectFreshNamespace();
    expect(occupied.isFresh, isFalse);
    await expectLater(
      requireFreshPortableNamespace(writer),
      throwsA(isA<PortablePopulatedTargetException>()),
    );
  });
}

final class _InlineLease implements LocalKeyProvisioningLease {
  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) => operation();
}

final class _MemoryKeyStore implements SecureKeyValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<bool> writeIfAbsent(String key, String value) async {
    if (values.containsKey(key)) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
