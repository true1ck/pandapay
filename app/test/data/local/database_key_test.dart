import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/database_key.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';
import 'package:pandapay/data/secure_storage/local_key_provisioning_lease.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('rejects a key that is not 64 lowercase hex characters', () {
    final db = sqlite3.openInMemory();
    expect(() => applyCipherKey(db, 'abc'), throwsArgumentError);
    expect(() => applyCipherKey(db, 'A' * 64), throwsArgumentError);
    expect(() => applyCipherKey(db, "a' OR '1" * 8), throwsArgumentError);
    db.dispose();
  });

  test('refuses to run when SQLCipher is not linked', () {
    final db = sqlite3.openInMemory();
    expect(() => applyCipherKey(db, 'a' * 64), throwsStateError);
    db.dispose();
  });

  test('hex encoding of key bytes', () {
    expect(keyBytesToHex([0, 1, 255, 16]), '0001ff10');
  });

  group('openCipherOnIos', () {
    // Two distinct handles stand in for SQLCipher.framework and the process.
    final cipher = DynamicLibrary.process();
    final process = DynamicLibrary.executable();

    test('binds to the SQLCipher framework by its own name', () {
      final asked = <String>[];
      final library = openCipherOnIos(
        openLibrary: (path) {
          asked.add(path);
          return cipher;
        },
        isSqlCipher: (_) => true,
        fallback: () => process,
      );
      expect(identical(library, cipher), isTrue);
      expect(asked, [iosSqlCipherPaths.first]);
    });

    test('tries the short framework path when the first is not found', () {
      final asked = <String>[];
      final library = openCipherOnIos(
        openLibrary: (path) {
          asked.add(path);
          if (path == iosSqlCipherPaths.first) throw ArgumentError('missing');
          return cipher;
        },
        isSqlCipher: (_) => true,
        fallback: () => process,
      );
      expect(identical(library, cipher), isTrue);
      expect(asked, iosSqlCipherPaths);
    });

    test('skips a library that does not export sqlite3_key', () {
      final library = openCipherOnIos(
        openLibrary: (_) => cipher,
        isSqlCipher: (_) => false,
        fallback: () => process,
      );
      expect(identical(library, process), isTrue);
    });

    test('falls back to the process lookup when no framework loads', () {
      var fallbacks = 0;
      final library = openCipherOnIos(
        openLibrary: (_) => throw ArgumentError('missing'),
        isSqlCipher: (_) => true,
        fallback: () {
          fallbacks++;
          return process;
        },
      );
      expect(identical(library, process), isTrue);
      expect(fallbacks, 1);
    });

    test('the real iOS framework names are the ones the app embeds', () {
      expect(iosSqlCipherPaths, contains('@rpath/SQLCipher.framework/SQLCipher'));
    });

    test('ensureSqlCipherLoaded leaves host (test) sqlite alone', () {
      ensureSqlCipherLoaded();
      final db = sqlite3.openInMemory();
      expect(db.select('SELECT 1 AS one').single['one'], 1);
      db.dispose();
    });
  });

  group('DatabaseKeyLoader', () {
    late _MemoryStore store;
    late Directory dir;
    late String dbPath;
    var wipes = 0;
    late Random rng;

    DatabaseKeyLoader loader({String installId = 'install-A'}) =>
        DatabaseKeyLoader(
          installId: installId,
          custody: LocalDatabaseKeyCustody(
            store,
            random: rng,
            lease: _InlineLease(),
          ),
        );

    setUp(() async {
      store = _MemoryStore();
      dir = await Directory.systemTemp.createTemp('dbkey');
      dbPath = '${dir.path}/pandapay.sqlite';
      wipes = 0;
      rng = Random(7);
    });
    tearDown(() => dir.delete(recursive: true));

    Future<void> wipe() async {
      wipes++;
      final file = File(dbPath);
      if (file.existsSync()) file.deleteSync();
    }

    test(
      'creates a 64 character key once and returns the same one after',
      () async {
        final first = await loader().loadHex(databaseExists: false);
        expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(await loader().loadHex(databaseExists: true), first);
      },
    );

    test(
      'a database with no key is never silently re-keyed by loadHex',
      () async {
        await expectLater(
          loader().loadHex(databaseExists: true),
          throwsA(
            isA<DatabaseKeyUnavailable>().having(
              (e) => e.status,
              'status',
              LocalKeyStatus.missingForEncryptedStore,
            ),
          ),
        );
      },
    );

    test(
      'lost key: loadHexOrReset wipes the unreadable file and starts fresh',
      () async {
        File(dbPath).writeAsStringSync('ciphertext nobody can read');
        final key = await loader().loadHexOrReset(
          databasePath: dbPath,
          wipeStorage: wipe,
        );
        expect(wipes, 1);
        expect(File(dbPath).existsSync(), isFalse);
        expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(await loader().loadHex(databaseExists: false), key);
      },
    );

    test('key bound to another install is replaced, not reused', () async {
      final old = await loader(
        installId: 'install-A',
      ).loadHex(databaseExists: false);
      File(dbPath).writeAsStringSync('ciphertext');
      final fresh = await loader(
        installId: 'install-B',
      ).loadHexOrReset(databasePath: dbPath, wipeStorage: wipe);
      expect(wipes, 1);
      expect(fresh, isNot(old));
      expect(
        await loader(installId: 'install-B').loadHex(databaseExists: false),
        fresh,
      );
    });

    test('damaged key metadata is destroyed and replaced', () async {
      await loader().loadHex(databaseExists: false);
      store.values['pandapay.localdb.key_metadata.v1'] = '{"format":1}';
      File(dbPath).writeAsStringSync('ciphertext');
      final fresh = await loader().loadHexOrReset(
        databasePath: dbPath,
        wipeStorage: wipe,
      );
      expect(wipes, 1);
      expect(fresh, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('a locked key store is rethrown and nothing is deleted', () async {
      File(dbPath).writeAsStringSync('ciphertext');
      store.locked = true;
      await expectLater(
        loader().loadHexOrReset(databasePath: dbPath, wipeStorage: wipe),
        throwsA(
          isA<DatabaseKeyUnavailable>().having(
            (e) => e.isTemporary,
            'temporary',
            isTrue,
          ),
        ),
      );
      expect(wipes, 0);
      expect(File(dbPath).existsSync(), isTrue);
    });

    test('destroy removes the key so the next key is different', () async {
      final first = await loader().loadHex(databaseExists: false);
      await loader().destroy();
      expect(store.values, isEmpty);
      final second = await DatabaseKeyLoader(
        installId: 'install-A',
        custody: LocalDatabaseKeyCustody(
          store,
          random: rng,
          lease: _InlineLease(),
        ),
      ).loadHex(databaseExists: false);
      expect(second, isNot(first));
    });
  });
}

final class _InlineLease implements LocalKeyProvisioningLease {
  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) => operation();
}

final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  bool locked = false;

  void _check() {
    if (locked) throw const SecureKeyStoreUnavailable();
  }

  @override
  Future<String?> read(String key) async {
    _check();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _check();
    values[key] = value;
  }

  @override
  Future<bool> writeIfAbsent(String key, String value) async {
    _check();
    if (values.containsKey(key)) return false;
    values[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async {
    _check();
    values.remove(key);
  }
}
