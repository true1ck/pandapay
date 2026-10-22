import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'canonical_ndjson.dart';
import 'portable_attachments.dart';
import 'portable_backup_models.dart';

/// Encryption is intentionally a port. Do not substitute ZIP's legacy AES
/// password mode: v1 requires Argon2id plus an authenticated streaming AEAD.
abstract interface class PortableBackupEncryptor {
  Future<void> encryptFile({
    required File plaintextArchive,
    required File destination,
    required String passphrase,
    Future<bool> Function()? isCancelled,
  });
}

class PortableBackupCryptoUnavailable implements Exception {
  const PortableBackupCryptoUnavailable();

  @override
  String toString() =>
      'portable backup encryption is unavailable; integrate the approved Argon2id/secretstream binding';
}

class UnsupportedPortableBackupEncryptor implements PortableBackupEncryptor {
  const UnsupportedPortableBackupEncryptor();

  @override
  Future<void> encryptFile({
    required File plaintextArchive,
    required File destination,
    required String passphrase,
    Future<bool> Function()? isCancelled,
  }) async {
    throw const PortableBackupCryptoUnavailable();
  }
}

class PortableArchiveLimits {
  final int maxEntries;
  final int maxExpandedBytes;
  final int maxEntryBytes;
  final int maxNesting;

  const PortableArchiveLimits({
    this.maxEntries = 4096,
    this.maxExpandedBytes = 1024 * 1024 * 1024,
    this.maxEntryBytes = 512 * 1024 * 1024,
    this.maxNesting = 8,
  });
}

/// Produces the plaintext bounded ZIP, then hands it to the approved crypto
/// implementation. Temporary plaintext is always deleted by this class.
class PortableArchiveWriter {
  final PortableBackupEncryptor encryptor;
  final PortableArchiveLimits limits;

  const PortableArchiveWriter({
    this.encryptor = const UnsupportedPortableBackupEncryptor(),
    this.limits = const PortableArchiveLimits(),
  });

  Future<void> write({
    required PortableBackupManifest manifest,
    required Map<String, File> sectionFiles,
    required List<PortableCollectedAttachment> attachments,
    required File output,
    required String passphrase,
    required Directory stagingDirectory,
    Future<bool> Function()? isCancelled,
  }) async {
    manifest.validate(requireComplete: true);
    final sectionByPath = <String, File>{};
    for (final section in manifest.sections) {
      final file = sectionFiles[section.name];
      if (file == null) throw FormatException('missing section file ${section.name}');
      await _validateStagedFile(file, section.byteLength, section.sha256);
      if (!sectionByPath.containsKey(section.path)) sectionByPath[section.path] = file;
    }
    for (final attachment in attachments) {
      final metadata = attachment.metadata;
      final expected = manifest.attachments.firstWhere(
        (candidate) => candidate.id == metadata.id,
        orElse: () => throw FormatException('attachment missing from manifest ${metadata.id}'),
      );
      if (expected.path != metadata.path || expected.sha256 != metadata.sha256) {
        throw FormatException('attachment metadata does not match manifest');
      }
      await _validateStagedFile(attachment.stagedFile, metadata.byteLength, metadata.sha256);
      if (!sectionByPath.containsKey(metadata.path)) sectionByPath[metadata.path] = attachment.stagedFile;
    }
    final tempZip = File(path.join(stagingDirectory.path, 'portable-${manifest.backupId}.zip'));
    await stagingDirectory.create(recursive: true);
    try {
      final zip = ZipFileEncoder();
      zip.create(tempZip.path, level: 6, modified: DateTime.utc(1980, 1, 1));
      final manifestBytes = utf8.encode('${canonicalJsonEncode(manifest.toJson())}\n');
      zip.addArchiveFile(ArchiveFile.bytes('manifest.json', manifestBytes));
      for (final entry in sectionByPath.entries) {
        if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
        validatePortableArchivePath(entry.key, maxDepth: limits.maxNesting);
        zip.addFileSync(entry.value, entry.key, PortableArchiveLimitsStore.level);
      }
      zip.closeSync();
      if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
      await output.parent.create(recursive: true);
      await encryptor.encryptFile(
        plaintextArchive: tempZip,
        destination: output,
        passphrase: passphrase,
        isCancelled: isCancelled,
      );
    } finally {
      try {
        if (await tempZip.exists()) await tempZip.delete();
      } on FileSystemException {
        // Do not hide a write/encryption error with a cleanup error.
      }
    }
  }

