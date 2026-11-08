import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'local/response_cache.dart';

/// Card Rewards Phase 1 (WP9) — the app side of the two catalogue feeds
/// (plan C2): `GET /catalogue?schema=2` (cards + merchant/platform
/// directory) and the unchanged v1 `GET /catalogue`.
///
/// Everything here is pure Dart over small interfaces, so the fallback order
/// and the parse-per-card guarantees are unit-tested without Flutter. The
/// Riverpod wiring stays in `providers.dart`, kept to a few lines.

/// The v2 body, stored losslessly (the raw response) under its own key.
/// `CardProduct.toJson` is not lossless for v2 (it drops what the parser
/// skipped and the v2-shaped marker), so the raw body is cached instead.
const String catalogueV2CacheKey = 'catalogue.v2';

/// Today's key: only ever holds a v1 body (`{"cards": [...]}`). It is read
/// as a v1 last resort and never as v2.
const String catalogueV1CacheKey = 'catalogue';

const String bundledCatalogueAsset = 'assets/data/bundled_catalogue.json';

/// Where a [CatalogueFeed] came from. For diagnostics and tests only.
enum CatalogueOrigin { liveV2, liveV1, cacheV2, cacheV1, bundled, none }

/// Receives one line per skipped card or directory problem. Lines carry a
/// card id and an error type only: never an amount, a card number or a
/// merchant name.
typedef CatalogueLog = void Function(String message);

void _defaultLog(String message) => debugPrint(message);

/// The parsed catalogue plus the merchant directory that came with it.
class CatalogueFeed {
  final List<CardProduct> cards;

  /// [MerchantDirectory.empty] for every v1 source.
  final MerchantDirectory directory;
  final CatalogueOrigin origin;

  /// 2 when the cards and directory came from a v2 body, 1 otherwise.
  final int schema;

  /// Cards that threw while parsing and were skipped (D15).
  final List<String> skippedCardIds;

  const CatalogueFeed({
    required this.cards,
    required this.directory,
    required this.origin,
    required this.schema,
    this.skippedCardIds = const [],
  });

  static final CatalogueFeed empty = CatalogueFeed(
    cards: const [],
    directory: MerchantDirectory.empty,
    origin: CatalogueOrigin.none,
    schema: 1,
  );

  int get skippedCards => skippedCardIds.length;
}

/// Top-level so it can run in a `compute` isolate.
Object? decodeCatalogueJson(String raw) => jsonDecode(raw);

/// A v2 response: the parsed feed and the raw body to cache.
class CatalogueV2Fetch {
  final CatalogueFeed feed;
  final String rawBody;
  const CatalogueV2Fetch(this.feed, this.rawBody);
}

/// Implemented by repositories that can serve `GET /catalogue?schema=2`.
/// Kept apart from `CatalogueRepository` so the many existing fakes that
/// only implement `fetchCatalogue()` keep compiling: the loader treats such
/// a repository as v1 only.
abstract class V2CatalogueSource {
  /// Throws on any transport, HTTP or shape failure, including a body that
  /// is not `schema: 2` (an older server that ignores the query parameter).
  Future<CatalogueV2Fetch> fetchV2();
}

/// Thrown when `?schema=2` answered with something that is not a v2 body.
class CatalogueSchemaMismatch implements Exception {
  const CatalogueSchemaMismatch();
  @override
  String toString() => 'CatalogueSchemaMismatch';
}

