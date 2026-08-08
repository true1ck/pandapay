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
  user_card_id TEXT NOT NULL,
  amount_paise INTEGER NOT NULL,
  category_id TEXT,
  merchant_name TEXT,
  occurred_at INTEGER,
  note TEXT,
  created_at INTEGER NOT NULL,
  last_error TEXT
);
''';

class AppDatabase {
  final Database db;

  AppDatabase._(this.db) {
    db.execute(_schema);
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
