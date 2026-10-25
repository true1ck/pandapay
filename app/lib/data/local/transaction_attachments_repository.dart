import '../portable_backup/account_recovery_operation_gate.dart';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_database.dart';

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

class TransactionAttachmentsRepository {
  final AppDatabase _database;

  TransactionAttachmentsRepository(this._database);

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
          localPath: row['local_path'] as String,
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
  }) async {
    return _add(
      transactionId: transactionId,
      fileName: fileName,
      mimeType: mimeType,
      copy: (destination) => File(sourcePath).copy(destination),
    );
  }

  Future<TransactionAttachment> addFromBytes({
    required String transactionId,
    required List<int> bytes,
    required String fileName,
    String? mimeType,
  }) async {
    return _add(
      transactionId: transactionId,
      fileName: fileName,
      mimeType: mimeType,
      copy: (destination) async {
        final file = File(destination);
        await file.writeAsBytes(bytes, flush: true);
        return file;
      },
    );
  }

  Future<TransactionAttachment> _add({
    required String transactionId,
    required String fileName,
    required String? mimeType,
    required Future<File> Function(String destination) copy,
  }) => AccountRecoveryOperationGate.process.run(() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(
      p.join(root.path, 'transaction_attachments', transactionId),
    );
    await directory.create(recursive: true);

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final safeName = _safeFileName(fileName);
    final storedName = '${id}_$safeName';
    final destination = p.join(directory.path, storedName);
    await copy(destination);

    try {
      _database.db.execute(
        'INSERT INTO transaction_attachments '
        '(id, transaction_id, file_name, local_path, mime_type, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          id,
          transactionId,
          fileName,
          destination,
          mimeType,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    } catch (_) {
      try {
        await File(destination).delete();
      } catch (_) {
        // The database write is the source of truth for the attachment list;
        // a failed cleanup should not hide the original database error.
      }
      rethrow;
    }

    return TransactionAttachment(
      id: id,
      transactionId: transactionId,
      fileName: fileName,
      localPath: destination,
      mimeType: mimeType,
      createdAt: DateTime.now(),
    );
  });

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
