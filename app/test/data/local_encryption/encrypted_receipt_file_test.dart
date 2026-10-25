import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/portable_backup/private_temporary_workspace.dart';
import 'package:pandapay/data/secure_storage/encrypted_receipt_file.dart';

void main() {
  late Directory root;
  late EncryptedReceiptFileCodec codec;
  final key = SecretKey(List<int>.generate(32, (i) => i));
  final otherKey = SecretKey(List<int>.generate(32, (i) => 255 - i));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pandapay-receipt-');
    codec = EncryptedReceiptFileCodec(maxPlaintextBytes: 1024);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<Uint8List> encode() => codec.encrypt(
    plaintext: Uint8List.fromList(List<int>.generate(128, (i) => i)),
    key: key,
    accountNamespace: 'account-A',
    attachmentId: 'receipt-1',
    keyVersion: 7,
  );

  Future<Uint8List> decode(
    List<int> encrypted, {
    SecretKey? withKey,
    String? account,
    String? id,
    int? version,
  }) => codec.decrypt(
    encrypted: encrypted,
    key: withKey ?? key,
    accountNamespace: account ?? 'account-A',
    attachmentId: id ?? 'receipt-1',
    expectedKeyVersion: version ?? 7,
  );

  group('EncryptedReceiptFileCodec', () {
    test('round trips and authenticates account, ID and key version', () async {
      final encrypted = await encode();
      final encryptedAgain = await encode();
      expect(encrypted.sublist(9, 21), isNot(encryptedAgain.sublist(9, 21)));
      expect(encrypted, isNot(List<int>.generate(128, (i) => i)));
      expect(await decode(encrypted), List<int>.generate(128, (i) => i));
      await expectLater(
        decode(encrypted, account: 'account-B'),
        throwsFormatException,
      );
      await expectLater(
        decode(encrypted, id: 'receipt-2'),
        throwsFormatException,
      );
      await expectLater(
        decode(encrypted, withKey: otherKey),
        throwsFormatException,
      );
      await expectLater(decode(encrypted, version: 8), throwsFormatException);
    });

    test(
      'rejects tampering, unknown format, truncation and oversized input',
      () async {
        final encrypted = await encode();
        final changed = Uint8List.fromList(encrypted)
          ..[EncryptedReceiptFileCodec.headerLength] ^= 1;
        await expectLater(decode(changed), throwsFormatException);
        final unknown = Uint8List.fromList(encrypted)..[4] = 99;
        await expectLater(decode(unknown), throwsFormatException);
        await expectLater(
          decode(encrypted.sublist(0, encrypted.length - 1)),
          throwsFormatException,
        );
        await expectLater(
          codec.decrypt(
            encrypted: List<int>.filled(
              EncryptedReceiptFileCodec.headerLength +
                  1024 +
                  EncryptedReceiptFileCodec.tagLength +
                  1,
              1,
            ),
            key: key,
            accountNamespace: 'account-A',
            attachmentId: 'receipt-1',
            expectedKeyVersion: 7,
          ),
          throwsFormatException,
        );
        await expectLater(
          codec.encrypt(
            plaintext: List<int>.filled(1025, 0),
            key: key,
            accountNamespace: 'account-A',
            attachmentId: 'receipt-1',
            keyVersion: 7,
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('EncryptedReceiptFileStore', () {
    test(
      'exclusive encrypted copy verifies and preserves its only readable source',
      () async {
        final source = File('${root.path}/picked.jpg');
        final destination = File('${root.path}/stored.receipt');
        final bytes = Uint8List.fromList(
          List<int>.generate(220, (i) => (i * 13) & 0xff),
        );
        await source.writeAsBytes(bytes, flush: true);
        final store = EncryptedReceiptFileStore(codec: codec);
        await store.copyEncrypted(
          source: source,
          destination: destination,
          key: key,
          accountNamespace: 'account-A',
          attachmentId: 'receipt-1',
          keyVersion: 7,
        );
        expect(await source.readAsBytes(), bytes);
        expect(await destination.readAsBytes(), isNot(bytes));
        await expectLater(
          store.copyEncrypted(
            source: source,
            destination: destination,
            key: key,
            accountNamespace: 'account-A',
            attachmentId: 'receipt-1',
            keyVersion: 7,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await source.readAsBytes(), bytes);
        expect(
          await EncryptedReceiptFileCodec().decrypt(
            encrypted: await destination.readAsBytes(),
            key: key,
            accountNamespace: 'account-A',
            attachmentId: 'receipt-1',
            expectedKeyVersion: 7,
          ),
          bytes,
        );
      },
    );

    test(
      'refuses symlink source and symlink destination without touching targets',
      () async {
        final outside = File('${root.path}/outside.jpg')
          ..writeAsStringSync('keep-me');
        final sourceLink = File('${root.path}/source-link.jpg');
        await Link(sourceLink.path).create(outside.path);
        final store = EncryptedReceiptFileStore(codec: codec);
        await expectLater(
          store.copyEncrypted(
            source: sourceLink,
            destination: File('${root.path}/out.enc'),
            key: key,
            accountNamespace: 'account-A',
            attachmentId: 'receipt-1',
            keyVersion: 7,
          ),
          throwsA(isA<FileSystemException>()),
        );
        final source = File('${root.path}/source.jpg')
          ..writeAsStringSync('photo');
        final destinationLink = File('${root.path}/destination.enc');
        await Link(destinationLink.path).create(outside.path);
        await expectLater(
          store.copyEncrypted(
            source: source,
            destination: destinationLink,
            key: key,
            accountNamespace: 'account-A',
            attachmentId: 'receipt-1',
            keyVersion: 7,
          ),
          throwsA(isA<FileSystemException>()),
        );
        final linkedDirectory = Directory('${root.path}/linked-directory');
        await Link(linkedDirectory.path).create(root.path);
        await expectLater(
          store.copyEncrypted(
            source: source,
            destination: File('${linkedDirectory.path}/escaped.enc'),
            key: key,
            accountNamespace: 'account-A',
            attachmentId: 'receipt-1',
            keyVersion: 7,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await File('${root.path}/escaped.enc').exists(), isFalse);
        expect(await outside.readAsString(), 'keep-me');
        expect(await source.readAsString(), 'photo');
      },
    );

    test(
      'scoped decryption writes only inside caller private workspace',
      () async {
        final encrypted = await encode();
        final encryptedFile = File('${root.path}/copy.enc')
          ..writeAsBytesSync(encrypted);
        final workspace = await PrivateTemporaryWorkspace.create(root);
        try {
          final clear = await EncryptedReceiptFileStore(codec: codec)
              .decryptToPrivateWorkspace(
                encryptedFile: encryptedFile,
                workspace: workspace,
                filename: 'ocr-input.jpg',
                key: key,
                accountNamespace: 'account-A',
                attachmentId: 'receipt-1',
                keyVersion: 7,
              );
          expect(clear.parent.path, workspace.directory.path);
          expect(await clear.readAsBytes(), List<int>.generate(128, (i) => i));
        } finally {
          expect(await workspace.cleanup(), isTrue);
        }
      },
    );

    test(
      'failed scoped paths preserve preexisting files and symlink targets',
      () async {
        final workspace = await PrivateTemporaryWorkspace.create(root);
        final store = EncryptedReceiptFileStore(codec: codec);
        final encryptedFile = File('${root.path}/scope.enc')
          ..writeAsBytesSync(await encode());
        try {
          final existing = workspace.file('already-there.jpg');
          await existing.writeAsString('keep-existing');
          await expectLater(
            store.decryptToPrivateWorkspace(
              encryptedFile: encryptedFile,
              workspace: workspace,
              filename: 'already-there.jpg',
              key: key,
              accountNamespace: 'account-A',
              attachmentId: 'receipt-1',
              keyVersion: 7,
            ),
            throwsA(isA<FileSystemException>()),
          );
          expect(await existing.readAsString(), 'keep-existing');

          final external = File('${root.path}/external.jpg')
            ..writeAsStringSync('keep-target');
          final linked = Link(workspace.file('linked.jpg').path);
          await linked.create(external.path);
          await expectLater(
            store.decryptToPrivateWorkspace(
              encryptedFile: encryptedFile,
              workspace: workspace,
              filename: 'linked.jpg',
              key: key,
              accountNamespace: 'account-A',
              attachmentId: 'receipt-1',
              keyVersion: 7,
            ),
            throwsA(isA<FileSystemException>()),
          );
          await expectLater(
            store.decryptToPrivateWorkspace(
              encryptedFile: encryptedFile,
              workspace: workspace,
              filename: '../external.jpg',
              key: key,
              accountNamespace: 'account-A',
              attachmentId: 'receipt-1',
              keyVersion: 7,
            ),
            throwsFormatException,
          );
          expect(await external.readAsString(), 'keep-target');
        } finally {
          expect(await workspace.cleanup(), isTrue);
        }
      },
    );
  });
}
