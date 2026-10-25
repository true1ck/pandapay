// Run only through the isolated sqlite3mc fixture; the production app still
// uses its unchanged SQLite dependency until migration/device acceptance.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('encrypted engine authenticates pages, WAL and retained key', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'pandapay-cipher-fixture-',
    );
    final file = File('${directory.path}/proof.db');
    final random = Random.secure();
    final key = List.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    Database open(String filename, String? secret) {
      final db = sqlite3.open(filename);
      db.execute("PRAGMA cipher='chacha20'");
      if (secret != null) db.execute('PRAGMA key = "x\'$secret\'"');
      db.execute('PRAGMA temp_store=MEMORY');
      return db;
    }

    const marker = 'receipt-fixture-₹500-original-uuid';
    try {
      final db = open(file.path, key);
      try {
        expect(db.select('PRAGMA cipher').single.values.first, 'chacha20');
        expect(db.select('PRAGMA temp_store').single.values.first, 2);
        expect(db.select('PRAGMA journal_mode=WAL').single.values.first, 'wal');
        db.execute(
          'CREATE TABLE proof(id TEXT PRIMARY KEY,value TEXT,payload BLOB)',
        );
        db.execute('INSERT INTO proof VALUES (?,?,?)', [
          'original-uuid',
          marker,
          [0, 1, 255],
        ]);
        final wal = File('${file.path}-wal');
        expect(wal.existsSync(), isTrue);
        expect(_contains(wal.readAsBytesSync(), utf8.encode(marker)), isFalse);
        db.execute('BEGIN IMMEDIATE');
        db.execute('UPDATE proof SET value=?', ['rolled-back']);
        db.execute('ROLLBACK');
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      } finally {
        db.dispose();
      }
      final original = file.readAsBytesSync();
      expect(
        String.fromCharCodes(original.take(16)),
        isNot('SQLite format 3\u0000'),
      );
      expect(_contains(original, utf8.encode(marker)), isFalse);
      for (final secret in [null, '0' * 64]) {
        final wrong = open(file.path, secret);
        try {
          expect(
            () => wrong.select('SELECT * FROM proof'),
            throwsA(isA<SqliteException>()),
          );
        } finally {
          wrong.dispose();
        }
      }
      final reopened = open(file.path, key);
      try {
        final row = reopened.select('SELECT * FROM proof').single;
        expect(row['id'], 'original-uuid');
        expect(row['value'], marker);
        expect(row['payload'], [0, 1, 255]);
      } finally {
        reopened.dispose();
      }
      expect(original.length, greaterThan(5000));
      original[5000] ^= 1;
      final damaged = File('${directory.path}/damaged.db')
        ..writeAsBytesSync(original);
      final corrupt = open(damaged.path, key);
      try {
        expect(
          () => corrupt.select('SELECT * FROM proof'),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        corrupt.dispose();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

bool _contains(List<int> bytes, List<int> marker) {
  for (var offset = 0; offset <= bytes.length - marker.length; offset++) {
    var equal = true;
    for (var i = 0; i < marker.length; i++) {
      if (bytes[offset + i] != marker[i]) {
        equal = false;
        break;
      }
    }
    if (equal) return true;
  }
  return false;
}