  Future<void> _validateStagedFile(File file, int expectedLength, String expectedDigest) async {
    if (!file.existsSync()) throw FileSystemException('staged file is missing', file.path);
    final length = file.lengthSync();
    if (length != expectedLength) {
      throw FormatException('staged file length mismatch for ${file.path}');
    }
    if (length > limits.maxEntryBytes) throw PortableBackupLimitExceeded('archive entry is too large');
    if (await sha256Checksum(file) != expectedDigest) {
      throw FormatException('staged file digest mismatch for ${file.path}');
    }
  }
}

/// `ZipFileEncoder.addFileSync` accepts a nullable compression level; keeping
/// this constant in one place makes the writer's deterministic settings clear.
abstract final class PortableArchiveLimitsStore {
  static const int level = 6;
}

/// Streaming SHA-256 of a staged file (never holds the whole file in memory).
Future<String> sha256Checksum(File file) async {
  final accumulator = PortableSha256Accumulator();
  await for (final chunk in file.openRead()) {
    accumulator.add(chunk);
  }
  return accumulator.close();
}

class PortableArchiveVerificationResult {
  final PortableBackupManifest manifest;
  final int expandedBytes;
  final int entryCount;

  const PortableArchiveVerificationResult({
    required this.manifest,
    required this.expandedBytes,
    required this.entryCount,
  });
}

/// Independent verifier for a decrypted ZIP. It validates entry names, size
/// limits, manifest membership, section hashes and attachment hashes before a
/// caller can offer a restore/commit action.
class PortableArchiveVerifier {
  final PortableArchiveLimits limits;

  const PortableArchiveVerifier({this.limits = const PortableArchiveLimits()});

  PortableArchiveVerificationResult verify(File zipFile) {
    final bytes = zipFile.readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.length > limits.maxEntries) {
      throw PortableBackupLimitExceeded('archive contains too many entries');
    }
    final names = <String>{};
    var expanded = 0;
    ArchiveFile? manifestEntry;
    for (final entry in archive.files) {
      if (!entry.isFile) throw FormatException('archive directories are not allowed');
      validatePortableArchivePath(entry.name, maxDepth: limits.maxNesting);
      if (!names.add(entry.name)) throw FormatException('duplicate archive path ${entry.name}');
      if (entry.size > limits.maxEntryBytes || expanded > limits.maxExpandedBytes - entry.size) {
        throw PortableBackupLimitExceeded('archive expanded size exceeds limits');
      }
      expanded += entry.size;
      if (entry.name == 'manifest.json') manifestEntry = entry;
    }
    if (manifestEntry == null) throw FormatException('manifest.json is missing');
    final manifestJson = jsonDecode(utf8.decode(manifestEntry.readBytes()!)) as Map<String, dynamic>;

    final manifest = PortableBackupManifest.fromJson(manifestJson);
    manifest.validate(requireComplete: true);
    final expectedPaths = <String>{'manifest.json'};
    for (final section in manifest.sections) {
      _verifyEntry(archive, section.path, section.byteLength, section.sha256);
      expectedPaths.add(section.path);
    }
    for (final attachment in manifest.attachments) {
      _verifyEntry(archive, attachment.path, attachment.byteLength, attachment.sha256);
      expectedPaths.add(attachment.path);
    }
    for (final entry in archive.files) {
      if (!expectedPaths.contains(entry.name)) throw FormatException('unknown archive entry ${entry.name}');
    }
    return PortableArchiveVerificationResult(
      manifest: manifest,
      expandedBytes: expanded,
      entryCount: archive.files.length,
    );
  }

  void _verifyEntry(Archive archive, String name, int length, String digest) {
    final entry = archive.findFile(name);
    if (entry == null) throw FormatException('manifest entry is missing: $name');
    final bytes = entry.readBytes();
    if (bytes == null || bytes.length != length || sha256.convert(bytes).toString() != digest) {
      throw FormatException('archive entry integrity check failed: $name');
    }
  }
}
