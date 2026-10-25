import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/secure_storage/encrypted_database_copy.dart';

void main() {
  test('contract covers rowids, storage classes, generated values and schema', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute(
      "CREATE TABLE ordinary(id TEXT PRIMARY KEY, value BLOB, generated TEXT GENERATED ALWAYS AS (id || '!') VIRTUAL)",
    );
    db.execute(
      "INSERT INTO ordinary(rowid,id,value) VALUES(-7,'first',x'00ff'),(23,'second',CAST(x'ff' AS TEXT))",
    );
    db.execute(
      'CREATE TABLE keyed(a TEXT,b INTEGER,value REAL,PRIMARY KEY(a,b)) WITHOUT ROWID',
    );
    db.execute("INSERT INTO keyed VALUES('a',2,1.5)");
    final first = SqliteDatabaseContract.capture(db),
        repeat = SqliteDatabaseContract.capture(db);
    expect(first.matches(repeat), true);
    expect(first.tableRows, {'ordinary': 2, 'keyed': 1});
    db.execute("UPDATE ordinary SET rowid=-8 WHERE id='first'");
    expect(first.matches(SqliteDatabaseContract.capture(db)), false);
    db.execute("UPDATE ordinary SET rowid=-7 WHERE id='first'");
    db.execute(
      "UPDATE ordinary SET value=CAST(value AS BLOB) WHERE id='second'",
    );
    expect(first.matches(SqliteDatabaseContract.capture(db)), false);
    db.execute('CREATE INDEX extra_idx ON ordinary(id)');
    expect(
      first.schemaSha256,
      isNot(SqliteDatabaseContract.capture(db).schemaSha256),
    );
  });
  test('contract keeps AUTOINCREMENT sequence and detects header versions', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute(
      'CREATE TABLE queue(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT)',
    );
    db.execute("INSERT INTO queue(id,value) VALUES(100,'pending')");
    db.execute('DELETE FROM queue');
    final before = SqliteDatabaseContract.capture(db);
    expect(before.tableRows['sqlite_sequence'], 1);
    db.execute("UPDATE sqlite_sequence SET seq=200 WHERE name='queue'");
    expect(
      before.dataSha256,
      isNot(SqliteDatabaseContract.capture(db).dataSha256),
    );
    db.execute('PRAGMA user_version=12');
    expect(
      before.schemaSha256,
      isNot(SqliteDatabaseContract.capture(db).schemaSha256),
    );
  });
  test('contract refuses row and cell budgets before materializing cells', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute('CREATE TABLE data(value BLOB)');
    db.execute("INSERT INTO data VALUES(x'00010203'),(NULL)");
    expect(
      () => SqliteDatabaseContract.capture(
        db,
        bounds: const SqliteCopyBounds(maxRows: 1),
      ),
      throwsA(isA<EncryptedDatabaseCopyFailure>()),
    );
    expect(
      () => SqliteDatabaseContract.capture(
        db,
        bounds: const SqliteCopyBounds(maxCellBytes: 2),
      ),
      throwsA(isA<EncryptedDatabaseCopyFailure>()),
    );
  });
  test(
    'contract refuses ambiguous rowid aliases and unknown internal/virtual layouts',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      db.execute(
        'CREATE TABLE ambiguous(rowid INTEGER,_rowid_ INTEGER,oid INTEGER)',
      );
      expect(
        () => SqliteDatabaseContract.capture(db),
        throwsA(isA<EncryptedDatabaseCopyFailure>()),
      );
    },
  );
  test(
    'invalid copy bounds and public errors contain no paths or key values',
    () {
      expect(
        () => const SqliteCopyBounds(maxRows: 0).validate(),
        throwsA(isA<EncryptedDatabaseCopyFailure>()),
      );
      expect(
        const EncryptedDatabaseCopyFailure('copy_unavailable').toString(),
        'EncryptedDatabaseCopyFailure(copy_unavailable)',
      );
    },
  );
  test(
    'aggregate row budget prevents many individually small cells growing buffers',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      db.execute('CREATE TABLE wide(a BLOB,b BLOB)');
      db.execute("INSERT INTO wide VALUES(x'000102',x'030405')");
      expect(
        () => SqliteDatabaseContract.capture(
          db,
          bounds: const SqliteCopyBounds(maxCellBytes: 3, maxRowBytes: 4),
        ),
        throwsA(isA<EncryptedDatabaseCopyFailure>()),
      );
    },
  );
}
