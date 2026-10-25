// Run only in an isolated test package with synthetic temporary files. This
// entrypoint does not initialize the application, accounts or any providers.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/account_recovery_local_snapshot.dart';
import 'package:sqlite3/sqlite3.dart';

Future<bool> _independentWriterIsBlocked(String location) => Isolate.run(() {
  final other = sqlite3.open(location);
  try {
    other.execute('PRAGMA busy_timeout=0');
    try {
      other.execute(
        "INSERT INTO profile_name_cache VALUES('user:native-test','foreign')",
      );
      return false;
    } on SqliteException catch (error) {
      return error.resultCode == 5; // SQLITE_BUSY from the native writer lease.
    }
  } finally {
    other.dispose();
  }
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native writer lease blocks another isolate and restores rollback', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('pp-native-fence-');
    final location = '${directory.path}/synthetic.sqlite';
    final owner = AppDatabase.openFile(location);
    try {
      await expectLater(
        owner.withRecoveryDatabase((lease) async {
          expect(await _independentWriterIsBlocked(location), isTrue);
          expect(
            () => owner.db.execute(
              "INSERT INTO profile_name_cache VALUES('user:native-test','normal')",
            ),
            throwsA(isA<SqliteException>()),
          );
          lease.database.execute(
            "INSERT INTO profile_name_cache VALUES('user:native-test','rolled-back')",
          );
          throw StateError('Synthetic interrupted operation');
        }),
        throwsStateError,
      );
      expect(owner.db.select('SELECT * FROM profile_name_cache'), isEmpty);
      owner.saveProfileDisplayName(
        'user:native-test',
        'Preserved after rollback',
      );
      expect(
        owner.profileDisplayName('user:native-test'),
        'Preserved after rollback',
      );
    } finally {
      owner.close();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('committed native SQLite data survives closing and reopening', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'pp-native-reopen-',
    );
    final location = '${directory.path}/synthetic.sqlite';
    final owner = AppDatabase.openFile(location);
    try {
      await owner.withRecoveryDatabase((lease) async {
        lease.database.execute(
          "INSERT INTO profile_name_cache VALUES('user:native-test','committed')",
        );
      });
    } finally {
      owner.close();
    }
    final reopened = AppDatabase.openFile(location);
    try {
      expect(reopened.profileDisplayName('user:native-test'), 'committed');
    } finally {
      reopened.close();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('native receipt cleanup preserves references and gallery files', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'pp-native-receipt-',
    );
    final owner = AppDatabase.openFile('${directory.path}/synthetic.sqlite');
    final attachments = Directory('${directory.path}/attachments')
      ..createSync();
    final owned = Directory('${attachments.path}/account_recovery_receipts')
      ..createSync();
    final orphanName = 'receipt-${'a' * 32}.bin';
    final referenceName = 'receipt-${'b' * 32}.bin';
    final orphan = File('${owned.path}/$orphanName')..writeAsBytesSync([1]);
    final referenced = File('${owned.path}/$referenceName')
      ..writeAsBytesSync([2]);
    final gallery = File('${directory.path}/gallery-original.jpg')
      ..writeAsBytesSync([3]);
    File('${owned.path}/.receipt-intents.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'files': [orphanName, referenceName],
      }),
      flush: true,
    );
    // A reference in another namespace/cache is conservatively retained too.
    owner.saveProfileDisplayName('user:another-native-account', referenceName);
    try {
      final removed = await owner.withRecoveryDatabase(
        (lease) => AccountRecoveryLocalSnapshot.reconcileOrphanedReceipts(
          lease: lease,
          attachmentsDirectory: attachments,
        ),
      );
      expect(removed, 1);
      expect(await orphan.exists(), isFalse);
      expect(await referenced.readAsBytes(), [2]);
      expect(await gallery.readAsBytes(), [3]);
    } finally {
      owner.close();
      await directory.delete(recursive: true);
    }
  });
}
