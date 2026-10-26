import 'package:sqlite3/sqlite3.dart' show Database;

/// Read-only: never opens the queue, creates tables, decrypts or changes keys.
int pendingStatementImportBatches(Database database, String namespace) {
  final exists = database.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='statement_import_batches'",
  );
  if (exists.isEmpty) return 0;
  return database.select(
        'SELECT COUNT(*) AS n FROM statement_import_batches WHERE namespace=? AND ciphertext IS NOT NULL',
        [namespace],
      ).single['n']
      as int;
}

void requireNoPendingStatementImports(Database database, String namespace) {
  if (pendingStatementImportBatches(database, namespace) > 0) {
    throw StateError(
      'Finish or explicitly cancel pending file imports on this phone before creating or restoring a recovery copy.',
    );
  }
}
