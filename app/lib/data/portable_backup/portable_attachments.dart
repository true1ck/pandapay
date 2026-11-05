import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'canonical_ndjson.dart';
import 'portable_backup_models.dart';

class PortableAttachmentSource {
  final String id;
  final String transactionId;
  final String fileName;
  final String? mimeType;
  final String localPath;

  const PortableAttachmentSource({
    required this.id,
    required this.transactionId,
    required this.fileName,
    required this.mimeType,
    required this.localPath,
  });
}

/// The per-account encrypted receipt store, as the portable backup uses it.
///
/// Receipts are encrypted at rest under a key that never leaves the phone
/// (`.pprc`, see `TransactionAttachmentsRepository`), so the stored files are
/// never copied as they are: a backup of them could not be read anywhere
/// else. Export decrypts through the store into private backup staging, and
/// the archive is then passphrase-encrypted. Restore encrypts the staged
/// bytes back into the store under the current account's key. Plaintext only
/// exists in private staging, which the caller removes.
abstract interface class PortableReceiptVault {
  /// The decrypted bytes of one stored receipt. Throws when the current
  /// account cannot decrypt it (key locked or lost, file damaged or another
  /// account's). The caller clears the returned bytes after use.
  Future<Uint8List> readPlaintext(PortableAttachmentSource source);

  /// Encrypts [plaintext] into the store as [attachmentId] for the current
  /// account and returns the encrypted file's path. Does not write the
  /// attachment row and does not delete [plaintext].
  Future<String> storeEncrypted({
    required String attachmentId,
    required String transactionId,
    required File plaintext,
  });
}

class PortableCollectedAttachment {
  final PortableBackupAttachment metadata;
  final File stagedFile;

  const PortableCollectedAttachment({required this.metadata, required this.stagedFile});
}

class PortableAttachmentLimits {
  final int maxAttachmentBytes;
  final int maxTotalBytes;
  final int chunkBytes;

  const PortableAttachmentLimits({
    this.maxAttachmentBytes = 100 * 1024 * 1024,
    this.maxTotalBytes = 500 * 1024 * 1024,
    this.chunkBytes = 64 * 1024,
  });
}

/// Decrypts each attachment through the receipt store into private staging
/// and hashes the plaintext. The source path is never used as an archive path
/// or written to metadata, and the stored (encrypted) file is never copied.
class PortableAttachmentCollector {
  final Uuid _uuid;
  final PortableAttachmentLimits limits;

  PortableAttachmentCollector({Uuid? uuid, this.limits = const PortableAttachmentLimits()})
      : _uuid = uuid ?? const Uuid();

  Future<List<PortableCollectedAttachment>> collect({
    required Iterable<PortableAttachmentSource> sources,
    required Directory stagingDirectory,
    required PortableReceiptVault receipts,
    Future<bool> Function()? isCancelled,
  }) async {
    await stagingDirectory.create(recursive: true);
    final output = <PortableCollectedAttachment>[];
    final staged = <File>[];
    var total = 0;
    try {
      for (final source in sources) {
        if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
        final clear = await receipts.readPlaintext(source);
        try {
          final size = clear.length;
          if (size > limits.maxAttachmentBytes || total > limits.maxTotalBytes - size) {
            throw PortableBackupLimitExceeded('attachment bytes exceed portable backup limits');
          }
          if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
          final id = _uuid.v4();
          final destination = File('${stagingDirectory.path}${Platform.pathSeparator}$id.bin');
          await destination.create(exclusive: true);
          staged.add(destination);
          await destination.writeAsBytes(clear, flush: true);
          final digest = PortableSha256Accumulator()..add(clear);
          final hash = digest.close();
          final extension = _safeExtension(source.fileName);
          final archivePath = 'attachments/$hash${extension.isEmpty ? '' : '.$extension'}';
          validatePortableArchivePath(archivePath);
          output.add(
            PortableCollectedAttachment(
              stagedFile: destination,
              metadata: PortableBackupAttachment(
                id: id,
                path: archivePath,
                transactionId: source.transactionId,
                fileName: _safeDisplayName(source.fileName),
                mimeType: source.mimeType,
                byteLength: size,
                sha256: hash,
              ),
            ),
          );
          total += size;
        } finally {
          clear.fillRange(0, clear.length, 0);
        }
      }
      return output;
    } catch (_) {
      await cleanup(staged);
      rethrow;
    }
  }

  static String _safeDisplayName(String value) {
    final base = value.replaceAll('\\', '/').split('/').last.trim();
    final sanitized = base.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    return sanitized.isEmpty ? 'attachment' : sanitized.substring(0, sanitized.length.clamp(0, 180));
  }

  static String _safeExtension(String value) {
    final name = _safeDisplayName(value);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    final extension = name.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,12}$').hasMatch(extension) ? extension : '';
  }
}

Future<void> cleanup(Iterable<File> files) async {
  for (final file in files) {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cleanup is best effort; preserve the original failure.
    }
  }
}

class PortableBackupLimitExceeded implements Exception {
  final String message;

  const PortableBackupLimitExceeded(this.message);

  @override
  String toString() => message;
}
