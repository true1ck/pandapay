import 'package:sqlite3/sqlite3.dart';

/// Additive module on the existing AppDatabase connection, not a second pool.
abstract final class SharedExpensesSchema {
  static const version = 7;
  static const tableNames = [
    'shared_commands',
    'shared_command_dependencies',
    'shared_source_dependencies',
    'shared_operation_receipts',
    'shared_provisional',
    'shared_projections',
    'shared_sync_state',
    'shared_editor_drafts',
    'shared_editor_receipts',
  ];

  /// The core database may skip only a known future module version so rollback
  /// keeps personal finance readable. Shared feature writers remain strict.
  /// Corrupt metadata and SQLite errors always propagate.
  static bool ensure(Database db, {bool allowNewerVersion = false}) {
    final exists = db
        .select(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name='shared_schema_version'",
        )
        .isNotEmpty;
    final rows = exists
        ? db.select(
            "SELECT version FROM shared_schema_version WHERE module='shared_expenses'",
          )
        : const <Map<String, Object?>>[];
    final installed = rows.isEmpty ? 0 : rows.single['version'] as int;
    if (installed > version) {
      if (allowNewerVersion) return false;
      throw const FormatException(
        'Newer shared storage requires a compatible app',
      );
    }
    if (installed == version) return true;
    db.execute('SAVEPOINT shared_schema_ensure');
    try {
      db.execute(
        'CREATE TABLE IF NOT EXISTS shared_schema_version(module TEXT PRIMARY KEY,version INTEGER NOT NULL)',
      );
      if (installed < 1) {
        db.execute('''
CREATE TABLE shared_commands (
 namespace TEXT NOT NULL,operation_id TEXT NOT NULL,context_id TEXT NOT NULL,
 kind TEXT NOT NULL,request_json TEXT NOT NULL,request_hash TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending',created_at INTEGER NOT NULL,
 attempts INTEGER NOT NULL DEFAULT 0,next_attempt INTEGER NOT NULL DEFAULT 0,
 lease_id TEXT,lease_expires INTEGER NOT NULL DEFAULT 0,error_code TEXT,
 PRIMARY KEY(namespace,operation_id)
);
CREATE INDEX shared_commands_due ON shared_commands(namespace,state,next_attempt,lease_expires,created_at,operation_id);
CREATE TRIGGER shared_commands_immutable BEFORE UPDATE OF namespace,operation_id,context_id,kind,request_json,request_hash ON shared_commands
BEGIN SELECT RAISE(ABORT,'shared command is immutable'); END;
CREATE TABLE shared_command_dependencies(namespace TEXT NOT NULL,operation_id TEXT NOT NULL,depends_on TEXT NOT NULL,PRIMARY KEY(namespace,operation_id,depends_on));
CREATE TABLE shared_source_dependencies(namespace TEXT NOT NULL,operation_id TEXT NOT NULL,source_key TEXT NOT NULL,resolved INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(namespace,operation_id,source_key));
CREATE INDEX shared_source_waiting ON shared_source_dependencies(namespace,source_key,resolved);
CREATE TABLE shared_operation_receipts(namespace TEXT NOT NULL,operation_id TEXT NOT NULL,request_hash TEXT NOT NULL,receipt_json TEXT NOT NULL,PRIMARY KEY(namespace,operation_id));
CREATE TABLE shared_provisional(namespace TEXT NOT NULL,operation_id TEXT NOT NULL,context_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,operation_id));
CREATE TABLE shared_projections(namespace TEXT NOT NULL,context_id TEXT NOT NULL,entity TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,payload TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(namespace,context_id,entity,id));
CREATE INDEX shared_projections_page ON shared_projections(namespace,context_id,entity,deleted,id);
CREATE TABLE shared_sync_state(namespace TEXT NOT NULL,key TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(namespace,key));
INSERT INTO shared_schema_version VALUES('shared_expenses',1);
''');
      }
      if (installed < 2) {
        db.execute(
          'CREATE INDEX IF NOT EXISTS shared_projection_overview ON shared_projections(namespace,entity,deleted,id)',
        );
        db.execute(
          'CREATE INDEX IF NOT EXISTS shared_command_context ON shared_commands(namespace,context_id,state,operation_id)',
        );
        db.execute(
          "UPDATE shared_schema_version SET version=2 WHERE module='shared_expenses'",
        );
      }
      if (installed < 3) {
        db.execute('''
CREATE TABLE shared_editor_drafts (
 namespace TEXT NOT NULL,draft_id TEXT NOT NULL,context_id TEXT,
 value_json TEXT NOT NULL,version INTEGER NOT NULL,operation_id TEXT,
 updated_at INTEGER NOT NULL,
 PRIMARY KEY(namespace,draft_id)
);
CREATE INDEX shared_editor_context ON shared_editor_drafts(namespace,context_id,draft_id);
CREATE INDEX shared_editor_unfinished ON shared_editor_drafts(namespace,draft_id) WHERE operation_id IS NULL;
UPDATE shared_schema_version SET version=3 WHERE module='shared_expenses';
''');
      }
      if (installed < 4) {
        db.execute('''
CREATE TABLE shared_editor_receipts (
 namespace TEXT NOT NULL,draft_id TEXT NOT NULL,hash TEXT NOT NULL,
 name TEXT NOT NULL,mime_type TEXT,bytes BLOB NOT NULL CHECK(length(bytes) BETWEEN 1 AND 8388608),
 PRIMARY KEY(namespace,draft_id,hash)
);
UPDATE shared_schema_version SET version=4 WHERE module='shared_expenses';
''');
      }
      if (installed < 7) {
        // No new form drafts are persisted. Keep legacy submitted metadata and
        // receipt storage so prior queues and backups remain compatible.
        db.execute('DROP INDEX IF EXISTS shared_editor_source_event');
        db.execute('DROP INDEX IF EXISTS shared_editor_source_transaction');
        db.execute('DROP INDEX IF EXISTS shared_editor_resume');
        db.execute('DROP INDEX IF EXISTS shared_editor_context_resume');
        db.execute(
          "UPDATE shared_schema_version SET version=7 WHERE module='shared_expenses'",
        );
      }
      db.execute('RELEASE shared_schema_ensure');
      return true;
    } catch (_) {
      db.execute('ROLLBACK TO shared_schema_ensure');
      db.execute('RELEASE shared_schema_ensure');
      rethrow;
    }
  }

  static void discardUnsubmittedEditors(Database db, String namespace) {
    db.execute('SAVEPOINT shared_discard_forms');
    try {
      db.execute(
        '''DELETE FROM shared_editor_receipts WHERE namespace=?
 AND draft_id IN (SELECT draft_id FROM shared_editor_drafts WHERE namespace=? AND operation_id IS NULL)
 AND NOT EXISTS (SELECT 1 FROM shared_commands c WHERE c.namespace=shared_editor_receipts.namespace AND c.operation_id=shared_editor_receipts.draft_id)''',
        [namespace, namespace],
      );
      db.execute(
        'DELETE FROM shared_editor_drafts WHERE namespace=? AND operation_id IS NULL',
        [namespace],
      );
      db.execute('RELEASE shared_discard_forms');
    } catch (_) {
      db.execute('ROLLBACK TO shared_discard_forms');
      db.execute('RELEASE shared_discard_forms');
      rethrow;
    }
  }
}
