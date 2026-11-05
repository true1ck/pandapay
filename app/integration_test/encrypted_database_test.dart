import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/database_key.dart';
import 'package:sqlite3/sqlite3.dart';

/// Real SQLCipher check on an iOS simulator/device and an Android emulator:
/// `flutter test integration_test/encrypted_database_test.dart -d <device>`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('database file is unreadable without the key', (_) async {
    ensureSqlCipherLoaded();
    final dir = await Directory.systemTemp.createTemp('cipher');
    final path = '${dir.path}/t.sqlite';
    final key = 'ab' * 32;
    final db = sqlite3.open(path);
    applyCipherKey(db, key);
    db.execute('CREATE TABLE t(v TEXT)');
    db.execute("INSERT INTO t VALUES ('secret')");
    db.dispose();
    final bytes = File(path).readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(15)), isNot('SQLite format 3'));
    expect(String.fromCharCodes(bytes), isNot(contains('secret')));
    final wrong = sqlite3.open(path);
    expect(
      () => applyCipherKey(wrong, 'cd' * 32),
      throwsA(isA<SqliteException>()),
    );
    wrong.dispose();
    await dir.delete(recursive: true);
  });

  testWidgets(
    'AppDatabase round-trips through its own key and rejects another',
    (_) async {
      final dir = await Directory.systemTemp.createTemp('appdb');
      final path = '${dir.path}/pandapay.sqlite';
      final first = AppDatabase.openFile(path, keyHex: 'ab' * 32);
      first.saveProfileDisplayName('user:synthetic', 'Synthetic Name');
      first.close();
      final again = AppDatabase.openFile(path, keyHex: 'ab' * 32);
      expect(again.profileDisplayName('user:synthetic'), 'Synthetic Name');
      again.close();
      expect(
        () => AppDatabase.openFile(path, keyHex: 'cd' * 32),
        throwsA(isA<SqliteException>()),
      );
      await dir.delete(recursive: true);
    },
  );
}
