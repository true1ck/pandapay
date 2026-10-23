import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/portable_backup/portable_archive.dart';
import 'package:pandapay/data/portable_backup/portable_backup_models.dart';
import 'package:pandapay/data/portable_backup/portable_restore.dart';
import 'package:pandapay/data/portable_backup/portable_restore_finalize.dart';

void main() {
  test('fresh target guard rejects populated namespace', () async {
    final target = _Target(const PortableFreshNamespaceState(hasPortableRows: true, hasAttachments: false));
    await expectLater(requireFreshPortableNamespace(target), throwsA(isA<PortablePopulatedTargetException>()));
  });

  test('idempotency key resumes same session and cannot switch backup', () async {
    final store = InMemoryPortableRestoreSessionStore();
    final first = await loadOrCreatePortableRestoreSession(store: store, sessionId: 's1', backupId: 'b1', idempotencyKey: 'k', stagingPath: 'p1');
    final resumed = await loadOrCreatePortableRestoreSession(store: store, sessionId: 's2', backupId: 'b1', idempotencyKey: 'k', stagingPath: 'p2');
    expect(resumed.sessionId, first.sessionId);
    await expectLater(loadOrCreatePortableRestoreSession(store: store, sessionId: 's3', backupId: 'b2', idempotencyKey: 'k', stagingPath: 'p3'), throwsA(isA<FormatException>()));
  });

  test('reconciliation catches changed staged bytes', () async {
    final dir = await Directory.systemTemp.createTemp('portable-restore-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/section.ndjson')..writeAsStringSync('{"id":"t"}\n');
    final manifest = PortableBackupManifest(
      formatVersion: 1, schemaVersion: 'v1', backupId: 'b1', accountBinding: 'a1',
      createdAt: DateTime.utc(2026), snapshotAt: DateTime.utc(2026), appVersion: '1', serverVersion: '1',
      complete: true, serverRevision: 'r',
      sections: const [PortableBackupSection(name: 'transactions', path: 'sections/transactions.ndjson', recordCount: 1, byteLength: 13, sha256: '0000000000000000000000000000000000000000000000000000000000000000')],
      attachments: const [], requiredCapabilities: const [], declaredExclusions: const [],
    );
    final result = await reconcileStagedRestore(PortableStagedRestore(
      stagingDirectory: dir, decryptedArchive: file,
      verification: PortableArchiveVerificationResult(manifest: manifest, expandedBytes: 0, entryCount: 1),
      sectionFiles: {'transactions': file}, attachmentFiles: const {},
    ));
    expect(result.isMatch, isFalse);
    expect(result.mismatches, isNotEmpty);
  });
}

class _Target implements PortableRestoreTargetInspector {
  final PortableFreshNamespaceState state;
  const _Target(this.state);
  @override
  Future<PortableFreshNamespaceState> inspectFreshNamespace() async => state;
}
