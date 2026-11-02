import 'package:sqlite3/sqlite3.dart';

/// Phone-side tables for the SMS pipeline v2 (Contracts -> Storage -> Phone).
///
/// The module keeps its own `sms_v2_schema_version` table and never touches
/// `PRAGMA user_version`, which `app_database.dart` owns. Every table is keyed
/// by `namespace` (the signed-in account) except the global rule bundle.
abstract final class SmsV2Schema {
  /// Row key in `sms_v2_schema_version`.
  static const String module = 'sms_v2';

  /// Bump when a later package adds columns or tables; add the change to
  /// [_migrations] under the new number.
  static const int version = 1;

  /// Tables created by this module, in dependency order.
  static const List<String> tableNames = [
    'v2_facts',
    'v2_instruments',
    'v2_events',
    'v2_ledger',
    'v2_outbox',
    'v2_rule_bundle',
    'v2_rule_stats',
    'v2_review_items',
  ];

  static const String _versionTable = 'sms_v2_schema_version';

  /// Statements that bring a database from version `n - 1` to `n`. All are
  /// idempotent (`IF NOT EXISTS`), so a crashed run can be repeated.
  static const Map<int, List<String>> _migrations = {
    1: [
      '''
CREATE TABLE IF NOT EXISTS v2_facts (
  namespace TEXT NOT NULL,
  fact_id TEXT NOT NULL,
  source_key TEXT NOT NULL,
  fact_type TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  instrument_id TEXT,
  payload TEXT NOT NULL,
  uploaded_at TEXT,
  PRIMARY KEY (namespace, fact_id)
)''',
      'CREATE INDEX IF NOT EXISTS idx_v2_facts_source ON v2_facts (namespace, source_key)',
      'CREATE INDEX IF NOT EXISTS idx_v2_facts_observed ON v2_facts (namespace, observed_at)',
      '''
CREATE TABLE IF NOT EXISTS v2_instruments (
  namespace TEXT NOT NULL,
  instrument_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  issuer_slug TEXT NOT NULL,
  mask_digits TEXT,
  status TEXT NOT NULL,
  payload TEXT NOT NULL,
  dirty INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (namespace, instrument_id)
)''',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_v2_instruments_identity ON v2_instruments (namespace, kind, issuer_slug, mask_digits)',
      '''
CREATE TABLE IF NOT EXISTS v2_events (
  namespace TEXT NOT NULL,
  event_id TEXT NOT NULL,
  type TEXT NOT NULL,
  status TEXT NOT NULL,
  payload TEXT NOT NULL,
  dirty INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (namespace, event_id)
)''',
      'CREATE INDEX IF NOT EXISTS idx_v2_events_status ON v2_events (namespace, status)',
      '''
CREATE TABLE IF NOT EXISTS v2_ledger (
  namespace TEXT NOT NULL,
  entry_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  payload TEXT NOT NULL,
  dirty INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (namespace, entry_id)
)''',
      'CREATE INDEX IF NOT EXISTS idx_v2_ledger_event ON v2_ledger (namespace, event_id)',
      'CREATE INDEX IF NOT EXISTS idx_v2_ledger_occurred ON v2_ledger (namespace, occurred_at)',
      '''
CREATE TABLE IF NOT EXISTS v2_outbox (
  namespace TEXT NOT NULL,
  id TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (namespace, id)
)''',
      'CREATE INDEX IF NOT EXISTS idx_v2_outbox_due ON v2_outbox (namespace, next_attempt_at)',
      '''
CREATE TABLE IF NOT EXISTS v2_rule_bundle (
  bundle_version INTEGER NOT NULL PRIMARY KEY,
  json TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  signature TEXT,
  expires_at TEXT NOT NULL,
  fetched_at TEXT NOT NULL
)''',
      '''
CREATE TABLE IF NOT EXISTS v2_rule_stats (
  day TEXT NOT NULL,
  rule_id TEXT NOT NULL,
  rule_version INTEGER NOT NULL,
  hits INTEGER NOT NULL DEFAULT 0,
  to_review INTEGER NOT NULL DEFAULT 0,
  corrected INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, rule_id, rule_version)
)''',
      '''
CREATE TABLE IF NOT EXISTS v2_review_items (
  namespace TEXT NOT NULL,
  review_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  status TEXT NOT NULL,
  PRIMARY KEY (namespace, review_id)
)''',
      'CREATE INDEX IF NOT EXISTS idx_v2_review_status ON v2_review_items (namespace, status)',
    ],
  };

  /// The version recorded for this module, or null before the first [ensure].
  static int? installedVersion(Database db) {
    final exists = db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [_versionTable],
    );
    if (exists.isEmpty) return null;
    final rows = db.select('SELECT version FROM $_versionTable WHERE module = ?', [module]);
    return rows.isEmpty ? null : rows.first['version'] as int;
  }

  /// Creates or upgrades the v2 tables. Safe to call on every start.
  static void ensure(Database db) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS $_versionTable ('
      'module TEXT PRIMARY KEY, version INTEGER NOT NULL)',
    );
    final installed = installedVersion(db) ?? 0;
    if (installed >= version) return;
    db.execute('SAVEPOINT sms_v2_ensure');
    try {
      for (var v = installed + 1; v <= version; v++) {
        for (final statement in _migrations[v]!) {
          db.execute(statement);
        }
      }
      db.execute(
        'INSERT INTO $_versionTable (module, version) VALUES (?, ?) '
        'ON CONFLICT(module) DO UPDATE SET version = excluded.version',
        [module, version],
      );
      db.execute('RELEASE sms_v2_ensure');
    } catch (_) {
      db.execute('ROLLBACK TO sms_v2_ensure');
      db.execute('RELEASE sms_v2_ensure');
      rethrow;
    }
  }
}
