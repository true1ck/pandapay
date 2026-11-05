import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/database_key.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// Host tests run on the system SQLite, which has no SQLCipher. When a
/// SQLCipher library is available on the Mac (set PANDAPAY_SQLCIPHER_LIB to a
/// libsqlcipher.dylib whose dependencies resolve, or install it with Homebrew)
/// these run the real encryption path; otherwise they are skipped and the
/// device test `integration_test/encrypted_database_test.dart` covers it.
String? _cipherLibrary() {
  final fromEnv = Platform.environment['PANDAPAY_SQLCIPHER_LIB'];
  final candidates = [?fromEnv, '/opt/homebrew/lib/libsqlcipher.dylib'];
  for (final path in candidates) {
    if (Platform.isMacOS && File(path).existsSync()) return path;
  }
  return null;
}

void main() {
  final library = _cipherLibrary();
  final skip = library == null ? 'no host SQLCipher library installed' : null;
  final key = 'ab' * 32;
  late Directory dir;

  setUpAll(() {
    if (library != null) {
      open.overrideFor(
        OperatingSystem.macOS,
        () => DynamicLibrary.open(library),
      );
    }
  });
  setUp(() async => dir = await Directory.systemTemp.createTemp('hostcipher'));
  tearDown(() => dir.delete(recursive: true));

  test('file is ciphertext and unreadable without or with the wrong key', () {
    final path = '${dir.path}/t.sqlite';
    final db = sqlite3.open(path);
    applyCipherKey(db, key);
    db.execute('CREATE TABLE t(v TEXT)');
    db.execute("INSERT INTO t VALUES ('synthetic-secret-value')");
    db.dispose();

    final bytes = File(path).readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(15)), isNot('SQLite format 3'));
    expect(
      String.fromCharCodes(bytes),
      isNot(contains('synthetic-secret-value')),
    );

    final wrong = sqlite3.open(path);
    expect(
      () => applyCipherKey(wrong, 'cd' * 32),
      throwsA(isA<SqliteException>()),
    );
    wrong.dispose();

    final unkeyed = sqlite3.open(path);
    expect(
      () => unkeyed.select('SELECT count(*) FROM sqlite_master'),
      throwsA(isA<SqliteException>()),
    );
    unkeyed.dispose();

    final right = sqlite3.open(path);
    applyCipherKey(right, key);
    expect(
      right.select('SELECT v FROM t').single['v'],
      'synthetic-secret-value',
    );
    right.dispose();
  }, skip: skip);

  test(
    'AppDatabase.openFile encrypts, reopens with the key and rejects another',
    () {
      final path = '${dir.path}/pandapay.sqlite';
      final first = AppDatabase.openFile(path, keyHex: key);
      first.saveProfileDisplayName('user:synthetic', 'Synthetic Name');
      first.close();
      expect(
        String.fromCharCodes(File(path).readAsBytesSync().take(15)),
        isNot('SQLite format 3'),
      );
      final again = AppDatabase.openFile(path, keyHex: key);
      expect(again.profileDisplayName('user:synthetic'), 'Synthetic Name');
      again.close();
      expect(
        () => AppDatabase.openFile(path, keyHex: 'cd' * 32),
        throwsA(isA<SqliteException>()),
      );
    },
    skip: skip,
  );

  test('the recovery connection is keyed with the same key', () async {
    final path = '${dir.path}/pandapay.sqlite';
    final database = AppDatabase.openFile(path, keyHex: key);
    final tables = await database.withRecoveryDatabase((lease) async {
      return lease.database
              .select(
                "SELECT count(*) AS n FROM sqlite_master WHERE type='table'",
              )
              .single['n']
          as int;
    });
    expect(tables, greaterThan(0));
    database.close();
  }, skip: skip);

  test('openFile refuses a malformed key before touching the file', () {
    final path = '${dir.path}/pandapay.sqlite';
    expect(
      () => AppDatabase.openFile(path, keyHex: 'not-hex'),
      throwsArgumentError,
    );
  });
}
