import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'canonical_ndjson.dart';
import 'portable_backup_models.dart';
import 'portable_restore.dart';

abstract interface class PortableLocalRestoreWriter {
  Future<void> beginFreshNamespace();
  Future<void> insertPortableRows(String sectionName, Stream<Map<String, dynamic>> rows);
  Future<void> insertHistoricalSmsRows(String sectionName, Stream<Map<String, dynamic>> rows);
  Future<void> installAttachment({required PortableBackupAttachment metadata, required File stagedFile});
  Future<void> rebuildDeclaredProjections();
  Future<void> commit();
  Future<void> rollback();
}

class PortableRestoreServerCommit {
  final String serverRevision;
  final bool committed;
  const PortableRestoreServerCommit({required this.serverRevision, required this.committed});
}

class PortableRestoreNotServerCommitted implements Exception {
  const PortableRestoreNotServerCommitted();
  @override
  String toString() => 'local finalization requires a successful server commit';
}

class PortableReconciliationMismatch {
  final String path;
  final String reason;
  const PortableReconciliationMismatch(this.path, this.reason);
}

class PortableReconciliationResult {
  final List<PortableReconciliationMismatch> mismatches;
  const PortableReconciliationResult(this.mismatches);
  bool get isMatch => mismatches.isEmpty;
}

class PortableRestoreReconciliationException implements Exception {
  final PortableReconciliationResult result;
  const PortableRestoreReconciliationException(this.result);
  @override
  String toString() => 'portable restore reconciliation failed: ${jsonEncode([
        for (final mismatch in result.mismatches) {'path': mismatch.path, 'reason': mismatch.reason},
      ])}';
}

class PortableRestoreLocalResult {
  final int sectionRows;
  final int attachments;
  final PortableReconciliationResult reconciliation;
  const PortableRestoreLocalResult({required this.sectionRows, required this.attachments, required this.reconciliation});
}

class PortableLocalRestoreFinalizer {
  final PortableLocalRestoreWriter writer;
  final PortableRestoreTargetInspector target;
  const PortableLocalRestoreFinalizer({required this.writer, required this.target});

  Future<PortableRestoreLocalResult> finalize({
    required PortableStagedRestore staged,
    required PortableRestoreServerCommit serverCommit,
    Future<bool> Function()? isCancelled,
  }) async {
    if (!serverCommit.committed) throw const PortableRestoreNotServerCommitted();
    await requireFreshPortableNamespace(target);
    var rows = 0;
    var attachments = 0;
    try {
      await writer.beginFreshNamespace();
      for (final section in staged.verification.manifest.sections) {
        if (await isCancelled?.call() == true) {
          throw const PortableBackupCancelled();
        }
        final stream = readPortableSection(staged.sectionFiles[section.name]!);
        final counted = _count(stream, () => rows++);
        if (_isHistoricalSms(section.name)) {
          await writer.insertHistoricalSmsRows(section.name, counted);
        } else {
          await writer.insertPortableRows(section.name, counted);
        }
      }
      for (final metadata in staged.verification.manifest.attachments) {
        if (await isCancelled?.call() == true) {
          throw const PortableBackupCancelled();
        }
        final file = staged.attachmentFiles[metadata.id];
        if (file == null) throw FormatException('staged attachment missing ${metadata.id}');
        await writer.installAttachment(metadata: metadata, stagedFile: file);
        attachments++;
      }
      await writer.rebuildDeclaredProjections();
      final reconciliation = await reconcileStagedRestore(staged);
      if (!reconciliation.isMatch) throw PortableRestoreReconciliationException(reconciliation);
      await writer.commit();
      return PortableRestoreLocalResult(sectionRows: rows, attachments: attachments, reconciliation: reconciliation);
    } catch (_) {
      await writer.rollback();
      rethrow;
    }
  }

  static bool _isHistoricalSms(String name) => name.toLowerCase().contains('sms') || name.toLowerCase().contains('provenance');

  static Stream<Map<String, dynamic>> _count(Stream<Map<String, dynamic>> source, void Function() onRow) async* {
    await for (final row in source) {
      onRow();
      yield row;
    }
  }
}

Future<PortableReconciliationResult> reconcileStagedRestore(PortableStagedRestore staged) async {
  final mismatches = <PortableReconciliationMismatch>[];
  for (final section in staged.verification.manifest.sections) {
    final file = staged.sectionFiles[section.name];
    if (file == null) {
      mismatches.add(PortableReconciliationMismatch(section.name, 'missing section file'));
      continue;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != section.byteLength) {
      mismatches.add(PortableReconciliationMismatch(section.name, 'byte count mismatch'));
    } else if (sha256.convert(bytes).toString() != section.sha256) {
      mismatches.add(PortableReconciliationMismatch(section.name, 'SHA-256 mismatch'));
    }
    var count = 0;
    await for (final _ in readPortableSection(file)) {
      count++;
    }
    if (count != section.recordCount) {
      mismatches.add(PortableReconciliationMismatch(section.name, 'record count mismatch'));
    }
  }
  for (final attachment in staged.verification.manifest.attachments) {
    final file = staged.attachmentFiles[attachment.id];
    if (file == null) {
      mismatches.add(PortableReconciliationMismatch(attachment.id, 'missing attachment'));
      continue;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != attachment.byteLength || sha256.convert(bytes).toString() != attachment.sha256) {
      mismatches.add(PortableReconciliationMismatch(attachment.id, 'attachment hash/length mismatch'));
    }
  }
  return PortableReconciliationResult(mismatches);
}
