import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';

void main() {
  late Directory staging;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('portable-crypto-');
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

  File plaintextOf(int bytes) {
    final file = File('${staging.path}${Platform.pathSeparator}plain.bin');
    final random = Random(7);
    file.writeAsBytesSync(List<int>.generate(bytes, (_) => random.nextInt(256)));
    return file;
  }

  Future<File> encryptOf(File plaintext, String passphrase) async {
    final destination = File('${staging.path}${Platform.pathSeparator}out.pandapay-backup');
    await const Argon2idSecretStreamEncryptor().encryptFile(
      plaintextArchive: plaintext,
      destination: destination,
      passphrase: passphrase,
    );
    return destination;
  }

  test('small payload round-trips exactly', () async {
    final plaintext = plaintextOf(1234);
    final encrypted = await encryptOf(plaintext, 'correct horse');
    expect(encrypted.lengthSync(), greaterThan(68));

    final decrypted = await readPortableBackupArchive(
      backupFile: encrypted,
      passphrase: 'correct horse',
      stagingDirectory: staging,
    );
    expect(decrypted.readAsBytesSync(), plaintext.readAsBytesSync());
  });

  test('multi-frame payload round-trips across chunk boundaries', () async {
    final plaintext = plaintextOf(200_000);
    final encrypted = await encryptOf(plaintext, 'salt pepper');
    final decrypted = await readPortableBackupArchive(
      backupFile: encrypted,
      passphrase: 'salt pepper',
      stagingDirectory: staging,
    );
    expect(decrypted.readAsBytesSync(), plaintext.readAsBytesSync());

    final singleFrame = await encryptOf(plaintextOf(70_000), 'salt pepper');
    final singleDecrypted = await readPortableBackupArchive(
      backupFile: singleFrame,
      passphrase: 'salt pepper',
      stagingDirectory: staging,
    );
    expect(singleDecrypted.lengthSync(), 70_000);
  });

  test('wrong passphrase is rejected on first frame open', () async {
    final encrypted = await encryptOf(plaintextOf(512), 'alpha');
    await expectLater(
      readPortableBackupArchive(
        backupFile: encrypted,
        passphrase: 'beta',
        stagingDirectory: staging,
      ),
      throwsA(isA<PortableBackupPassphraseError>()),
    );
  });

  test('tampered ciphertext is rejected', () async {
    final encrypted = await encryptOf(plaintextOf(512), 'alpha');
    final bytes = encrypted.readAsBytesSync();
    bytes[68] = bytes[68] ^ 0x02;
    final tampered = File('${staging.path}${Platform.pathSeparator}tampered.fr');
    tampered.writeAsBytesSync(bytes);

    await expectLater(
      readPortableBackupArchive(
        backupFile: tampered,
        passphrase: 'alpha',
        stagingDirectory: staging,
      ),
      throwsA(isA<PortableBackupPassphraseError>()),
    );
  });

  test('truncated envelope is rejected', () async {
    final encrypted = await encryptOf(plaintextOf(4096), 'alpha');
    final truncated = File('${staging.path}${Platform.pathSeparator}truncated.pandapay-backup');
    truncated.writeAsBytesSync(List<int>.from(encrypted.readAsBytesSync())..removeLast());

    await expectLater(
      readPortableBackupArchive(
        backupFile: truncated,
        passphrase: 'alpha',
        stagingDirectory: staging,
      ),
      throwsA(anyOf(
        isA<PortableBackupEnvelopeException>(),
        isA<PortableBackupPassphraseError>(),
      )),
    );
  });

  test('trailing unauthenticated bytes are rejected', () async {
    final encrypted = await encryptOf(plaintextOf(4096), 'alpha');
    final bytes = List<int>.from(encrypted.readAsBytesSync())..add(0x00);
    final trailing = File('${staging.path}${Platform.pathSeparator}trailing.pandapay-backup');
    trailing.writeAsBytesSync(bytes);

    await expectLater(
      readPortableBackupArchive(
        backupFile: trailing,
        passphrase: 'alpha',
        stagingDirectory: staging,
      ),
      throwsA(anyOf(
        isA<PortableBackupEnvelopeException>(),
        isA<PortableBackupPassphraseError>(),
      )),
    );
  });

  test('tampered header magic is rejected before any work', () async {
    final encrypted = await encryptOf(plaintextOf(64), 'alpha');
    final bytes = encrypted.readAsBytesSync();
    bytes[2] = 0x58;
    final magic = File('${staging.path}${Platform.pathSeparator}magic.pandapay-backup');
    magic.writeAsBytesSync(bytes);

    await expectLater(
      readPortableBackupArchive(
        backupFile: magic,
        passphrase: 'alpha',
        stagingDirectory: staging,
      ),
      throwsA(isA<PortableBackupEnvelopeException>()),
    );
  });

  test('header-only KDF parameters must match frozen v1 values', () async {
    final encrypted = await encryptOf(plaintextOf(64), 'alpha');
    final bytes = encrypted.readAsBytesSync();
    // KDF memory field sits at bytes 28..32; raise iterations at byte 36.
    bytes[36] = 3;
    final params = File('${staging.path}${Platform.pathSeparator}params.pandapay-backup');
    params.writeAsBytesSync(bytes);

    await expectLater(
      readPortableBackupArchive(
        backupFile: params,
        passphrase: 'alpha',
        stagingDirectory: staging,
      ),
      throwsA(isA<PortableBackupEnvelopeException>()),
    );
  });

  test('encryption output is randomized between runs', () async {
    final plaintext = plaintextOf(300);
    final first = await encryptOf(plaintext, 'alpha');
    final second = File('${staging.path}${Platform.pathSeparator}second.pandapay-backup');
    await const Argon2idSecretStreamEncryptor().encryptFile(
      plaintextArchive: plaintext,
      destination: second,
      passphrase: 'alpha',
    );
    // Same payload twice must not produce identical ciphertext bytes.
    expect(first.readAsBytesSync(), isNot(second.readAsBytesSync()));
  });
}

