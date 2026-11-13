import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../portable_backup/account_recovery_operation_gate.dart';
import '../portable_backup/app_private_temporary_storage.dart';
import '../portable_backup/portable_attachments.dart';
import '../portable_backup/private_temporary_workspace.dart';
import '../secure_storage/encrypted_receipt_file.dart';
import '../secure_storage/flutter_secure_key_value_store.dart';
import '../secure_storage/local_database_key_custody.dart';
import '../secure_storage/local_key_provisioning_lease.dart';
import '../secure_storage/local_receipt_key_custody.dart';
import 'app_database.dart';
import 'storage_paths.dart';

/// A receipt, bill, warranty, or other proof attached to one transaction.
///
/// Attachments are deliberately local-only for now. A receipt can contain an
/// address, order number, or other sensitive information, so cloud backup must
/// be an explicit future opt-in rather than an accidental side effect of
/// adding a file to a transaction.
class TransactionAttachment {
  final String id;
  final String transactionId;
  final String fileName;
  final String localPath;
  final String? mimeType;
  final DateTime createdAt;

  const TransactionAttachment({
    required this.id,
    required this.transactionId,
    required this.fileName,
    required this.localPath,
    required this.mimeType,
    required this.createdAt,
  });
}

/// A receipt could not be encrypted or read: the phone is locked, the key is
/// gone, or the file belongs to another account. Nothing is stored or shown.
final class ReceiptUnavailable implements Exception {
  const ReceiptUnavailable([this.status]);
  final LocalKeyStatus? status;
  @override
  String toString() => 'Receipt unavailable';
}

/// A decrypted copy in a private temporary workspace. Call [release] as soon
/// as the viewer or share sheet closes; a startup sweep also removes strays.
final class DecryptedAttachment {
  DecryptedAttachment._(this.file, this._workspace);
  final File file;
  final PrivateTemporaryWorkspace _workspace;
  Future<void> release() async {
    await _workspace.cleanup();
  }
}

/// Receipt files are AES-256-GCM encrypted (`PPRC` format) under
/// `Application Support/PandaPay/receipts/ACCOUNT/TRANSACTION/`, with a
/// per-account key kept in the Keychain/Keystore. A decrypted copy exists only
/// while a viewer is open, or in private staging while a portable backup is
/// built or restored ([PortableReceiptVault]).
class TransactionAttachmentsRepository implements PortableReceiptVault {
  final AppDatabase _database;
  final String namespace;
  final Future<String> Function() installId;
  final Future<Directory> Function() _receiptsDirectory;
  final Future<PrivateTemporaryWorkspace> Function() _workspace;
  final EncryptedReceiptFileStore _store;
  final LocalReceiptKeyCustody _custody;

  TransactionAttachmentsRepository(
    this._database, {
    required this.namespace,
    required this.installId,
    Future<Directory> Function()? receiptsDirectory,
    Future<PrivateTemporaryWorkspace> Function()? workspace,
    EncryptedReceiptFileStore? store,
    SecureKeyValueStore? keyStore,
    LocalKeyProvisioningLease? lease,
  }) : _receiptsDirectory =
           receiptsDirectory ??
           (() async => (await StoragePaths.resolve()).receiptsDir),
       _workspace = workspace ?? AppPrivateTemporaryStorage.create,
       _store = store ?? EncryptedReceiptFileStore(),
       _custody = LocalReceiptKeyCustody(
         keyStore ?? FlutterSecureKeyValueStore(),
         lease: lease,
       );

  /// The key-slot namespace. Only `user:` and `guest:` ids are accepted by the
  /// receipt key custody; any other session label maps to a hashed guest slot.
  late final String _keyNamespace = _normalizeNamespace(namespace);

