import 'app_database.dart';

/// Thin key/value wrapper over [AppDatabase]'s cached_responses table — see
/// that table's doc-comment for why this stores raw JSON text rather than
/// parsed domain objects.
class ResponseCache {
  final AppDatabase _db;
  ResponseCache(this._db);

  Future<void> put(String key, String rawJson) async {
    _db.db.execute('INSERT OR REPLACE INTO cached_responses (key, raw_json, fetched_at) VALUES (?, ?, ?)', [
      key,
      rawJson,
      DateTime.now().millisecondsSinceEpoch,
    ]);
  }

  Future<String?> get(String key) async {
    final rows = _db.db.select('SELECT raw_json FROM cached_responses WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.single['raw_json'] as String;
  }

  /// When [key] was last written, or null if it was never cached.
  ///
  /// [put] has always recorded `fetched_at`; nothing read it until design
  /// 21's offline state ("Showing your last synced balances from 6:40 PM")
  /// needed a timestamp to name. Kept separate from [get] rather than
  /// returning a record from it, so the many existing call sites that only
  /// want the body stay unchanged.
  Future<DateTime?> fetchedAt(String key) async {
    final rows = _db.db.select('SELECT fetched_at FROM cached_responses WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.single['fetched_at'] as int);
  }

  /// The most recent write across every cached endpoint — what the offline
  /// banner means by "last synced". A single per-key timestamp would be
  /// misleading there: the banner sits above a screen built from several
  /// cached responses at once (catalogue + user cards + overrides), so the
  /// newest of them is the honest answer to "how stale is what I'm seeing".
  Future<DateTime?> lastFetchedAt() async {
    final rows = _db.db.select('SELECT MAX(fetched_at) AS newest FROM cached_responses');
    final newest = rows.single['newest'];
    if (newest == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(newest as int);
  }

  Future<void> clear(String key) async {
    _db.db.execute('DELETE FROM cached_responses WHERE key = ?', [key]);
  }
}
