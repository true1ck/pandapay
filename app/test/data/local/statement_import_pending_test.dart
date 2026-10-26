import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/statement_import_pending.dart';

void main() {
  test(
    'legacy databases need no queue schema or key just to check backup admission',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      expect(pendingStatementImportBatches(db, 'user:owner'), 0);
      requireNoPendingStatementImports(db, 'user:owner');
      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE name LIKE 'statement_import_%'",
        ),
        isEmpty,
      );
    },
  );
  test(
    'pending ciphertext blocks complete recovery only for its owning account',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      db.execute(
        'CREATE TABLE statement_import_batches(namespace TEXT,ciphertext BLOB)',
      );
      db.execute('INSERT INTO statement_import_batches VALUES (?,?)', [
        'user:owner',
        [1, 2, 3],
      ]);
      db.execute('INSERT INTO statement_import_batches VALUES (?,NULL)', [
        'user:other',
      ]);
      expect(pendingStatementImportBatches(db, 'user:owner'), 1);
      expect(
        () => requireNoPendingStatementImports(db, 'user:owner'),
        throwsStateError,
      );
      requireNoPendingStatementImports(db, 'user:other');
      expect(
        db.select(
          'SELECT length(ciphertext) AS n FROM statement_import_batches WHERE namespace=?',
          ['user:owner'],
        ).single['n'],
        3,
      );
    },
  );
  test(
    'storage corruption or unknown shape cannot become an empty successful backup gate',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      db.execute('CREATE TABLE statement_import_batches(unexpected TEXT)');
      expect(
        () => requireNoPendingStatementImports(db, 'user:owner'),
        throwsA(isA<SqliteException>()),
      );
    },
  );
}