  static String _normalizeNamespace(String value) {
    if (RegExp(r'^(user|guest):[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
      return value;
    }
    return 'guest:${sha256.convert(utf8.encode(value)).toString().substring(0, 40)}';
  }

  /// The folder name under the receipts directory that holds [namespace]'s
  /// files. Rows of `transaction_attachments` have no namespace column; this
  /// folder (the first segment of their stored path) is what tells accounts
  /// apart, so sign-out can count only the current account's receipts.
  static String accountFolderFor(String namespace) => sha256
      .convert(utf8.encode(_normalizeNamespace(namespace)))
      .toString()
      .substring(0, 32);

  /// True when the stored attachment path [storedPath] is not known to belong
  /// to another account: it sits under [namespace]'s folder, or under no
  /// account folder at all (an old flat path whose owner cannot be proven, so
  /// it is counted rather than hidden). Accepts both the relative form and the
  /// old absolute form (`.../receipts/<folder>/...`), with either separator.
  static bool storedPathMayBelongTo(String storedPath, String namespace) {
    final segments = storedPath
        .replaceAll(r'\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return true;
    final receiptsAt = segments.lastIndexOf('receipts');
    final index = receiptsAt >= 0 ? receiptsAt + 1 : 0;
    if (index >= segments.length) return true;
    final folder = segments[index];
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(folder)) return true;
    return folder == accountFolderFor(namespace);
  }

  /// The form stored in the database: relative to the receipts folder, so a
  /// receipt keeps working when iOS moves the app's data container.
  Future<String> _storedPath(File file) async {
    final root = (await _receiptsDirectory()).path;
    return p.isWithin(root, file.path)
        ? p.relative(file.path, from: root)
        : file.path;
  }

  /// Turns a stored path back into a file path for this launch. Older rows hold
  /// an absolute path from a previous container; when it no longer exists, the
  /// part under `receipts/` is re-rooted in the current receipts folder.
  Future<String> resolvePath(String stored) async {
    final root = (await _receiptsDirectory()).path;
    if (!p.isAbsolute(stored)) return p.join(root, stored);
    if (File(stored).existsSync()) return stored;
    final parts = p.split(stored);
    final index = parts.lastIndexOf('receipts');
    if (index < 0 || index == parts.length - 1) return stored;
    return p.joinAll([root, ...parts.sublist(index + 1)]);
  }

  Future<Directory> _transactionDirectory(String transactionId) async {
    final root = await _receiptsDirectory();
    final account = accountFolderFor(namespace);
    final safeTransaction = transactionId.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '_',
    );
    return Directory(p.join(root.path, account, safeTransaction));
  }

  Future<bool> _accountHasReceipts() async {
    final root = await _receiptsDirectory();
    final account = Directory(
      p.join(root.path, accountFolderFor(namespace)),
    );
    if (!await account.exists()) return false;
    return account.list(recursive: true).any((entry) => entry is File);
  }

  Future<T> _withKey<T>({
    required bool receiptsExist,
    required Future<T> Function(SecretKey key, int version) use,
  }) async {
    final LocalReceiptKeyResult result;
    try {
      result = await _custody.openKey(
        installId: await installId(),
        accountNamespace: _keyNamespace,
        encryptedReceiptsExist: receiptsExist,
      );
    } on Object {
      throw const ReceiptUnavailable();
    }
    final handle = result.handle;
    if (handle == null) throw ReceiptUnavailable(result.status);
    try {
      return await handle.withSecretKey((key) => use(key, handle.version));
    } finally {
      handle.dispose();
    }
  }

