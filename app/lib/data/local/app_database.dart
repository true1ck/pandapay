import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// UA-0.3 offline cache (GAP_ANALYSIS.md §2) — plain sqlite3, not drift.
/// drift_dev's build_runner codegen was tried first and dropped: every
/// drift_dev version compatible with pandapay_lints' analyzer ^7.0.0 hits a
/// real analyzer crash (DotShorthandInvocationImpl in bundle_writer.dart)
/// on this codebase's existing `'key': ?value` null-shorthand syntax, and
/// every drift_dev version that avoids the crash needs an analyzer/build
/// version pandapay_lints or riverpod_generator can't satisfy. Raw sqlite3
/// needs no codegen, so the conflict doesn't apply — see
/// docs/superpowers/plans/2026-08-08-offline-first-local-cache.md.
///
/// `cached_responses` — one row per cached endpoint, storing the raw
/// response body text so a cold-cache read reuses the exact same fromJson
/// parser a live fetch already used. FinancialStore now owns canonical
/// account-scoped transactions/cards and coverage; these blobs remain for
/// migration and server-derived display aggregates.
///
/// `transaction_outbox_entries` — B6 quick-add offline queue. One row per
/// POST /transactions payload that failed to send while offline.
/// amount_paise mirrors Money.paise (the only integer-safe representation)
/// rather than a rupee double, avoiding float round-trip drift on a real
/// payment amount. last_error is set when a flush attempt fails for a
/// reason other than "still offline" — surfaced to the user rather than
/// retried forever silently; null means "never attempted" or "queued
/// again after a prior failure was cleared."
const _schema = '''
CREATE TABLE IF NOT EXISTS cached_responses (
  key TEXT PRIMARY KEY,
  raw_json TEXT NOT NULL,
  fetched_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS local_needs_review (
  namespace TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
  PRIMARY KEY(namespace,id)
);
CREATE TABLE IF NOT EXISTS local_commitments (
  namespace TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
  PRIMARY KEY(namespace, id)
);
CREATE TABLE IF NOT EXISTS local_past_bill_receipts (
  namespace TEXT NOT NULL,
  id TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(namespace, id)
);
CREATE INDEX IF NOT EXISTS idx_local_past_bill_receipts_date
  ON local_past_bill_receipts(namespace, updated_at DESC);
CREATE TABLE IF NOT EXISTS cache_refresh_requests (key TEXT PRIMARY KEY);

CREATE TABLE IF NOT EXISTS transaction_outbox_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_card_id TEXT,
  client_mutation_id TEXT,
  amount_paise INTEGER NOT NULL,
  category_id TEXT,
  user_category_id TEXT,
  merchant_name TEXT,
  occurred_at INTEGER,
  note TEXT,
  instrument TEXT NOT NULL DEFAULT 'credit_card',
  entry_kind TEXT NOT NULL DEFAULT 'spend',
  created_at INTEGER NOT NULL,
  last_error TEXT
);

-- Duplicate review is a multi-row server operation, so it has its own
-- durable intent queue. It must not be represented as a generic field edit
-- or as a new transaction insert: the server also updates observations,
-- caps, milestones and points in one transaction.
CREATE TABLE IF NOT EXISTS duplicate_resolution_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  namespace TEXT NOT NULL DEFAULT 'legacy',
  candidate_id TEXT NOT NULL,
  resolution TEXT NOT NULL,
  keep_transaction_id TEXT,
  created_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  UNIQUE(namespace, candidate_id)
);
CREATE INDEX IF NOT EXISTS idx_duplicate_resolution_outbox_pending
  ON duplicate_resolution_outbox(namespace, created_at);

-- Receipt/bill files are private device attachments by default. The database
-- stores metadata and the application-documents path; raw files are never
-- uploaded as a side effect of viewing or editing a transaction.
CREATE TABLE IF NOT EXISTS transaction_attachments (
  id TEXT PRIMARY KEY,
  transaction_id TEXT NOT NULL,
  file_name TEXT NOT NULL,
  local_path TEXT NOT NULL,
  mime_type TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_transaction_attachments_transaction
  ON transaction_attachments (transaction_id, created_at);

-- Guest/no-account mode (ui-spec.md A3): the on-device wallet for a user
-- who never signs in. Deliberately just card ownership + ordering, not a
-- relational mirror of the signed-in schema's cap/points/transaction
-- tracking — a guest has no synced spend history to compute those from,
-- so LocalUserCardsRepository always reports zero usage rather than
-- fabricating numbers. sort_order is a plain float (like signed-in
-- reorderCards) so a drag-drop insert between two cards never requires
-- renumbering every other row.
CREATE TABLE IF NOT EXISTS local_user_cards (
  id TEXT PRIMARY KEY,
  card_product_id TEXT NOT NULL,
  nickname TEXT,
  last4 TEXT,
  is_default INTEGER NOT NULL DEFAULT 0,
  is_archived INTEGER NOT NULL DEFAULT 0,
  sort_order REAL NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS user_categories (
  namespace TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  slug TEXT NOT NULL,
  parent_category_id TEXT,
  parent_user_category_id TEXT,
  match_terms_json TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(namespace, id)
);
CREATE INDEX IF NOT EXISTS idx_user_categories_namespace_name
  ON user_categories (namespace, name COLLATE NOCASE);

-- Tags are account-owned context, independent of transaction/reward writes.
-- Removed links remain as tombstones until a complete server snapshot is
-- reconciled with the durable operation queue. A known empty assignment set
-- must override tag metadata in an older transaction response.
CREATE TABLE IF NOT EXISTS transaction_tags (
  namespace TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  color TEXT,
  archived_at TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(namespace, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_transaction_tags_active_name
  ON transaction_tags(namespace, normalized_name) WHERE archived_at IS NULL;
CREATE TABLE IF NOT EXISTS transaction_tag_links (
  namespace TEXT NOT NULL,
  transaction_id TEXT NOT NULL,
  tag_id TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  PRIMARY KEY(namespace, transaction_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_transaction_tag_links_tag
  ON transaction_tag_links(namespace, tag_id, deleted_at, transaction_id);
CREATE TABLE IF NOT EXISTS transaction_tag_known_transactions (
  namespace TEXT NOT NULL,
  transaction_id TEXT NOT NULL,
  PRIMARY KEY(namespace, transaction_id)
);
CREATE TABLE IF NOT EXISTS transaction_tag_aliases (
  namespace TEXT NOT NULL,
  local_id TEXT NOT NULL,
  transaction_id TEXT NOT NULL,
  PRIMARY KEY(namespace, local_id)
);
CREATE TABLE IF NOT EXISTS transaction_tag_sync_state (
  namespace TEXT PRIMARY KEY,
  downloaded_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS transaction_tag_outbox (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  namespace TEXT NOT NULL,
  mutation_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  UNIQUE(namespace, mutation_id)
);
CREATE INDEX IF NOT EXISTS idx_transaction_tag_outbox_pending
  ON transaction_tag_outbox(namespace, seq);

-- Plan Phase 4 multi-device sync. One row per local edit that hasn't reached
-- the server yet, plus the per-device cursor.
--
-- Deliberately a queue of CHANGES rather than a mirror of the server's rows.
-- A relational replica would have to be reconciled field by field on every
-- pull and would duplicate every constraint the server already enforces; a
-- change queue only has to answer "what have I done that the server hasn't
-- seen", which is the actual question. It also composes with the existing
-- `transaction_outbox_entries` model rather than competing with it.
--
-- `field_clocks` is a JSON map of field -> millisecond timestamp, sent to the
-- server so the merge can be per-field. `attempts`/`last_error` exist so a
-- change the server permanently rejects can be surfaced and dropped instead
-- of retried forever, which is how a single bad row otherwise blocks the
-- whole queue.
CREATE TABLE IF NOT EXISTS sync_pending_changes (
  client_seq INTEGER PRIMARY KEY AUTOINCREMENT,
  entity TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  op TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  field_clocks_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);

-- Coalescing index: repeated edits to the same field of the same row should
-- collapse rather than queue N times (see SyncQueue.enqueue).
CREATE INDEX IF NOT EXISTS idx_sync_pending_entity
  ON sync_pending_changes (entity, entity_id, op);

-- Single-row table (id = 1). Holds the server-issued device id and the pull
-- cursor, both of which must survive an app restart or the device would
-- re-register and re-pull the entire history every launch.
CREATE TABLE IF NOT EXISTS sync_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  device_id TEXT,
  last_server_seq INTEGER NOT NULL DEFAULT 0,
  last_synced_at INTEGER
);

-- Display name of the signed-in profile, cached synchronously so SMS capture
-- (which runs in sync sqlite transactions and background isolates) can use it
-- for own-name self-transfer matching without an async provider hop.
CREATE TABLE IF NOT EXISTS profile_name_cache (
  namespace TEXT PRIMARY KEY,
  display_name TEXT NOT NULL
);

-- Tier-1 auto-resolution receipt. A message the AI engine resolved without a
-- user tap is removed from local_needs_review, so without this table the
-- decision would be invisible and unreversible. One row per resolved source,
-- scoped by namespace, ordered by the resolution time for the Auto-Resolved
-- tab. amount_paise follows the same integer-money rule as every other table.
CREATE TABLE IF NOT EXISTS local_auto_resolved_history (
  id TEXT PRIMARY KEY,
  namespace TEXT NOT NULL,
  source_key TEXT NOT NULL,
  sender TEXT NOT NULL,
  resolved_kind TEXT NOT NULL,
  title TEXT NOT NULL,
  amount_paise INTEGER NOT NULL,
  category_slug TEXT,
  due_date TEXT,
  occurred_at TEXT NOT NULL,
  instrument TEXT,
  account_last4 TEXT,
  confidence REAL NOT NULL,
  resolved_by TEXT NOT NULL DEFAULT 'ai',
  auto_resolved_at INTEGER NOT NULL,
  is_user_modified INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_auto_resolved_time
  ON local_auto_resolved_history (namespace, auto_resolved_at DESC);

-- Closed-loop learning: a category the user corrected once is applied to the
-- next message from the same merchant without another AI round trip. Local
-- first; `synced` only records whether the server has since learned the rule
-- (the existing POST /merchant-category-rules needs a server transaction id,
-- so local capture is authoritative until one exists).
CREATE TABLE IF NOT EXISTS user_merchant_category_rules (
  namespace TEXT NOT NULL,
  pattern TEXT NOT NULL,
  category_slug TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 1.0,
  source TEXT NOT NULL DEFAULT 'user',
  updated_at INTEGER NOT NULL,
  synced INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(namespace, pattern)
);
CREATE INDEX IF NOT EXISTS idx_user_merchant_rules_namespace
  ON user_merchant_category_rules(namespace);
''';

