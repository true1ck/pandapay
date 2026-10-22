import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';

/// The archive tests use a plain identity copy of the encryptor interface so
/// they stay fast; the roundtrip test exercises the real crypto envelope.
class IdentityEncryptor implements PortableBackupEncryptor {
  const IdentityEncryptor();

  @override
  Future<void> encryptFile({
    required File plaintextArchive,
    required File destination,
    required String passphrase,
    Future<bool> Function()? isCancelled,
  }) async {
    await destination.parent.create(recursive: true);
    await plaintextArchive.copy(destination.path);
  }
}

void main() {
  late Directory staging;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('portable-archive-');
  });

  tearDown(() async {
    // Windows keeps file handles briefly after zip.closeSync(); retry so a
    // locked file never turns into a failing teardown.
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

  String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

  PortableBackupSection sectionOf(String name, List<int> bytes) =>
      PortableBackupSection(
        name: name,
        path: 'sections/$name.ndjson',
        recordCount: utf8.decode(bytes).trim().split('\n').length,
        byteLength: bytes.length,
        sha256: digestOf(bytes),
      );

  List<int> cardsBytes() => utf8.encode('{"id":"card-1"}\n{"id":"card-2"}\n');
  List<int> transactionsBytes() => utf8.encode('{"id":"txn-1","card_id":"card-1"}\n');

  Map<String, File> stageFiles(Map<String, List<int>> sections) => {
        for (final entry in sections.entries)
          entry.key: File('${staging.path}${Platform.pathSeparator}stage-${entry.key}.ndjson')
            ..writeAsBytesSync(entry.value),
      };

  PortableBackupManifest manifestFor({
    required List<PortableBackupSection> sections,
    List<PortableBackupAttachment> attachments = const [],
    bool complete = true,
  }) =>
      PortableBackupManifest(
        formatVersion: 1,
        schemaVersion: 'server-v1+local-v1',
        backupId: '11111111-2222-3333-4444-555555555555',
        accountBinding: 'profile-alpha',
        createdAt: DateTime.utc(2026, 10, 23, 9),
        snapshotAt: DateTime.utc(2026, 10, 23, 9),
        appVersion: 'app-test',
        serverVersion: 'server-test',
        complete: complete,
        serverRevision: 'tx-42-1',
        sections: sections,
        attachments: attachments,
        requiredCapabilities: const [],
        declaredExclusions: const ['device_id', 'push_token'],
      );

  test('writer produces an archive the independent verifier accepts', () async {
    final sections = {'cards': cardsBytes(), 'transactions': transactionsBytes()};
    final manifest = manifestFor(sections: [
      sectionOf('cards', sections['cards']!),
      sectionOf('transactions', sections['transactions']!),
    ]);
    final output = File('${staging.path}${Platform.pathSeparator}backup.zip');

    await const PortableArchiveWriter(encryptor: IdentityEncryptor()).write(
      manifest: manifest,
      sectionFiles: stageFiles(sections),
      attachments: const [],
      output: output,
      passphrase: 'password',
      stagingDirectory: staging,
    );

    final result = const PortableArchiveVerifier().verify(output);
    expect(result.manifest.backupId, manifest.backupId);
    expect(
      result.manifest.sections.map((s) => s.name),
      unorderedEquals(['cards', 'transactions']),
    );
    expect(result.entryCount, 3);
  });

  test('writer rejects staged bytes whose digest betrays the manifest', () async {
    final sections = {'cards': cardsBytes()};
    final manifest = manifestFor(sections: [
      PortableBackupSection(
        name: 'cards',
        path: 'sections/cards.ndjson',
        recordCount: 1,
        byteLength: sections['cards']!.length,
        sha256: '0' * 64,
      ),
    ]);
    final output = File('${staging.path}${Platform.pathSeparator}backup.zip');
    await expectLater(
      const PortableArchiveWriter(encryptor: IdentityEncryptor()).write(
        manifest: manifest,
        sectionFiles: stageFiles(sections),
        attachments: const [],
        output: output,
        passphrase: 'password',
        stagingDirectory: staging,
      ),
      throwsFormatException,
    );
  });

  test('writer rejects staged files whose length mismatches the manifest', () async {
    final sections = {'cards': cardsBytes()};
    final manifest = manifestFor(sections: [
      PortableBackupSection(
        name: 'cards',
        path: 'sections/cards.ndjson',
        recordCount: 1,
        byteLength: sections['cards']!.length + 5,
        sha256: digestOf(sections['cards']!),
      ),
    ]);
    final output = File('${staging.path}${Platform.pathSeparator}backup.zip');
    await expectLater(
      const PortableArchiveWriter(encryptor: IdentityEncryptor()).write(
        manifest: manifest,
        sectionFiles: stageFiles(sections),
        attachments: const [],
        output: output,
        passphrase: 'password',
        stagingDirectory: staging,
      ),
      throwsFormatException,
    );
  });

  test('writer honours cancellation and leaves no final artifact behind', () async {
    final sections = {'cards': cardsBytes()};
    final manifest = manifestFor(sections: [sectionOf('cards', sections['cards']!)]);
    final output = File('${staging.path}${Platform.pathSeparator}backup.zip');
    await expectLater(
      const PortableArchiveWriter(encryptor: IdentityEncryptor()).write(
        manifest: manifest,
        sectionFiles: stageFiles(sections),
        attachments: const [],
        output: output,
        passphrase: 'password',
        stagingDirectory: staging,
        isCancelled: () async => true,
      ),
      throwsA(isA<PortableBackupCancelled>()),
    );
    expect(await output.exists(), isFalse);
  });

  test('writer refuses an incomplete manifest', () async {
    final sections = {'cards': cardsBytes()};
    final manifest = manifestFor(sections: [sectionOf('cards', sections['cards']!)], complete: false);
    await expectLater(
      const PortableArchiveWriter(encryptor: IdentityEncryptor()).write(
        manifest: manifest,
        sectionFiles: stageFiles(sections),
        attachments: const [],
        output: File('${staging.path}${Platform.pathSeparator}backup.zip'),
        passphrase: 'password',
        stagingDirectory: staging,
      ),
      throwsFormatException,
    );
  });

  test('archive path validation rejects every unsafe shape', () {
    final badPaths = <String>[
      'sections/../cards.ndjson',
      '/absolute/section',
      'windows\\path',
      'C:/drive/section',
      'sections//section',
      'a/b/c/d/e/f/g/h/i/too-deep',
      'ünicode-section',
      '',
    ];
    for (final candidate in badPaths) {
      expect(
        () => validatePortableArchivePath(candidate),
        throwsFormatException,
        reason: candidate,
      );
    }
  });

  test('verifier rejects a zip whose section bytes betray their digest', () async {
    final cards = cardsBytes();
    final manifestForBadDigest = manifestFor(sections: [sectionOf('cards', cards)])
        .toJson()
        .cast<String, dynamic>();
    manifestForBadDigest['sections'] = [
      {
        ...(manifestForBadDigest['sections'] as List).first.cast<String, dynamic>(),
        'sha256': '1' * 64,
      },
    ];
    final whenBytes = utf8.encode(jsonEncode(manifestForBadDigest));
    final encoder = ZipEncoder();
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('manifest.json', whenBytes))
      ..addFile(ArchiveFile.bytes('sections/cards.ndjson', cards));
    final bytes = encoder.encode(archive);
    final bad = File('${staging.path}${Platform.pathSeparator}bad.zip')..writeAsBytesSync(bytes);

    expect(
      () => const PortableArchiveVerifier().verify(bad),
      throwsFormatException,
    );
  });

  test('verifier rejects an archive with an undeclared entry', () async {
    final cards = cardsBytes();
    final manifestBytes = utf8.encode(
      jsonEncode(manifestFor(sections: [sectionOf('cards', cards)]).toJson()),
    );
    final encoder = ZipEncoder();
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('manifest.json', manifestBytes))
      ..addFile(ArchiveFile.bytes('sections/cards.ndjson', cards))
      ..addFile(ArchiveFile.bytes('attachments/smuggled.bin', [1, 2, 3]));
    final bytes = encoder.encode(archive);
    final bad = File('${staging.path}${Platform.pathSeparator}bad.zip')..writeAsBytesSync(bytes);
    expect(
      () => const PortableArchiveVerifier().verify(bad),
      throwsFormatException,
    );
  });

  test('verifier rejects an archive missing its manifest', () async {
    final encoder = ZipEncoder();
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('sections/orphan.ndjson', cardsBytes()));
    final bytes = encoder.encode(archive);
    final bad = File('${staging.path}${Platform.pathSeparator}bad.zip')..writeAsBytesSync(bytes);
    expect(
      () => const PortableArchiveVerifier().verify(bad),
      throwsFormatException,
    );
  });
}

