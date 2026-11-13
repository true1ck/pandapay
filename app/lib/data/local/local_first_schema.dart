import 'package:sqlite3/sqlite3.dart';

/// Additive schema module for the offline-first work (WP-C2 onwards).
///
/// Why this exists: [AppDatabase] only runs its big static `_schema` block when
/// `PRAGMA user_version < 1`, so a table added there never reaches an install
/// that is already past v1, and every extra `user_version` bump is a shared
/// merge hotspot. This module is the one place later work packages append to.
/// It mirrors `SmsV2Schema` and `SharedExpensesSchema`: its own version row in
/// its own table, and it never touches `PRAGMA user_version`.
///
/// How to add a migration (append only):
///  1. Add a function to [_migrations]; its position (1-based) is its number.
///     Never edit, reorder or remove a shipped one.
///  2. Make it idempotent: `CREATE TABLE/INDEX IF NOT EXISTS`, and use
///     [addColumnIfMissing] instead of a bare `ALTER TABLE`. Another isolate
///     (the SMS background handler, the capture worker) opens its own
///     connection and runs this same code, so a step can be attempted twice.
///  3. Additive only: new tables, new nullable/defaulted columns, new indexes.
///     No renames, drops or repurposed columns. An older app on the same file
///     must keep working (it simply ignores what it does not know), and
///     SQLite's `user_version` downgrade is silent.
///  4. Every new table is namespaced: `namespace TEXT NOT NULL` is the FIRST
///     primary-key column (`PRIMARY KEY (namespace, id)`), so
///     `AppDatabase.clearAccountNamespace` and the account-scoped queue
///     counting in `QueueRegistry` work without special cases.
///  5. Register queue-like tables in `QueueRegistry`
///     (`lib/data/local/queue_registry.dart`) and decide backup coverage.
///
/// Each run applies all outstanding migrations inside one SAVEPOINT together
/// with the version row, so a crash rolls the whole run back and it can simply
/// be repeated.
abstract final class LocalFirstSchema {
  /// Row key in [versionTable].
  static const String module = 'local_first';
  static const String versionTable = 'local_first_schema_version';

  /// Tables owned by this module (excluding [versionTable]). Append-only,
  /// same order as the migrations that create them.
  static const List<String> tableNames = <String>[
    'subscription_overrides',
    'user_budgets',
  ];

  /// The migration list. Index 0 is migration number 1.
  static final List<LocalFirstMigration> _migrations = <LocalFirstMigration>[
    _addTagAndForeignOutboxRetryColumns,
    _addSubscriptionOverridesAndUserBudgets,
  ];

  /// Current module version: the number of shipped migrations.
  static int get version => _migrations.length;

  /// The version recorded in [db], or null when the module never ran.
  static int? installedVersion(Database db) {
    final exists = db
        .select(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
          [versionTable],
        )
        .isNotEmpty;
    if (!exists) return null;
    final rows = db.select(
      'SELECT version FROM $versionTable WHERE module = ?',
      [module],
    );
    return rows.isEmpty ? null : rows.single['version'] as int;
  }

  /// Brings [db] to [version]. Safe to call from every connection on open.
  ///
  /// A database that is already newer (an older app reading a file a newer app
  /// migrated) is left alone and `false` is returned, so rollback keeps
  /// personal finance readable. Corrupt metadata and SQLite errors propagate.
  ///
  /// [migrations] exists for tests only; production always uses the shipped
  /// list.
  static bool ensure(Database db, {List<LocalFirstMigration>? migrations}) {
    final list = migrations ?? _migrations;
    final target = list.length;
    db.execute(
      'CREATE TABLE IF NOT EXISTS $versionTable ('
      'module TEXT PRIMARY KEY, version INTEGER NOT NULL)',
    );
    final seen = installedVersion(db);
    if (seen != null && seen > target) return false;
    if ((seen ?? 0) >= target) return true;
    db.execute('SAVEPOINT local_first_ensure');
    try {
      // Take the write lock first, then re-read the version: another isolate
      // may have finished the same migration since the check above.
      db.execute(
        'INSERT OR IGNORE INTO $versionTable (module, version) VALUES (?, 0)',
        [module],
      );
      final installed = installedVersion(db) ?? 0;
      if (installed > target) {
        db.execute('RELEASE local_first_ensure');
        return false;
      }
      for (var v = installed + 1; v <= target; v++) {
        list[v - 1](db);
      }
      db.execute(
        'UPDATE $versionTable SET version = ? WHERE module = ?',
        [target, module],
      );
      db.execute('RELEASE local_first_ensure');
      return true;
    } catch (_) {
      db.execute('ROLLBACK TO local_first_ensure');
      db.execute('RELEASE local_first_ensure');
      rethrow;
    }
  }

