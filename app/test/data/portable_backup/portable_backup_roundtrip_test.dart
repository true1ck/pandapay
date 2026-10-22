import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';

/// Wave 1 export gate, data level: the real writer plus the real crypto
/// envelope produce a file the independent verifier accepts, and whose
/// decrypted sections match their manifest digests byte-for-byte.
void main() {
  late Directory staging;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('portable-roundtrip-');
  });

tearDown(() async {
    // Windows keeps file handles briefly after zips close; retry the teardown.
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (!await staging.exists()) return;
        await staging.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  test('real writer -> real envelope -> independent verification', () async {
    final staged = <String, File>{};
    final sections = <PortableBackupSection>[];
    for (final entry in {
      'cards': [
        {'id': 'card-1', 'nickname': 'Everyday'},
        {'id': 'card-2', 'nickname': 'Travel'},
      ],
      'transactions': [
        {'id': 'txn-1', 'card_id': 'card-1', 'amount_inr': '250.00'},
        {'id': 'txn-2', 'card_id': 'card-2', 'amount_inr': '125.50'},
      ],
    }.entries) {
      final bytes =
          utf8.encode('${entry.value.map(canonicalJsonEncode).join('\n')}\n');
      final file = File('${staging.path}${Platform.pathSeparator}stage-${entry.key}.ndjson')
        ..writeAsBytesSync(bytes);
      staged[entry.key] = file;
      sections.add(PortableBackupSection(
        name: entry.key,
        path: 'sections/${entry.key}.ndjson',
        recordCount: entry.value.length,
        byteLength: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      ));
    }

    final output = File('${staging.path}${Platform.pathSeparator}export.pandapay-backup');
    await const PortableArchiveWriter(
      encryptor: Argon2idSecretStreamEncryptor(),
    ).write(
      manifest: PortableBackupManifest(
        formatVersion: portableBackupFormatVersion,
        schemaVersion: 'server-v1+local-v1',
        backupId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        accountBinding: 'profile-alpha',
        createdAt: DateTime.utc(2026, 10, 23, 10),
        snapshotAt: DateTime.utc(2026, 10, 23, 10),
        appVersion: 'app-test',
        serverVersion: 'server-test',
        complete: true,
        serverRevision: 'tx-99-2',
        sections: sections,
        attachments: const [],
        requiredCapabilities: const [],
        declaredExclusions: const ['device_id', 'push_token', 'biometric_state'],
      ),
      sectionFiles: staged,
      attachments: const [],
      output: output,
      passphrase: 'wave-one-passphrase',
      stagingDirectory: staging,
    );

    final decrypted = await readPortableBackupArchive(
      backupFile: output,
      passphrase: 'wave-one-passphrase',
      stagingDirectory: staging,
    );

    final archive = ZipDecoder().decodeBytes(await decrypted.readAsBytes(), verify: true);
    final verification = const PortableArchiveVerifier().verify(decrypted);
    expect(verification.manifest.backupId, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
    expect(verification.manifest.accountBinding, 'profile-alpha');
    expect(verification.manifest.sections.length, 2);
    for (final section in verification.manifest.sections) {
      final entry = archive.files.firstWhere((f) => f.name == section.path);
      final bytes = entry.readBytes() as List<int>;
      expect(sha256.convert(bytes).toString(), section.sha256);
      expect(
        utf8.decode(bytes).trim().split('\n').length,
        section.recordCount,
      );
    }

    // Wrong passphrase must fail on the finished artifact.
    await expectLater(
      readPortableBackupArchive(
        backupFile: output,
        passphrase: 'not-the-passphrase',
        stagingDirectory: staging,
      ),
      throwsA(isA<PortableBackupPassphraseError>()),
    );
  });
}

