import 'dart:async';
import 'dart:io';

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

/// Copies attachment bytes into private staging while hashing the source.
/// The source path is never used as an archive path or written to metadata.
class PortableAttachmentCollector {
  final Uuid _uuid;
  final PortableAttachmentLimits limits;

  PortableAttachmentCollector({Uuid? uuid, this.limits = const PortableAttachmentLimits()})
      : _uuid = uuid ?? const Uuid();

  Future<List<PortableCollectedAttachment>> collect({
    required Iterable<PortableAttachmentSource> sources,
    required Directory stagingDirectory,
    Future<bool> Function()? isCancelled,
  }) async {
    await stagingDirectory.create(recursive: true);
    final output = <PortableCollectedAttachment>[];
    var total = 0;
    try {
      for (final source in sources) {
        if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
        final file = File(source.localPath);
        if (!await file.exists()) throw FileSystemException('attachment is missing', source.localPath);
        final size = await file.length();
        if (size > limits.maxAttachmentBytes || total > limits.maxTotalBytes - size) {
          throw PortableBackupLimitExceeded('attachment bytes exceed portable backup limits');
        }
        final id = _uuid.v4();
        final destination = File('${stagingDirectory.path}${Platform.pathSeparator}$id.bin');
        final digest = PortableSha256Accumulator();
        final sink = destination.openWrite();
        var copied = 0;
        try {
          await for (final chunk in file.openRead()) {
            if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
            copied += chunk.length;
            if (copied > limits.maxAttachmentBytes || total + copied > limits.maxTotalBytes) {
              throw PortableBackupLimitExceeded('attachment bytes exceed portable backup limits');
            }
            sink.add(chunk);
            digest.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
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
              byteLength: copied,
              sha256: hash,
            ),
          ),
        );
        total += copied;
      }
      return output;
    } catch (_) {
      await cleanup(output.map((entry) => entry.stagedFile));
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