  /// Idempotent `ALTER TABLE ... ADD COLUMN`. Does nothing when the table does
  /// not exist yet (its owner creates it with the column) or the column is
  /// already there; tolerates losing a race with another connection.
  static void addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) {
    bool has() => db
        .select('PRAGMA table_info("$table")')
        .any((row) => row['name'] == column);
    final columns = db.select('PRAGMA table_info("$table")');
    if (columns.isEmpty) return;
    if (columns.any((row) => row['name'] == column)) return;
    try {
      db.execute('ALTER TABLE "$table" ADD COLUMN $column $definition');
    } catch (_) {
      if (!has()) rethrow;
    }
  }
}

/// Migration 1: the tag outbox and the foreign-payments outbox gain the same
/// retry bookkeeping as the transaction outbox (next attempt / park, plus
/// attempts and last_error for the foreign one). The foreign table is created
/// lazily by its repository, which also adds these columns when it creates the
/// table, so a table that does not exist yet is skipped here.
void _addTagAndForeignOutboxRetryColumns(Database db) {
  const counter = 'INTEGER NOT NULL DEFAULT 0';
  LocalFirstSchema.addColumnIfMissing(
    db,
    'transaction_tag_outbox',
    'next_attempt_at',
    counter,
  );
  LocalFirstSchema.addColumnIfMissing(
    db,
    'transaction_tag_outbox',
    'parked',
    counter,
  );
  for (final column in ['attempts', 'next_attempt_at', 'parked']) {
    LocalFirstSchema.addColumnIfMissing(
      db,
      'foreign_payments_outbox',
      column,
      counter,
    );
  }
  LocalFirstSchema.addColumnIfMissing(
    db,
    'foreign_payments_outbox',
    'last_error',
    'TEXT',
  );
}

/// Migration 2 (WP-C7): two device-local stores, namespace first.
///
/// `subscription_overrides`: the person's hide/edit/manual-add of subscriptions
/// whose ids the server cannot know (`v2:`, `projection:`, `manual:`).
/// `user_budgets`: budgets created on the phone and not yet confirmed by the
/// server (the queued `budget_save` command delivers them; the row is dropped
/// once the server list carries the same id). Neither is a send queue.
void _addSubscriptionOverridesAndUserBudgets(Database db) {
  db.execute(
    'CREATE TABLE IF NOT EXISTS subscription_overrides ('
    'namespace TEXT NOT NULL, '
    'series_id TEXT NOT NULL, '
    'payload TEXT NOT NULL, '
    'updated_at INTEGER NOT NULL, '
    'PRIMARY KEY (namespace, series_id))',
  );
  db.execute(
    'CREATE TABLE IF NOT EXISTS user_budgets ('
    'namespace TEXT NOT NULL, '
    'id TEXT NOT NULL, '
    'payload TEXT NOT NULL, '
    'edited_at INTEGER NOT NULL, '
    'PRIMARY KEY (namespace, id))',
  );
}

/// One numbered, append-only step of [LocalFirstSchema]. Must be idempotent.
typedef LocalFirstMigration = void Function(Database db);