  Future<List<TransactionAttachment>> list(String transactionId) async {
    final rows = _database.db.select(
      'SELECT id, transaction_id, file_name, local_path, mime_type, created_at '
      'FROM transaction_attachments WHERE transaction_id = ? ORDER BY created_at DESC',
      [transactionId],
    );
    return [
      for (final row in rows)
        TransactionAttachment(
          id: row['id'] as String,
          transactionId: row['transaction_id'] as String,
          fileName: row['file_name'] as String,
          localPath: await resolvePath(row['local_path'] as String),
          mimeType: row['mime_type'] as String?,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at'] as int,
          ),
        ),
    ];
  }

  Future<TransactionAttachment> addFromPath({
    required String transactionId,
    required String sourcePath,
    required String fileName,
    String? mimeType,
  }) => _add(
    transactionId: transactionId,
    fileName: fileName,
    mimeType: mimeType,
    source: File(sourcePath),
  );

  Future<TransactionAttachment> addFromBytes({
    required String transactionId,
    required List<int> bytes,
    required String fileName,
    String? mimeType,
  }) async {
    // The encryptor reads from a file, so stage the bytes in a private
    // temporary workspace and delete it whatever happens.
    final workspace = await _workspace();
    try {
      final staged = workspace.file('incoming.bin');
      await staged.writeAsBytes(bytes, flush: true);
      return await _add(
        transactionId: transactionId,
        fileName: fileName,
        mimeType: mimeType,
        source: staged,
      );
    } finally {
      await workspace.cleanup();
    }
  }

  Future<TransactionAttachment> _add({
    required String transactionId,
    required String fileName,
    required String? mimeType,
    required File source,
  }) => AccountRecoveryOperationGate.process.run(() async {
    final directory = await _transactionDirectory(transactionId);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final destination = File(p.join(directory.path, '$id.pprc'));
    final existing = await _accountHasReceipts();
    // The key comes first: a locked or lost key stores nothing at all.
    await _withKey(
      receiptsExist: existing,
      use: (key, version) async {
        await directory.create(recursive: true);
        await _store.copyEncrypted(
          source: source,
          destination: destination,
          key: key,
          accountNamespace: _keyNamespace,
          attachmentId: id,
          keyVersion: version,
        );
      },
    );

    try {
      _database.db.execute(
        'INSERT INTO transaction_attachments '
        '(id, transaction_id, file_name, local_path, mime_type, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          id,
          transactionId,
          _safeFileName(fileName),
          await _storedPath(destination),
          mimeType,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    } catch (_) {
      try {
        await destination.delete();
      } catch (_) {
        // The database write is the source of truth for the attachment list;
        // a failed cleanup should not hide the original database error.
      }
      rethrow;
    }

    return TransactionAttachment(
      id: id,
      transactionId: transactionId,
      fileName: _safeFileName(fileName),
      localPath: destination.path,
      mimeType: mimeType,
      createdAt: DateTime.now(),
    );
  });

  /// Decrypts into a private temporary workspace for viewing or sharing.
  /// Throws [ReceiptUnavailable] when the key is locked or lost, or the file
  /// is not this account's. The caller must [DecryptedAttachment.release].
  Future<DecryptedAttachment> decryptForViewing(
    TransactionAttachment attachment,
  ) async {
    final workspace = await _workspace();
    try {
      final extension = p.extension(attachment.fileName);
      final name =
          'receipt-${attachment.id}'
          '${RegExp(r'^\.[A-Za-z0-9]{1,8}$').hasMatch(extension) ? extension : ''}';
      final file = await _withKey(
        receiptsExist: true,
        use: (key, version) => _store.decryptToPrivateWorkspace(
          encryptedFile: File(attachment.localPath),
          workspace: workspace,
          filename: name,
          key: key,
          accountNamespace: _keyNamespace,
          attachmentId: attachment.id,
          keyVersion: version,
        ),
      );
      return DecryptedAttachment._(file, workspace);
    } on ReceiptUnavailable {
      await workspace.cleanup();
      rethrow;
    } on Object {
      await workspace.cleanup();
      throw const ReceiptUnavailable();
    }
  }

  /// Portable backup export. Not gated by [AccountRecoveryOperationGate]: it
  /// only reads, and a backup or restore already runs as the recovery side.
  @override
  Future<Uint8List> readPlaintext(PortableAttachmentSource source) async {
    final path = await resolvePath(source.localPath);
    try {
      return await _withKey(
        receiptsExist: true,
        use: (key, version) => _store.decryptBytes(
          encryptedFile: File(path),
          key: key,
          accountNamespace: _keyNamespace,
          attachmentId: source.id,
          keyVersion: version,
        ),
      );
    } on ReceiptUnavailable {
      rethrow;
    } on Object {
      throw const ReceiptUnavailable();
    }
  }

  /// Portable backup restore: encrypts a restored receipt for this account.
  /// The restore writer records the row inside its own transaction, and
  /// deletes the file again if that transaction rolls back.
  @override
  Future<String> storeEncrypted({
    required String attachmentId,
    required String transactionId,
    required File plaintext,
  }) async {
    // The id names the file and is bound into the ciphertext.
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(attachmentId)) {
      throw const FormatException('Invalid restored attachment id');
    }
    final directory = await _transactionDirectory(transactionId);
    final destination = File(p.join(directory.path, '$attachmentId.pprc'));
    final existing = await _accountHasReceipts();
    await _withKey(
      receiptsExist: existing,
      use: (key, version) async {
        await directory.create(recursive: true);
        // An interrupted restore can leave a file that no row points to; a
        // retry replaces it. A file with a row is never replaced.
        final referenced = _database.db.select(
          'SELECT 1 FROM transaction_attachments '
          'WHERE id = ? OR local_path = ? OR local_path = ?',
          [attachmentId, destination.path, await _storedPath(destination)],
        );
        if (referenced.isEmpty &&
            await FileSystemEntity.type(destination.path, followLinks: false) ==
                FileSystemEntityType.file) {
          await destination.delete();
        }
        await _store.copyEncrypted(
          source: plaintext,
          destination: destination,
          key: key,
          accountNamespace: _keyNamespace,
          attachmentId: attachmentId,
          keyVersion: version,
        );
      },
    );
    return destination.path;
  }

  Future<void> delete(TransactionAttachment attachment) =>
      AccountRecoveryOperationGate.process.run(() async {
        _database.db.execute(
          'DELETE FROM transaction_attachments WHERE id = ?',
          [attachment.id],
        );
        final file = File(attachment.localPath);
        if (await file.exists()) await file.delete();
      });

  static String _safeFileName(String value) {
    final base = p.basename(value).trim();
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty ? 'receipt' : safe;
  }
}
