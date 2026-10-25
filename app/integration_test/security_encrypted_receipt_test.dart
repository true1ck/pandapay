import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pandapay/data/portable_backup/private_temporary_workspace.dart';
import 'package:pandapay/data/secure_storage/encrypted_database_copy.dart';
import 'package:pandapay/data/secure_storage/encrypted_receipt_file.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native receipt copy authenticates account and keeps original through scoped viewing',
    (tester) async {
      final owned = await AppPrivateDatabaseCopyDirectory.documents(
        subdirectory:
            'receipt-fixture-${DateTime.now().microsecondsSinceEpoch}',
      );
      final source = File('${owned.directory.path}/original.bin'),
          encrypted = File('${owned.directory.path}/encrypted.pprc');
      final bytes = List<int>.generate(1024, (i) => i % 256),
          key = SecretKey(
            List.generate(32, (_) => Random.secure().nextInt(256)),
          );
      final workspace = await PrivateTemporaryWorkspace.create(owned.directory);
      try {
        await source.writeAsBytes(bytes, flush: true);
        final store = EncryptedReceiptFileStore();
        await store.copyEncrypted(
          source: source,
          destination: encrypted,
          key: key,
          accountNamespace: 'user:fixture',
          attachmentId: 'receipt-fixture',
          keyVersion: 1,
        );
        expect(source.readAsBytesSync(), bytes);
        expect(encrypted.readAsBytesSync(), isNot(bytes));
        final viewed = await store.decryptToPrivateWorkspace(
          encryptedFile: encrypted,
          workspace: workspace,
          filename: 'view.bin',
          key: key,
          accountNamespace: 'user:fixture',
          attachmentId: 'receipt-fixture',
          keyVersion: 1,
        );
        expect(viewed.readAsBytesSync(), bytes);
        await expectLater(
          store.decryptToPrivateWorkspace(
            encryptedFile: encrypted,
            workspace: workspace,
            filename: 'wrong.bin',
            key: key,
            accountNamespace: 'user:other',
            attachmentId: 'receipt-fixture',
            keyVersion: 1,
          ),
          throwsFormatException,
        );
        expect(await workspace.file('wrong.bin').exists(), false);
        await expectLater(
          store.decryptToPrivateWorkspace(
            encryptedFile: encrypted,
            workspace: workspace,
            filename: 'view.bin',
            key: key,
            accountNamespace: 'user:fixture',
            attachmentId: 'receipt-fixture',
            keyVersion: 1,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(viewed.readAsBytesSync(), bytes);
      } finally {
        expect(await workspace.cleanup(), true);
        await owned.directory.delete(recursive: true);
      }
    },
  );
}