/// Parses a decoded catalogue body, card by card (D15): a card that throws
/// is skipped and counted, never the whole list. Throws only when the body
/// itself has no `cards` list, which the caller treats as a failed source.
///
/// [schema] 2 also reads the `merchants` / `platforms` keys through
/// `MerchantDirectory.fromJson` (tolerant per entry). Anything else leaves
/// the directory empty, so a v1 source never carries a directory.
CatalogueFeed parseCatalogueBody(
  Object? decoded, {
  required int schema,
  required CatalogueOrigin origin,
  CatalogueLog? log,
}) {
  final emit = log ?? _defaultLog;
  final body = decoded as Map<String, dynamic>;
  final rawCards = body['cards'] as List;
  final cards = <CardProduct>[];
  final skipped = <String>[];
  for (final raw in rawCards) {
    try {
      // D32a: a schema-1 body is parsed in v1 mode. Its rows are
      // `to_jsonb(row)` and carry the v2 columns, which the released parser
      // ignored; reading them would turn a v1-served card v2-shaped without
      // the precise v2 rows, and over-state.
      cards.add(
        CardProductJson.fromJson(raw as Map<String, dynamic>, v1Mode: schema < 2),
      );
    } catch (error) {
      final id = raw is Map && raw['id'] is String
          ? raw['id'] as String
          : 'unknown';
      skipped.add(id);
      // Card id and error type only (no values, no names).
      emit('catalogue: skipped card $id (${error.runtimeType})');
    }
  }
  if (skipped.isNotEmpty) {
    emit('catalogue: ${skipped.length} card(s) skipped, ${cards.length} kept');
  }

  var directory = MerchantDirectory.empty;
  if (schema >= 2) {
    try {
      directory = MerchantDirectory.fromJson(body);
      if (directory.parseWarnings.isNotEmpty) {
        emit(
          'catalogue: ${directory.parseWarnings.length} directory '
          'entr${directory.parseWarnings.length == 1 ? 'y' : 'ies'} skipped',
        );
      }
    } catch (error) {
      emit('catalogue: directory unreadable (${error.runtimeType})');
      directory = MerchantDirectory.empty;
    }
  }
  return CatalogueFeed(
    cards: cards,
    directory: directory,
    origin: origin,
    schema: schema,
    skippedCardIds: skipped,
  );
}

/// The key/value store the loader caches in. `ResponseCache` is adapted by
/// [ResponseCacheCatalogueStore]; tests use a map.
abstract class CatalogueCacheStore {
  Future<String?> get(String key);
  Future<void> put(String key, String rawJson);

  /// Removes [key] (a no-op when absent).
  Future<void> clear(String key);
}

class ResponseCacheCatalogueStore implements CatalogueCacheStore {
  final ResponseCache _cache;
  const ResponseCacheCatalogueStore(this._cache);

  @override
  Future<String?> get(String key) => _cache.get(key);

  @override
  Future<void> put(String key, String rawJson) => _cache.put(key, rawJson);

  @override
  Future<void> clear(String key) => _cache.clear(key);
}

class _Live {
  final CatalogueFeed feed;

  /// Set for a v2 response: the raw body to cache losslessly.
  final String? rawV2Body;

  /// True only when the server answered `?schema=2` with something that is
  /// not v2 (an older server, [CatalogueSchemaMismatch]): the cached v2 body
  /// is then stale and is dropped. A transient v2 failure (5xx, 429, a
  /// transport error, a body with no readable card) never clears it (D32a).
  final bool olderServer;
  const _Live(this.feed, this.rawV2Body, {this.olderServer = false});
}

/// The catalogue load, in this order (plan C2, WP9):
///
/// 1. the v2 cache, if it holds at least one readable card (today's
///    cache-first policy; the refresh policy is unchanged);
/// 2. live v2 (`/catalogue?schema=2`), cached losslessly under
///    [catalogueV2CacheKey];
/// 3. live v1 (`/catalogue`, an older server), cached under the old
///    [catalogueV1CacheKey];
/// 4. the old v1 cache key, as a v1 last resort;
/// 5. the bundled asset.
///
/// Every step parses card by card. A step that yields no cards is a failed
/// step, never an empty catalogue.
class CatalogueLoader {
  /// The v1 fetch (`CatalogueRepository.fetchCatalogue`).
  final Future<List<CardProduct>> Function() fetchV1;

  /// Null for a repository that only speaks v1.
  final V2CatalogueSource? v2Source;
  final CatalogueCacheStore? cache;
  final Future<String> Function()? loadBundled;
  final Duration timeout;
  final CatalogueLog? log;

  CatalogueLoader({
    required this.fetchV1,
    this.v2Source,
    this.cache,
    this.loadBundled,
    this.timeout = const Duration(seconds: 15),
    this.log,
  });

  CatalogueLog get _log => log ?? _defaultLog;

  Future<CatalogueFeed> load() async {
    final cached = await _readCache(
      catalogueV2CacheKey,
      schema: 2,
      origin: CatalogueOrigin.cacheV2,
    );
    if (cached != null) return cached;

    final live = await _fetchLive();
    if (live != null) {
      await _writeCache(live);
      return live.feed;
    }

    final v1Cached = await _readCache(
      catalogueV1CacheKey,
      schema: 1,
      origin: CatalogueOrigin.cacheV1,
    );
    if (v1Cached != null) return v1Cached;

    final bundled = await _readBundled();
    if (bundled != null) return bundled;
    return CatalogueFeed.empty;
  }

