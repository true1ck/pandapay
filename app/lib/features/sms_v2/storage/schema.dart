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
  static const int version = 5;

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
    'v2_sync_state',
    'v2_rule_stats_by_account',
    'v2_personal_merchant_alias',
    'v2_bulk_changes',
    'v2_bulk_change_items',
    'v2_subscriptions',
    'v2_subscription_history',
    'v2_owner_identity',
    'v2_owner_signals',
  ];

  static const String _versionTable = 'sms_v2_schema_version';

  /// Statements that bring a database from version `n - 1` to `n`. A version's
  /// statements run in one savepoint together with the version row, so a crashed
  /// run rolls back whole and can be repeated. Most are `IF NOT EXISTS`; the
  /// `ALTER TABLE ... ADD COLUMN` statements of version 3 are not idempotent on
  /// their own, they rely on that savepoint and on the version row.
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
    2: [
      '''
CREATE TABLE IF NOT EXISTS v2_sync_state (
  namespace TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY(namespace, key)
)''',
      '''
CREATE TABLE IF NOT EXISTS v2_rule_stats_by_account (
  namespace TEXT NOT NULL,
  day TEXT NOT NULL,
  rule_id TEXT NOT NULL,
  rule_version INTEGER NOT NULL,
  hits INTEGER NOT NULL DEFAULT 0,
  to_review INTEGER NOT NULL DEFAULT 0,
  corrected INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(namespace, day, rule_id, rule_version)
)''',
    ],
    3: [
      // "Which other transactions look like this one" must be a single indexed
      // lookup, not a read of every fact. The shop key and the rule id used to
      // live only inside the JSON text of a fact. `keyed = 0` marks the rows
      // that still need their key written (see FactKeys.backfill).
      'ALTER TABLE v2_facts ADD COLUMN merchant_key TEXT',
      'ALTER TABLE v2_facts ADD COLUMN rule_id TEXT',
      'ALTER TABLE v2_facts ADD COLUMN keyed INTEGER NOT NULL DEFAULT 0',
      'CREATE INDEX IF NOT EXISTS idx_v2_facts_merchant ON v2_facts (namespace, merchant_key, observed_at)',
      'CREATE INDEX IF NOT EXISTS idx_v2_facts_instrument ON v2_facts (namespace, instrument_id, observed_at)',
      'CREATE INDEX IF NOT EXISTS idx_v2_facts_rule ON v2_facts (namespace, rule_id, observed_at)',
      'CREATE INDEX IF NOT EXISTS idx_v2_facts_unkeyed ON v2_facts (namespace) WHERE keyed = 0',
      // A person's own name for a shop, keyed on the name the SMS prints.
      // `since` is the earliest SMS time the name applies to.
      '''
CREATE TABLE IF NOT EXISTS v2_personal_merchant_alias (
  namespace TEXT NOT NULL,
  printed_key TEXT NOT NULL,
  display_name TEXT NOT NULL,
  since TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (namespace, printed_key)
)''',
      // A change applied to many transactions at once, kept so it can be undone.
      '''
CREATE TABLE IF NOT EXISTS v2_bulk_changes (
  namespace TEXT NOT NULL,
  change_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  detail TEXT NOT NULL,
  created_at TEXT NOT NULL,
  undone_at TEXT,
  PRIMARY KEY (namespace, change_id)
)''',
      '''
CREATE TABLE IF NOT EXISTS v2_bulk_change_items (
  namespace TEXT NOT NULL,
  change_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  previous TEXT NOT NULL,
  PRIMARY KEY (namespace, change_id, event_id)
)''',
    ],
    4: [
      // What the phone keeps about each subscription, derived once from the
      // ledger (see SubscriptionStore) so no screen walks the whole history.
      // One row per service; `payload` is the SubscriptionState JSON. Anything
      // that depends on today's date is decided when a screen reads the row.
      '''
CREATE TABLE IF NOT EXISTS v2_subscriptions (
  namespace TEXT NOT NULL,
  series_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  payload TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (namespace, series_id)
)''',
      // The dated story of each subscription: set up, charged, price changed,
      // paused, cancelled. `seq` keeps the order of same-day events.
      '''
CREATE TABLE IF NOT EXISTS v2_subscription_history (
  namespace TEXT NOT NULL,
  series_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  kind TEXT NOT NULL,
  at TEXT NOT NULL,
  amount_minor INTEGER,
  previous_minor INTEGER,
  source_key TEXT,
  PRIMARY KEY (namespace, series_id, seq)
)''',
      'CREATE INDEX IF NOT EXISTS idx_v2_subscription_history_at ON v2_subscription_history (namespace, series_id, at)',
    ],
    // Version 5 adds who the account owner is. It is its own step because a phone
    // that already ran version 4 never runs version 4 again.
    5: [
      // Who the account owner is, for telling a transfer between their own
      // accounts from a payment to someone else. `entry` is the string the
      // linker reads (a name, `vpa:`, `payee:`, `mask:` or a `not:` rejection);
      // `source` is user (typed), marked (a payment they flagged), inferred
      // (learned from their messages) or dismissed (an inferred name they
      // removed, so it is not learned again).
      '''
CREATE TABLE IF NOT EXISTS v2_owner_identity (
  namespace TEXT NOT NULL,
  entry TEXT NOT NULL,
  source TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (namespace, entry)
)''',
      // How often each greeting name was seen and from how many senders.
      '''
CREATE TABLE IF NOT EXISTS v2_owner_signals (
  namespace TEXT NOT NULL PRIMARY KEY,
  payload TEXT NOT NULL,
  updated_at TEXT NOT NULL
)''',
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
