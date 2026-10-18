import 'dart:convert';
import '../user_cards_repository.dart';
import 'app_database.dart';
import 'financial_store.dart';

class CachedResponse {
  final String rawJson;
  final DateTime fetchedAt;

  const CachedResponse({required this.rawJson, required this.fetchedAt});
}

/// Thin key/value wrapper over [AppDatabase]'s cached_responses table — see
/// that table's doc-comment for why this stores raw JSON text rather than
/// parsed domain objects.
class ResponseCache {
  final AppDatabase _db;
  ResponseCache(this._db);
  late final FinancialStore financialStore = FinancialStore(_db);
  void markAccountStale(String namespace) {
    _db.db.execute(
      'INSERT OR IGNORE INTO cache_refresh_requests SELECT key FROM cached_responses WHERE substr(key,1,length(?))=?',
      ['$namespace:', '$namespace:'],
    );
  }

  bool needsRefresh(String key) => _db.db.select(
    'SELECT 1 FROM cache_refresh_requests WHERE key=?',
    [key],
  ).isNotEmpty;

  void migratePrefix(String oldPrefix, String newPrefix) {
    final rows = _db.db.select(
      'SELECT key,raw_json,fetched_at FROM cached_responses WHERE substr(key,1,length(?))=?',
      [oldPrefix, oldPrefix],
    );
    if (rows.isEmpty) return;
    _db.db.execute('SAVEPOINT migrate_cache_namespace');
    try {
      for (final row in rows) {
        final key =
            newPrefix + (row['key'] as String).substring(oldPrefix.length);
        _db.db.execute(
          'INSERT OR IGNORE INTO cached_responses VALUES (?,?,?)',
          [key, row['raw_json'], row['fetched_at']],
        );
        _db.db.execute('DELETE FROM cached_responses WHERE key=?', [
          row['key'],
        ]);
      }
      _db.db.execute('RELEASE SAVEPOINT migrate_cache_namespace');
    } catch (_) {
      _db.db.execute('ROLLBACK TO SAVEPOINT migrate_cache_namespace');
      _db.db.execute('RELEASE SAVEPOINT migrate_cache_namespace');
      rethrow;
    }
  }

  Future<void> put(String key, String rawJson) async {
    // Validate private entity snapshots before publishing them. The entity
    // store is the shared read source; blobs remain for legacy consumers.
    final cardsMatch = RegExp(
      r'^(.*):(user_cards|user_cards_with_archived)$',
    ).firstMatch(key);
    if (cardsMatch != null) {
      List<UserCard>? cards;
      try {
        final body = jsonDecode(rawJson) as Map<String, dynamic>;
        cards = (body['userCards'] as List)
            .map((r) => UserCard.fromJson(Map<String, dynamic>.from(r as Map)))
            .toList();
      } on FormatException {
        /* A legacy blob is not an entity write. */
      } on TypeError {
        /* Leave the last valid entities intact. */
      }
      if (cards != null) {
        financialStore.replaceCards(
          cardsMatch[1]!,
          cards,
          archived: cardsMatch[2] == 'user_cards_with_archived',
        );
      }
    }
    _db.db.execute(
      'INSERT OR REPLACE INTO cached_responses (key, raw_json, fetched_at) VALUES (?, ?, ?)',
      [key, rawJson, DateTime.now().millisecondsSinceEpoch],
    );
    _db.db.execute('DELETE FROM cache_refresh_requests WHERE key=?', [key]);
  }

  Future<String?> get(String key) async {
    return (await read(key))?.rawJson;
  }

  /// Reads the body and the write time together. Providers that fall back to
  /// stale data need both: the body to render and the timestamp to tell the
  /// user that it is cached rather than a fresh server response.
  Future<CachedResponse?> read(String key) async {
    final rows = _db.db.select(
      'SELECT raw_json, fetched_at FROM cached_responses WHERE key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return CachedResponse(
      rawJson: rows.single['raw_json'] as String,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(
        rows.single['fetched_at'] as int,
      ),
    );
  }

  /// Account-scoped transaction snapshots may be stored for different
  /// Insights date ranges. Return them newest first so report fallbacks can
  /// combine the rows without depending on one particular screen's cache key.
  Future<List<CachedResponse>> readPrefix(String prefix) async {
    final rows = _db.db.select(
      'SELECT raw_json, fetched_at FROM cached_responses WHERE substr(key, 1, length(?)) = ? ORDER BY fetched_at DESC',
      [prefix, prefix],
    );
    return [
      for (final row in rows)
        CachedResponse(
          rawJson: row['raw_json'] as String,
          fetchedAt: DateTime.fromMillisecondsSinceEpoch(
            row['fetched_at'] as int,
          ),
        ),
    ];
  }

  /// When [key] was last written, or null if it was never cached.
  ///
  /// [put] has always recorded `fetched_at`; nothing read it until design
  /// 21's offline state ("Showing your last synced balances from 6:40 PM")
  /// needed a timestamp to name. Kept separate from [get] rather than
  /// returning a record from it, so the many existing call sites that only
  /// want the body stay unchanged.
  Future<DateTime?> fetchedAt(String key) async {
    final rows = _db.db.select(
      'SELECT fetched_at FROM cached_responses WHERE key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      rows.single['fetched_at'] as int,
    );
  }

  /// The most recent write across every cached endpoint — what the offline
  /// banner means by "last synced". A single per-key timestamp would be
  /// misleading there: the banner sits above a screen built from several
  /// cached responses at once (catalogue + user cards + overrides), so the
  /// newest of them is the honest answer to "how stale is what I'm seeing".
  Future<DateTime?> lastFetchedAt({String? keyPrefix}) async {
    final rows = keyPrefix == null
        ? _db.db.select(
            'SELECT MAX(fetched_at) AS newest FROM cached_responses',
          )
        : _db.db.select(
            'SELECT MAX(fetched_at) AS newest FROM cached_responses WHERE key LIKE ?',
            ['$keyPrefix%'],
          );
    final newest = rows.single['newest'];
    if (newest == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(newest as int);
  }

  Future<void> clear(String key) async {
    _db.db.execute('DELETE FROM cached_responses WHERE key = ?', [key]);
  }

  /// Removes every cached response under [prefix]. Private response keys are
  /// namespaced by account, so sign-out can erase the whole account snapshot
  /// without maintaining a separate endpoint list.
  Future<void> clearPrefix(String prefix) async {
    if (prefix.endsWith(':')) {
      financialStore.clear(prefix.substring(0, prefix.length - 1));
    }
    _db.db.execute('DELETE FROM cached_responses WHERE key LIKE ?', [
      '$prefix%',
    ]);
  }
}