  /// The background refresh: fetch live (v2, else v1) and cache it. Returns
  /// whether something was cached.
  Future<bool> refreshCache() async {
    if (cache == null) return false;
    final live = await _fetchLive();
    if (live == null) return false;
    return _writeCache(live);
  }

  Future<_Live?> _fetchLive() async {
    final source = v2Source;
    var skipV1 = false;
    var olderServer = false;
    if (source != null) {
      try {
        final fetched = await source.fetchV2().timeout(timeout);
        if (fetched.feed.cards.isNotEmpty) {
          return _Live(fetched.feed, fetched.rawBody);
        }
      } on TimeoutException {
        // A hung network will not answer the v1 request either: go to the
        // cache rather than doubling the wait.
        skipV1 = true;
      } on CatalogueSchemaMismatch {
        olderServer = true;
        _log('catalogue: v2 fetch failed (CatalogueSchemaMismatch)');
      } catch (error) {
        _log('catalogue: v2 fetch failed (${error.runtimeType})');
      }
    }
    if (skipV1) return null;
    try {
      final cards = await fetchV1().timeout(timeout);
      if (cards.isNotEmpty) {
        return _Live(
          CatalogueFeed(
            cards: cards,
            directory: MerchantDirectory.empty,
            origin: CatalogueOrigin.liveV1,
            schema: 1,
          ),
          null,
          olderServer: olderServer,
        );
      }
    } catch (error) {
      _log('catalogue: v1 fetch failed (${error.runtimeType})');
    }
    return null;
  }

  Future<bool> _writeCache(_Live live) async {
    final store = cache;
    if (store == null) return false;
    try {
      final raw = live.rawV2Body;
      if (raw != null) {
        await store.put(catalogueV2CacheKey, raw);
      } else {
        await store.put(
          catalogueV1CacheKey,
          jsonEncode({'cards': live.feed.cards.map((c) => c.toJson()).toList()}),
        );
        // The cards were parsed in v1 mode, so this is the v1 body without
        // v2 keys: an offline start reads the same v1-shaped card.
        //
        // An OLDER SERVER (it answered ?schema=2 with a v1 body) no longer
        // serves v2, so a v2 body cached earlier is stale and cache-first
        // would keep serving it for ever: drop it. A transient v2 failure
        // (5xx, 429, a transport error, no readable card) says nothing about
        // the server: the good v2 cache stays (D32a). A failed clear never
        // fails the write above.
        if (live.olderServer) {
          try {
            await store.clear(catalogueV2CacheKey);
          } catch (error) {
            _log(
              'catalogue: stale v2 cache not cleared (${error.runtimeType})',
            );
          }
        }
      }
      return true;
    } catch (error) {
      _log('catalogue: cache write failed (${error.runtimeType})');
      return false;
    }
  }

  Future<CatalogueFeed?> _readCache(
    String key, {
    required int schema,
    required CatalogueOrigin origin,
  }) async {
    final store = cache;
    if (store == null) return null;
    try {
      final raw = await store.get(key);
      if (raw == null) return null;
      // The cached catalogue is large; decode it off the UI thread.
      final decoded = await compute(decodeCatalogueJson, raw);
      // A body under the v2 key must say so: an old v1 body is never read
      // as v2.
      if (schema == 2 && !(decoded is Map && decoded['schema'] == 2)) {
        return null;
      }
      final feed = parseCatalogueBody(
        decoded,
        schema: schema,
        origin: origin,
        log: log,
      );
      return feed.cards.isEmpty ? null : feed;
    } catch (error) {
      _log('catalogue: cache read failed (${error.runtimeType})');
      return null;
    }
  }

  Future<CatalogueFeed?> _readBundled() async {
    final load = loadBundled;
    if (load == null) return null;
    try {
      final decoded = jsonDecode(await load());
      final schema = decoded is Map && decoded['schema'] == 2 ? 2 : 1;
      final feed = parseCatalogueBody(
        decoded,
        schema: schema,
        origin: CatalogueOrigin.bundled,
        log: log,
      );
      return feed.cards.isEmpty ? null : feed;
    } catch (error) {
      _log('catalogue: bundled asset unreadable (${error.runtimeType})');
      return null;
    }
  }
}