class AppDatabase {
  final Database db;
  final String? filePath;

  AppDatabase._(this.db, {this.filePath}) {
    // SMS delivery opens another connection in a background isolate. Let
    // SQLite serialize commits rather than losing a message to SQLITE_BUSY.
    db.execute('PRAGMA busy_timeout = 30000');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute(_schema);
    _ensureUserCategoriesSchema();
    _ensureLocalUserCardsSchema();
    _ensureOutboxSchema();
    if (!db
        .select('PRAGMA table_info(sync_pending_changes)')
        .any((c) => c['name'] == 'in_flight')) {
      db.execute(
        'ALTER TABLE sync_pending_changes ADD COLUMN in_flight INTEGER NOT NULL DEFAULT 0',
      );
    }
    for (final table in [
      'transaction_outbox_entries',
      'sync_pending_changes',
    ]) {
      if (!db
          .select('PRAGMA table_info($table)')
          .any((c) => c['name'] == 'namespace')) {
        db.execute(
          "ALTER TABLE $table ADD COLUMN namespace TEXT NOT NULL DEFAULT 'legacy'",
        );
      }
    }
  }

  void _ensureLocalUserCardsSchema() {
    final columns = db
        .select('PRAGMA table_info(local_user_cards)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('last4')) {
      db.execute('ALTER TABLE local_user_cards ADD COLUMN last4 TEXT');
    }
  }

