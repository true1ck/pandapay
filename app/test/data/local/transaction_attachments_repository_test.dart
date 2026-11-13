import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/transaction_attachments_repository.dart';
import 'package:pandapay/data/portable_backup/private_temporary_workspace.dart';
import 'package:pandapay/data/secure_storage/encrypted_receipt_file.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';
import 'package:pandapay/data/secure_storage/local_key_provisioning_lease.dart';

/// Paths use the platform separator; compare them with `/` so the tests agree on Windows.
String _slash(String p) => p.replaceAll(r'\', '/');

void main() {
  late Directory root;
  late AppDatabase database;
  late _MemoryStore keys;
  late List<PrivateTemporaryWorkspace> workspaces;

  TransactionAttachmentsRepository make({
    String namespace = 'user:11111111-2222-3333-4444-555555555555',
    String installId = 'install-A',
    _MemoryStore? store,
    String? receiptsPath,
  }) => TransactionAttachmentsRepository(
    database,
    namespace: namespace,
    installId: () async => installId,
    receiptsDirectory: () async =>
        Directory(receiptsPath ?? '${root.path}/receipts'),
    workspace: () async {
      final workspace = await PrivateTemporaryWorkspace.create(
        Directory('${root.path}/tmp'),
      );
      workspaces.add(workspace);
      return workspace;
    },
    keyStore: store ?? keys,
    lease: _InlineLease(),
  );

  List<File> filesUnder(Directory directory) => directory.existsSync()
      ? directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => !f.path.contains('pandapay-private-v1-'))
            .toList()
      : [];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('receipts');
    database = openInMemoryForTesting();
    keys = _MemoryStore();
    workspaces = [];
  });
  tearDown(() async {
    database.close();
    await root.delete(recursive: true);
  });

  test('a receipt saved under a queued alias follows the transaction to its server id', () async {
    final repo = make();
    final plain = Uint8List.fromList(List<int>.generate(64, (i) => i));
    await repo.addFromBytes(
      transactionId: 'local-outbox:m-1',
      bytes: plain,
      fileName: 'r.png',
      mimeType: 'image/png',
    );
    expect(await repo.list('local-outbox:m-1'), hasLength(1));

    await repo.remapTransaction('local-outbox:m-1', 'server-9');

    expect(await repo.list('local-outbox:m-1'), isEmpty);
    final moved = await repo.list('server-9');
    expect(moved, hasLength(1));
    final opened = await repo.decryptForViewing(moved.single);
    expect(opened.file.readAsBytesSync(), plain);
    await opened.release();
  });

  test('receipts still open after the app container path changes', () async {
    // iOS may move an app's data container on update; stored paths must not
    // depend on where the container was when the receipt was saved.
    final before = '${root.path}/containerA/receipts';
    final after = '${root.path}/containerB/receipts';
    final plain = Uint8List.fromList(List<int>.generate(512, (i) => i % 251));
    final saved = await make(receiptsPath: before).addFromBytes(
      transactionId: 'tx-move',
      bytes: plain,
      fileName: 'move.png',
      mimeType: 'image/png',
    );
    expect(saved.localPath, startsWith(before));

    Directory('${root.path}/containerB').createSync(recursive: true);
    Directory(before).renameSync(after);

    final moved = make(receiptsPath: after);
    final listed = await moved.list('tx-move');
    expect(listed, hasLength(1));
    expect(listed.single.localPath, startsWith(after));
    final viewed = await moved.decryptForViewing(listed.single);
    expect(viewed.file.readAsBytesSync(), plain);
    await viewed.release();
  });

  test(
    'receipt bytes are stored as PPRC ciphertext and read back intact',
    () async {
      final repository = make();
      final plain = Uint8List.fromList(
        List<int>.generate(4096, (i) => 65 + i % 26),
      );
      final attachment = await repository.addFromBytes(
        transactionId: 'tx-1',
        bytes: plain,
        fileName: 'Synthetic Receipt.png',
        mimeType: 'image/png',
      );

      final stored = File(attachment.localPath).readAsBytesSync();
      expect(
        stored.take(4).toList(),
        EncryptedReceiptFileCodec.magic,
        reason: 'the stored file starts with the PPRC header',
      );
      expect(String.fromCharCodes(stored), isNot(contains('ABCDEFGHIJKLMNOP')));
      expect(_slash(attachment.localPath), startsWith(_slash('${root.path}/receipts/')));

      final viewed = await repository.decryptForViewing(attachment);
      expect(viewed.file.readAsBytesSync(), plain);
      await viewed.release();
      expect(viewed.file.existsSync(), isFalse);
    },
  );

  test('tiny receipts and file copies are encrypted too', () async {
    final repository = make();
    final tiny = await repository.addFromBytes(
      transactionId: 'tx-1',
      bytes: [1, 2, 3],
      fileName: 'a.bin',
    );
    final viewed = await repository.decryptForViewing(tiny);
    expect(viewed.file.readAsBytesSync(), [1, 2, 3]);
    await viewed.release();

    final source = File('${root.path}/picked.jpg')
      ..writeAsBytesSync(List<int>.filled(512, 7));
    final copied = await repository.addFromPath(
      transactionId: 'tx-1',
      sourcePath: source.path,
      fileName: 'picked.jpg',
      mimeType: 'image/jpeg',
    );
    expect(
      File(copied.localPath).readAsBytesSync().take(4),
      EncryptedReceiptFileCodec.magic,
    );
    expect(
      source.existsSync(),
      isTrue,
      reason: 'the picked source is never touched',
    );
    final again = await repository.decryptForViewing(copied);
    expect(again.file.readAsBytesSync(), List<int>.filled(512, 7));
    await again.release();
  });

  test('no plaintext copy is left behind after adding from bytes', () async {
    final repository = make();
    await repository.addFromBytes(
      transactionId: 'tx-1',
      bytes: List<int>.filled(64, 9),
      fileName: 'a.bin',
    );
    for (final workspace in workspaces) {
      expect(workspace.directory.existsSync(), isFalse);
    }
    final all = filesUnder(root).where((f) => !_slash(f.path).contains('/receipts/'));
    expect(all, isEmpty);
  });

  test('another account namespace cannot read the file', () async {
    final attachment = await make().addFromBytes(
      transactionId: 'tx-1',
      bytes: [1, 2, 3],
      fileName: 'a.bin',
    );
    await expectLater(
      make(
        namespace: 'user:99999999-aaaa-bbbb-cccc-dddddddddddd',
      ).decryptForViewing(attachment),
      throwsA(isA<ReceiptUnavailable>()),
    );
  });

  test(
    'a lost key leaves existing receipts unreadable, never silently re-keyed',
    () async {
      final repository = make();
      final attachment = await repository.addFromBytes(
        transactionId: 'tx-1',
        bytes: [1, 2, 3],
        fileName: 'a.bin',
      );
      keys.values.clear();
      await expectLater(
        repository.decryptForViewing(attachment),
        throwsA(isA<ReceiptUnavailable>()),
      );
      await expectLater(
        repository.addFromBytes(
          transactionId: 'tx-1',
          bytes: [4],
          fileName: 'b.bin',
        ),
        throwsA(isA<ReceiptUnavailable>()),
      );
    },
  );

  test('a locked key store fails the add and leaves no file or row', () async {
    keys.locked = true;
    final repository = make();
    await expectLater(
      repository.addFromBytes(
        transactionId: 'tx-1',
        bytes: [1],
        fileName: 'a.bin',
      ),
      throwsA(isA<ReceiptUnavailable>()),
    );
    expect(filesUnder(Directory('${root.path}/receipts')), isEmpty);
    expect(await repository.list('tx-1'), isEmpty);
  });

  test('a session-style namespace still gets its own key', () async {
    final repository = make(namespace: 'session:${'a' * 64}');
    final attachment = await repository.addFromBytes(
      transactionId: 'tx-1',
      bytes: [1, 2, 3],
      fileName: 'a.bin',
    );
    final viewed = await repository.decryptForViewing(attachment);
    expect(viewed.file.readAsBytesSync(), [1, 2, 3]);
    await viewed.release();
  });

  test(
    'backup restore refuses an attachment id that is not a plain name',
    () async {
      final plain = File('${root.path}/staged.bin')..writeAsBytesSync([1, 2]);
      for (final id in ['../escape', 'a/b', '.hidden', '']) {
        await expectLater(
          make().storeEncrypted(
            attachmentId: id,
            transactionId: 'tx-1',
            plaintext: plain,
          ),
          throwsFormatException,
          reason: id,
        );
      }
      expect(filesUnder(Directory('${root.path}/receipts')), isEmpty);
    },
  );

  test(
    'backup restore replaces a file an interrupted restore left without a row',
    () async {
      final repository = make();
      final plain = File('${root.path}/staged.bin')
        ..writeAsBytesSync([1, 2, 3]);
      final first = await repository.storeEncrypted(
        attachmentId: 'att-1',
        transactionId: 'tx-1',
        plaintext: plain,
      );
      // No row was written (the app stopped mid-restore); a retry succeeds.
      plain.writeAsBytesSync([4, 5, 6]);
      final again = await repository.storeEncrypted(
        attachmentId: 'att-1',
        transactionId: 'tx-1',
        plaintext: plain,
      );
      expect(again, first);
      final restored = TransactionAttachment(
        id: 'att-1',
        transactionId: 'tx-1',
        fileName: 'a.bin',
        localPath: again,
        mimeType: null,
        createdAt: DateTime(2026),
      );
      final viewed = await repository.decryptForViewing(restored);
      expect(viewed.file.readAsBytesSync(), [4, 5, 6]);
      await viewed.release();

      // A file that a row points to is never replaced.
      database.db.execute(
        'INSERT INTO transaction_attachments '
        '(id, transaction_id, file_name, local_path, mime_type, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['att-1', 'tx-1', 'a.bin', again, null, 1],
      );
      await expectLater(
        repository.storeEncrypted(
          attachmentId: 'att-1',
          transactionId: 'tx-1',
          plaintext: plain,
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('delete removes the encrypted file and the row', () async {
    final repository = make();
    final attachment = await repository.addFromBytes(
      transactionId: 'tx-1',
      bytes: [1, 2, 3],
      fileName: 'a.bin',
    );
    expect(await repository.list('tx-1'), hasLength(1));
    await repository.delete(attachment);
    expect(File(attachment.localPath).existsSync(), isFalse);
    expect(await repository.list('tx-1'), isEmpty);
  });
}

final class _InlineLease implements LocalKeyProvisioningLease {
  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) => operation();
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  bool locked = false;
  void _check() {
    if (locked) throw const SecureKeyStoreUnavailable();
  }

  @override
  Future<String?> read(String key) async {
    _check();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _check();
    values[key] = value;
  }

  @override
  Future<bool> writeIfAbsent(String key, String value) async {
    _check();
    if (values.containsKey(key)) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async {
    _check();
    values.remove(key);
  }
}
