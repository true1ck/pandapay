import 'app_database.dart';

/// Thin key/value wrapper over [AppDatabase]'s cached_responses table — see
/// that table's doc-comment for why this stores raw JSON text rather than
/// parsed domain objects.
class ResponseCache {
  final AppDatabase _db;
  ResponseCache(this._db);

  Future<void> put(String key, String rawJson) async {
    _db.db.execute(
      'INSERT OR REPLACE INTO cached_responses (key, raw_json, fetched_at) VALUES (?, ?, ?)',
      [key, rawJson, DateTime.now().millisecondsSinceEpoch],
    );
  }

  Future<String?> get(String key) async {
    final rows = _db.db.select('SELECT raw_json FROM cached_responses WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.single['raw_json'] as String;
  }

  Future<void> clear(String key) async {
    _db.db.execute('DELETE FROM cached_responses WHERE key = ?', [key]);
  }
}