  void _ensureUserCategoriesSchema() {
    final columns = db
        .select('PRAGMA table_info(user_categories)')
        .map((row) => row['name'] as String)
        .toSet();
    for (final column in [
      'parent_category_id',
      'parent_user_category_id',
      'match_terms_json',
    ]) {
      if (columns.contains(column)) continue;
      final definition = column == 'match_terms_json'
          ? 'TEXT NOT NULL DEFAULT \'[]\''
          : 'TEXT';
      db.execute('ALTER TABLE user_categories ADD COLUMN $column $definition');
    }
  }

  /// CREATE TABLE IF NOT EXISTS does not update an existing table. Rebuild
  /// the small outbox once so card-less offline entries (cash, UPI, income,
  /// transfers) retain the same semantics as their online equivalents.
  void _ensureOutboxSchema() {
    final columns = db.select('PRAGMA table_info(transaction_outbox_entries)');
    final names = columns.map((row) => row['name'] as String).toSet();
    final userCardColumn = columns.firstWhere(
      (row) => row['name'] == 'user_card_id',
    );
    final needsRebuild =
        userCardColumn['notnull'] == 1 ||
        !names.contains('client_mutation_id') ||
        !names.contains('instrument') ||
        !names.contains('entry_kind') ||
        !names.contains('user_category_id');

    if (needsRebuild) {
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute('DROP TABLE IF EXISTS transaction_outbox_entries_new');
        db.execute('''
          CREATE TABLE transaction_outbox_entries_new (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            namespace TEXT NOT NULL DEFAULT 'legacy',
            user_card_id TEXT,
            client_mutation_id TEXT,
            amount_paise INTEGER NOT NULL,
            category_id TEXT,
            user_category_id TEXT,
            merchant_name TEXT,
            occurred_at INTEGER,
            note TEXT,
            instrument TEXT NOT NULL DEFAULT 'credit_card',
            entry_kind TEXT NOT NULL DEFAULT 'spend',
            created_at INTEGER NOT NULL,
            last_error TEXT
          )
        ''');
        final mutationExpression = names.contains('client_mutation_id')
            ? "COALESCE(client_mutation_id, 'legacy-outbox-' || id || '-' || created_at)"
            : "'legacy-outbox-' || id || '-' || created_at";
        final instrumentExpression = names.contains('instrument')
            ? "COALESCE(instrument, 'credit_card')"
            : "'credit_card'";
        final entryKindExpression = names.contains('entry_kind')
            ? "COALESCE(entry_kind, 'spend')"
            : "'spend'";
        final userCategoryExpression = names.contains('user_category_id')
            ? 'user_category_id'
            : 'NULL';
        final namespaceExpression = names.contains('namespace')
            ? 'namespace'
            : "'legacy'";
        db.execute('''
          INSERT INTO transaction_outbox_entries_new
            (id, namespace, user_card_id, client_mutation_id, amount_paise, category_id,
             user_category_id,
             merchant_name, occurred_at, note, instrument, entry_kind,
             created_at, last_error)
          SELECT id, $namespaceExpression, user_card_id, $mutationExpression, amount_paise,
                 category_id, $userCategoryExpression, merchant_name, occurred_at, note,
                 $instrumentExpression, $entryKindExpression,
                 created_at, last_error
          FROM transaction_outbox_entries
        ''');
        db.execute('DROP TABLE transaction_outbox_entries');
        db.execute(
          'ALTER TABLE transaction_outbox_entries_new RENAME TO transaction_outbox_entries',
        );
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }

    // Give every legacy queued write a stable identity before it retries.
    db.execute(
      "UPDATE transaction_outbox_entries "
      "SET client_mutation_id = 'legacy-outbox-' || id || '-' || created_at "
      "WHERE client_mutation_id IS NULL",
    );
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_transaction_outbox_mutation_id '
      'ON transaction_outbox_entries (client_mutation_id)',
    );
  }

  /// Tests pass [Database.memory()][sqlite3.openInMemory] directly via the
  /// named [AppDatabase.forTesting] constructor below; production opens a
  /// real file under the app's documents directory via [open].
  factory AppDatabase.forTesting(Database db) => AppDatabase._(db);

  /// `flutter test` sets FLUTTER_TEST=true in the process environment (a
  /// standard, documented mechanism — not a hand-rolled flag) — used here
  /// to skip path_provider's platform channel entirely rather than reach
  /// for it and hang. An unregistered path_provider channel call never
  /// resolves inside `testWidgets()` (confirmed empirically — it doesn't
  /// throw the way an unmocked MethodChannel call normally does), which
  /// would otherwise hang pumpAndSettle for every one of the 60+ existing
  /// widget tests that watch catalogueProvider/userCardsProvider/
  /// cardOverridesProvider transitively and have nothing to do with
  /// offline caching. A wall-clock `.timeout()` was tried first and
  /// dropped — it leaves a real dangling Timer if the test's own
  /// pumpAndSettle finishes before the timeout fires, which trips
  /// flutter_test's "!timersPending" invariant on teardown. Tests that
  /// want to exercise the real cache use AppDatabase.forTesting()/
  /// openInMemoryForTesting() directly, bypassing this check entirely.
  static Future<AppDatabase> open() async {
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return AppDatabase._(sqlite3.openInMemory());
    }
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'pandapay.sqlite');
    return openFile(dbPath);
  }

  /// Worker isolates open their own connection; a native database handle
  /// must never be shared across isolates.
  static AppDatabase openFile(String path) =>
      AppDatabase._(sqlite3.open(path), filePath: path);

  void saveProfileDisplayName(String namespace, String? displayName) {
    if (displayName == null || displayName.trim().isEmpty) return;
    db.execute(
      'INSERT OR REPLACE INTO profile_name_cache(namespace, display_name) VALUES(?, ?)',
      [namespace, displayName.trim()],
    );
  }

  String? profileDisplayName(String namespace) {
    try {
      final rows = db.select(
        'SELECT display_name FROM profile_name_cache WHERE namespace=? LIMIT 1',
        [namespace],
      );
      return rows.isEmpty ? null : rows.single['display_name'] as String?;
    } catch (_) {
      return null;
    }
  }

  void close() => db.dispose();
}

/// Test-only convenience — avoids every test needing its own
/// `AppDatabase.forTesting(sqlite3.openInMemory())` boilerplate.
AppDatabase openInMemoryForTesting() {
  return AppDatabase.forTesting(sqlite3.openInMemory());
}
