import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'canonical_ndjson.dart';
import 'portable_archive.dart';
import 'portable_attachments.dart';
import 'portable_crypto.dart';

class PortableRestoreAccountMismatch implements Exception {
  const PortableRestoreAccountMismatch();
  @override
  String toString() => 'portable backup belongs to a different account';
}

class PortablePopulatedTargetException implements Exception {
  const PortablePopulatedTargetException();
  @override
  String toString() => 'portable restore requires a fresh local namespace';
}

class PortableFreshNamespaceState {
  final bool hasPortableRows;
  final bool hasAttachments;
  const PortableFreshNamespaceState({required this.hasPortableRows, required this.hasAttachments});
  bool get isFresh => !hasPortableRows && !hasAttachments;
}

abstract interface class PortableRestoreTargetInspector {
  Future<PortableFreshNamespaceState> inspectFreshNamespace();
}

Future<void> requireFreshPortableNamespace(PortableRestoreTargetInspector target) async {
  if (!(await target.inspectFreshNamespace()).isFresh) {
    throw const PortablePopulatedTargetException();
  }
}

class PortableStagedRestore {
  final Directory stagingDirectory;
  final File decryptedArchive;
  final PortableArchiveVerificationResult verification;
  final Map<String, File> sectionFiles;
  final Map<String, File> attachmentFiles;
  bool _cleaned = false;

  PortableStagedRestore({
    required this.stagingDirectory,
    required this.decryptedArchive,
    required this.verification,
    required this.sectionFiles,
    required this.attachmentFiles,
  });

  Future<void> cleanup() async {
    if (_cleaned) return;
    _cleaned = true;
    try {
      if (await stagingDirectory.exists()) await stagingDirectory.delete(recursive: true);
    } on FileSystemException {
      // Startup cleanup may retry a locked staging directory.
    }
  }
}

class PortableRestoreInspector {
  final PortableArchiveVerifier verifier;
  const PortableRestoreInspector({this.verifier = const PortableArchiveVerifier()});

  Future<PortableStagedRestore> inspectAndStage({
    required File backupFile,
    required String passphrase,
    required Directory stagingDirectory,
    required String expectedAccountBinding,
    Future<bool> Function()? isCancelled,
  }) async {
    if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
    await stagingDirectory.create(recursive: true);
    try {
      final decrypted = await readPortableBackupArchive(
        backupFile: backupFile,
        passphrase: passphrase,
        stagingDirectory: stagingDirectory,
      );
      if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
      final verification = verifier.verify(decrypted);
      final manifest = verification.manifest;
      if (manifest.accountBinding != expectedAccountBinding) {
        throw const PortableRestoreAccountMismatch();
      }
      manifest.validate(requireComplete: true);
      final archive = ZipDecoder().decodeBytes(decrypted.readAsBytesSync(), verify: true);
      final sections = <String, File>{};
      final attachments = <String, File>{};
      for (var i = 0; i < manifest.sections.length; i++) {
        final section = manifest.sections[i];
        final entry = archive.findFile(section.path);
        if (entry == null) throw FormatException('missing section ${section.name}');
        final file = File('${stagingDirectory.path}${Platform.pathSeparator}section-$i.ndjson');
        await file.writeAsBytes(entry.readBytes()!, flush: true);
        sections[section.name] = file;
      }
      for (var i = 0; i < manifest.attachments.length; i++) {
        final attachment = manifest.attachments[i];
        final entry = archive.findFile(attachment.path);
        if (entry == null) throw FormatException('missing attachment ${attachment.id}');
        final file = File('${stagingDirectory.path}${Platform.pathSeparator}attachment-$i.bin');
        await file.writeAsBytes(entry.readBytes()!, flush: true);
        attachments[attachment.id] = file;
      }
      return PortableStagedRestore(
        stagingDirectory: stagingDirectory,
        decryptedArchive: decrypted,
        verification: verification,
        sectionFiles: sections,
        attachmentFiles: attachments,
      );
    } catch (_) {
      try {
        if (await stagingDirectory.exists()) await stagingDirectory.delete(recursive: true);
      } on FileSystemException {
        // Keep the validation/decryption error.
      }
      rethrow;
    }
  }
}

Stream<Map<String, dynamic>> readPortableSection(File file, {int maxLineBytes = 4 * 1024 * 1024}) async* {
  await for (final line in file.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
    if (utf8.encode(line).length > maxLineBytes) throw PortableBackupLimitExceeded('NDJSON record exceeds restore limit');
    final value = jsonDecode(line);
    if (value is! Map<String, dynamic>) throw const FormatException('portable section row must be an object');
    yield value;
  }
}

enum PortableRestoreSessionState { staged, serverCommitted, localApplying, committed, failed }

class PortableRestoreSession {
  final String sessionId;
  final String backupId;
  final String idempotencyKey;
  final String stagingPath;
  final PortableRestoreSessionState state;
  final String? failure;
  const PortableRestoreSession({required this.sessionId, required this.backupId, required this.idempotencyKey, required this.stagingPath, required this.state, required this.failure});
}

abstract interface class PortableRestoreSessionStore {
  Future<PortableRestoreSession?> loadByIdempotencyKey(String key);
  Future<void> save(PortableRestoreSession session);
}

class InMemoryPortableRestoreSessionStore implements PortableRestoreSessionStore {
  final _sessions = <String, PortableRestoreSession>{};
  @override
  Future<PortableRestoreSession?> loadByIdempotencyKey(String key) async => _sessions[key];
  @override
  Future<void> save(PortableRestoreSession session) async => _sessions[session.idempotencyKey] = session;
}

Future<PortableRestoreSession> loadOrCreatePortableRestoreSession({
  required PortableRestoreSessionStore store,
  required String sessionId,
  required String backupId,
  required String idempotencyKey,
  required String stagingPath,
}) async {
  final existing = await store.loadByIdempotencyKey(idempotencyKey);
  if (existing != null) {
    if (existing.backupId != backupId) throw const FormatException('idempotency key belongs to another backup');
    return existing;
  }
  final session = PortableRestoreSession(sessionId: sessionId, backupId: backupId, idempotencyKey: idempotencyKey, stagingPath: stagingPath, state: PortableRestoreSessionState.staged, failure: null);
  await store.save(session);
  return session;
}
