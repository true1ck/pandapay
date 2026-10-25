import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/secure_storage/encrypted_database_migration.dart';

void main() {
  test('journal persists progress and rejects backwards movement', () async {
    final dir = await Directory.systemTemp.createTemp('pandapay-encryption-');
    addTearDown(() => dir.delete(recursive: true));
    final journal = EncryptedMigrationJournal(
      File('${dir.path}/migration.json'),
      authenticationKey: List.filled(32, 7),
      binding: 'fixture',
      keyVersion: 1,
    );
    const copying = EncryptedMigrationState(
      phase: EncryptedMigrationPhase.copying,
      lastRowid: 10,
      copiedRows: 10,
      sourceDigest:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      destinationDigest: '',
    );
    await journal.create(copying);
    await expectLater(
      journal.create(copying),
      throwsA(isA<FileSystemException>()),
    );
    expect((await journal.read())!.lastRowid, 10);
    await journal.replace(
      const EncryptedMigrationState(
        phase: EncryptedMigrationPhase.verifying,
        lastRowid: 10,
        copiedRows: 10,
        sourceDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        destinationDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    );
    expect((await journal.read())!.phase, EncryptedMigrationPhase.verifying);
    await expectLater(journal.replace(copying), throwsStateError);
  });

  test('journal refuses a symlink path', () async {
    final dir = await Directory.systemTemp.createTemp('pandapay-encryption-');
    addTearDown(() => dir.delete(recursive: true));
    final real = Directory('${dir.path}/real')..createSync();
    final link = Link('${dir.path}/linked')..createSync(real.path);
    final journal = EncryptedMigrationJournal(
      File('${link.path}/migration.json'),
      authenticationKey: List.filled(32, 7),
      binding: 'fixture',
      keyVersion: 1,
    );
    await expectLater(
      journal.create(
        const EncryptedMigrationState(
          phase: EncryptedMigrationPhase.copying,
          lastRowid: 0,
          copiedRows: 0,
          sourceDigest:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          destinationDigest: '',
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
  test(
    'journal refuses oversized input, unknown fields and changed source',
    () async {
      final dir = await Directory.systemTemp.createTemp('pandapay-encryption-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/migration.json');
      final journal = EncryptedMigrationJournal(
        file,
        authenticationKey: List.filled(32, 7),
        binding: 'fixture',
        keyVersion: 1,
      );
      await file.writeAsString('x' * 4097);
      await expectLater(journal.read(), throwsFormatException);
      await file.delete();
      const start = EncryptedMigrationState(
        phase: EncryptedMigrationPhase.copying,
        lastRowid: 0,
        copiedRows: 0,
        sourceDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        destinationDigest: '',
      );
      await journal.create(start);
      await expectLater(
        journal.replace(
          const EncryptedMigrationState(
            phase: EncryptedMigrationPhase.copying,
            lastRowid: 1,
            copiedRows: 1,
            sourceDigest:
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            destinationDigest: '',
          ),
        ),
        throwsStateError,
      );
      expect(
        () => EncryptedMigrationState.parse('{"format":1,"extra":true}'),
        throwsFormatException,
      );
    },
  );
  test(
    'journal authenticates metadata, install binding, key version and content',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'pandapay-journal-auth-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/migration.json');
      final journal = EncryptedMigrationJournal(
        file,
        authenticationKey: List.filled(32, 7),
        binding: 'install-A',
        keyVersion: 1,
      );
      const state = EncryptedMigrationState(
        phase: EncryptedMigrationPhase.copying,
        lastRowid: 1,
        copiedRows: 1,
        sourceDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        destinationDigest: '',
      );
      await journal.create(state);
      for (final alternate in [
        EncryptedMigrationJournal(
          file,
          authenticationKey: List.filled(32, 8),
          binding: 'install-A',
          keyVersion: 1,
        ),
        EncryptedMigrationJournal(
          file,
          authenticationKey: List.filled(32, 7),
          binding: 'install-B',
          keyVersion: 1,
        ),
        EncryptedMigrationJournal(
          file,
          authenticationKey: List.filled(32, 7),
          binding: 'install-A',
          keyVersion: 2,
        ),
      ]) {
        await expectLater(alternate.read(), throwsFormatException);
        alternate.dispose();
      }
      final original = await file.readAsString();
      final envelope = jsonDecode(original);
      envelope['state']['copied_rows'] = 2;
      await file.writeAsString(jsonEncode(envelope));
      await expectLater(journal.read(), throwsFormatException);
      await file.writeAsString(original);
      expect((await journal.read())!.copiedRows, 1);
      journal.dispose();
      await expectLater(journal.read(), throwsStateError);
    },
  );
  test(
    'authenticated pending replacement resumes exactly, conflicting state is preserved',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'pandapay-journal-resume-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/migration.json');
      EncryptedMigrationJournal journal(File target) =>
          EncryptedMigrationJournal(
            target,
            authenticationKey: List.filled(32, 7),
            binding: 'install',
            keyVersion: 1,
          );
      const copy = EncryptedMigrationState(
        phase: EncryptedMigrationPhase.copying,
        lastRowid: 1,
        copiedRows: 1,
        sourceDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        destinationDigest: '',
      );
      const verify = EncryptedMigrationState(
        phase: EncryptedMigrationPhase.verifying,
        lastRowid: 1,
        copiedRows: 1,
        sourceDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        destinationDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final active = journal(file);
      await active.create(copy);
      final pending = journal(File('${file.path}.next'));
      await pending.create(copy);
      await pending.replace(verify);
      await expectLater(active.replace(copy), throwsStateError);
      expect((await active.read())!.phase, EncryptedMigrationPhase.copying);
      expect(await File('${file.path}.next').exists(), true);
      await active.replace(verify);
      expect((await active.read())!.phase, EncryptedMigrationPhase.verifying);
      expect(await File('${file.path}.next').exists(), false);
      active.dispose();
      pending.dispose();
    },
  );
}
