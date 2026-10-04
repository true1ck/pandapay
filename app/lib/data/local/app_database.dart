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
/// parser a live fetch already used. Deliberately NOT a relational mirror
/// of card_products/user_cards/etc. — see the plan's Architecture note.
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

CREATE TABLE IF NOT EXISTS transaction_outbox_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_card_id TEXT,
  client_mutation_id TEXT,
  amount_paise INTEGER NOT NULL,
  category_id TEXT,
  merchant_name TEXT,
  occurred_at INTEGER,
  note TEXT,
  instrument TEXT NOT NULL DEFAULT 'credit_card',
  entry_kind TEXT NOT NULL DEFAULT 'spend',
  created_at INTEGER NOT NULL,
  last_error TEXT
);

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
  is_default INTEGER NOT NULL DEFAULT 0,
  is_archived INTEGER NOT NULL DEFAULT 0,
  sort_order REAL NOT NULL,
  created_at INTEGER NOT NULL
);

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
''';

class AppDatabase {
  final Database db;

  AppDatabase._(this.db) {
    db.execute(_schema);
    _ensureOutboxSchema();
  }

  /// CREATE TABLE IF NOT EXISTS does not update an existing table. Rebuild
  /// the small outbox once so card-less offline entries (cash, UPI, income,
  /// transfers) retain the same semantics as their online equivalents.
  void _ensureOutboxSchema() {
    final columns = db.select('PRAGMA table_info(transaction_outbox_entries)');
    final names = columns.map((row) => row['name'] as String).toSet();
    final userCardColumn = columns.firstWhere((row) => row['name'] == 'user_card_id');
    final needsRebuild =
        userCardColumn['notnull'] == 1 ||
        !names.contains('client_mutation_id') ||
        !names.contains('instrument') ||
        !names.contains('entry_kind');

    if (needsRebuild) {
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute('DROP TABLE IF EXISTS transaction_outbox_entries_new');
        db.execute('''
          CREATE TABLE transaction_outbox_entries_new (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_card_id TEXT,
            client_mutation_id TEXT,
            amount_paise INTEGER NOT NULL,
            category_id TEXT,
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
        final entryKindExpression = names.contains('entry_kind') ? "COALESCE(entry_kind, 'spend')" : "'spend'";
        db.execute('''
          INSERT INTO transaction_outbox_entries_new
            (id, user_card_id, client_mutation_id, amount_paise, category_id,
             merchant_name, occurred_at, note, instrument, entry_kind,
             created_at, last_error)
          SELECT id, user_card_id, $mutationExpression, amount_paise,
                 category_id, merchant_name, occurred_at, note,
                 $instrumentExpression, $entryKindExpression,
                 created_at, last_error
          FROM transaction_outbox_entries
        ''');
        db.execute('DROP TABLE transaction_outbox_entries');
        db.execute('ALTER TABLE transaction_outbox_entries_new RENAME TO transaction_outbox_entries');
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
    return AppDatabase._(sqlite3.open(dbPath));
  }

  void close() => db.dispose();
}

/// Test-only convenience — avoids every test needing its own
/// `AppDatabase.forTesting(sqlite3.openInMemory())` boilerplate.
AppDatabase openInMemoryForTesting() {
  return AppDatabase.forTesting(sqlite3.openInMemory());
}
