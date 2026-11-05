import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/catalogue_v2.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/v2_catalogue_fixtures.dart';

class _MapStore implements CatalogueCacheStore {
  final Map<String, String> values;
  _MapStore([Map<String, String>? initial]) : values = {...?initial};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> put(String key, String rawJson) async {
    values[key] = rawJson;
  }

  @override
  Future<void> clear(String key) async {
    values.remove(key);
  }
}

/// A store whose clear always fails: a stale-key cleanup must never fail the
/// write.
class _ClearFailsStore extends _MapStore {
  _ClearFailsStore([super.initial]);

  @override
  Future<void> clear(String key) async => throw StateError('clear failed');
}

/// Scriptable repository: v1 and v2 each return cards, throw, or hang.
class _FakeRepo implements CatalogueRepository, V2CatalogueSource {
  Future<CatalogueV2Fetch> Function()? onV2;
  Future<List<CardProduct>> Function()? onV1;
  int v2Calls = 0;
  int v1Calls = 0;

  @override
  Future<CatalogueV2Fetch> fetchV2() {
    v2Calls++;
    final run = onV2;
    if (run == null) throw ApiException('GET /catalogue?schema=2 failed: 404');
    return run();
  }

  @override
  Future<List<CardProduct>> fetchCatalogue() {
    v1Calls++;
    final run = onV1;
    if (run == null) throw ApiException('GET /catalogue failed: 500');
    return run();
  }
}

CatalogueV2Fetch _v2Fetch(Map<String, dynamic> body) {
  final raw = jsonEncode(body);
  return CatalogueV2Fetch(
    parseCatalogueBody(
      jsonDecode(raw),
      schema: 2,
      origin: CatalogueOrigin.liveV2,
      log: (_) {},
    ),
    raw,
  );
}

CatalogueLoader _loader(
  _FakeRepo repo, {
  CatalogueCacheStore? cache,
  Future<String> Function()? bundled,
  List<String>? logs,
  Duration timeout = const Duration(seconds: 15),
}) => CatalogueLoader(
  fetchV1: repo.fetchCatalogue,
  v2Source: repo,
  cache: cache,
  loadBundled: bundled,
  timeout: timeout,
  log: logs?.add ?? (_) {},
);

void main() {
  group('parseCatalogueBody (per-card tolerance, D15)', () {
    test('a card that throws is skipped and counted, the rest are kept', () {
      final logs = <String>[];
      final feed = parseCatalogueBody(
        v2Body([v2CardJson('a'), badCardJson('bad'), v2CardJson('b')]),
        schema: 2,
        origin: CatalogueOrigin.liveV2,
        log: logs.add,
      );
      expect(feed.cards.map((c) => c.id), ['a', 'b']);
      expect(feed.skippedCardIds, ['bad']);
      expect(feed.skippedCards, 1);
    });

    test('skipped-card logging records only the card id and error type', () {
      final logs = <String>[];
      parseCatalogueBody(
        v2Body([badCardJson('card-xyz', name: 'Secret Name'), v2CardJson('a')]),
        schema: 2,
        origin: CatalogueOrigin.liveV2,
        log: logs.add,
      );
      final skipLine = logs.firstWhere((l) => l.contains('card-xyz'));
      expect(skipLine, matches(RegExp(r'skipped card card-xyz \(\w+\)')));
      for (final line in logs) {
        expect(line, isNot(contains('Secret Name')));
        expect(line, isNot(contains('not_a_unit')));
      }
    });

    test('a non-map card element is skipped as "unknown", not thrown', () {
      final feed = parseCatalogueBody(
        {
          'schema': 2,
          'cards': [42, v2CardJson('a')],
        },
        schema: 2,
        origin: CatalogueOrigin.liveV2,
        log: (_) {},
      );
      expect(feed.cards.map((c) => c.id), ['a']);
      expect(feed.skippedCardIds, ['unknown']);
    });

    test('a v2 body fills the directory; a v1 parse leaves it empty', () {
      final v2 = parseCatalogueBody(
        v2Body([v2CardJson('a')]),
        schema: 2,
        origin: CatalogueOrigin.liveV2,
        log: (_) {},
      );
      expect(v2.directory.merchant('swiggy'), isNotNull);
      expect(v2.schema, 2);

      // A v1 source never carries a directory, even if the body had keys.
      final v1 = parseCatalogueBody(
        v2Body([v2CardJson('a')]),
        schema: 1,
        origin: CatalogueOrigin.cacheV1,
        log: (_) {},
      );
      expect(identical(v1.directory, MerchantDirectory.empty), isTrue);
    });

    test('a bad directory entry is skipped, the directory and cards survive',
        () {
      final logs = <String>[];
      final feed = parseCatalogueBody(
        v2Body(
          [v2CardJson('a')],
          merchants: [
            {'slug': 'swiggy', 'name': 'Swiggy', 'aliases': ['swiggy']},
            {'name': 'No slug at all'},
          ],
        ),
        schema: 2,
        origin: CatalogueOrigin.liveV2,
        log: logs.add,
      );
      expect(feed.cards, hasLength(1));
      expect(feed.directory.merchants.map((m) => m.slug), ['swiggy']);
      expect(logs.where((l) => l.contains('directory')), isNotEmpty);
      // The skipped entry's content is not logged.
      expect(logs.join(), isNot(contains('No slug at all')));
    });

    test('an unreadable directory never costs the cards', () {
      final feed = parseCatalogueBody(
        {
          'schema': 2,
          'cards': [v2CardJson('a')],
          'merchants': 'not a list',
        },
        schema: 2,
        origin: CatalogueOrigin.liveV2,
        log: (_) {},
      );
      expect(feed.cards, hasLength(1));
      expect(identical(feed.directory, MerchantDirectory.empty), isTrue);
    });
  });

  group('CatalogueLoader fallback order', () {
    test('no cache: v2 live wins and the raw v2 body is cached verbatim',
        () async {
      final body = v2Body([v2CardJson('a'), badCardJson('bad')]);
      final repo = _FakeRepo()..onV2 = () async => _v2Fetch(body);
      final store = _MapStore();
      final feed = await _loader(repo, cache: store).load();

      expect(feed.origin, CatalogueOrigin.liveV2);
      expect(feed.cards.map((c) => c.id), ['a']);
      expect(feed.directory.merchant('swiggy'), isNotNull);
      expect(repo.v1Calls, 0);
      // Lossless: the cached text is the response, bad card included.
      expect(store.values[catalogueV2CacheKey], jsonEncode(body));
      expect(store.values.containsKey(catalogueV1CacheKey), isFalse);
    });

    test('v2 cache hit is served first (cache-first policy unchanged)',
        () async {
      final repo = _FakeRepo();
      final store = _MapStore({
        catalogueV2CacheKey: jsonEncode(v2Body([v2CardJson('cached')])),
      });
      final feed = await _loader(repo, cache: store).load();
      expect(feed.origin, CatalogueOrigin.cacheV2);
      expect(feed.cards.single.id, 'cached');
      expect(repo.v2Calls + repo.v1Calls, 0);
    });

    test('v2 fails with a 404: v1 live is used, cached under the OLD key only',
        () async {
      final repo = _FakeRepo()
        ..onV1 = () async => [parseCard(v1CardJson('old'))];
      final store = _MapStore();
      final feed = await _loader(repo, cache: store).load();

      expect(repo.v2Calls, 1);
      expect(repo.v1Calls, 1);
      expect(feed.origin, CatalogueOrigin.liveV1);
      expect(feed.schema, 1);
      expect(identical(feed.directory, MerchantDirectory.empty), isTrue);
      expect(store.values.keys, [catalogueV1CacheKey]);
      final cachedV1 = jsonDecode(store.values[catalogueV1CacheKey]!) as Map;
      expect(cachedV1.containsKey('schema'), isFalse);
    });

    test('an older server that answers /catalogue?schema=2 with a v1 body '
        'falls through to v1 live', () async {
      final repo = _FakeRepo()
        ..onV2 = (() async => throw const CatalogueSchemaMismatch())
        ..onV1 = () async => [parseCard(v1CardJson('old'))];
      final feed = await _loader(repo, cache: _MapStore()).load();
      expect(feed.origin, CatalogueOrigin.liveV1);
    });

    test('an empty v2 body is a failed step, never an empty catalogue',
        () async {
      final repo = _FakeRepo()
        ..onV2 = (() async => _v2Fetch(v2Body(const [])))
        ..onV1 = () async => [parseCard(v1CardJson('old'))];
      final store = _MapStore();
      final feed = await _loader(repo, cache: store).load();
      expect(feed.origin, CatalogueOrigin.liveV1);
      expect(store.values.containsKey(catalogueV2CacheKey), isFalse);
    });

    test('a v2 timeout goes to the cache without a second wait for v1',
        () async {
      final repo = _FakeRepo()
        ..onV2 = (() => Completer<CatalogueV2Fetch>().future)
        ..onV1 = () async => [parseCard(v1CardJson('old'))];
      final store = _MapStore({
        catalogueV1CacheKey: jsonEncode(v1Body([v1CardJson('cached-v1')])),
      });
      final feed = await _loader(
        repo,
        cache: store,
        timeout: const Duration(milliseconds: 20),
      ).load();
      expect(repo.v1Calls, 0);
      expect(feed.origin, CatalogueOrigin.cacheV1);
      expect(feed.cards.single.id, 'cached-v1');
    });

    test('both live feeds fail: the old v1 cache key is a v1 last resort',
        () async {
      final repo = _FakeRepo();
      final store = _MapStore({
        catalogueV1CacheKey: jsonEncode(v1Body([v1CardJson('cached-v1')])),
      });
      final feed = await _loader(repo, cache: store).load();
      expect(feed.origin, CatalogueOrigin.cacheV1);
      expect(feed.cards.single.id, 'cached-v1');
      expect(feed.schema, 1);
      expect(identical(feed.directory, MerchantDirectory.empty), isTrue);
    });

    test('the v1 cache key is not read while a live feed works (last resort)',
        () async {
      final repo = _FakeRepo()
        ..onV2 = () async => _v2Fetch(v2Body([v2CardJson('live')]));
      final store = _MapStore({
        catalogueV1CacheKey: jsonEncode(v1Body([v1CardJson('stale-v1')])),
      });
      final feed = await _loader(repo, cache: store).load();
      expect(feed.cards.single.id, 'live');
    });

    test('everything fails: the bundled asset is parsed card by card',
        () async {
      final repo = _FakeRepo();
      final feed = await _loader(
        repo,
        cache: _MapStore(),
        bundled: () async =>
            jsonEncode(v1Body([v1CardJson('b1'), badCardJson('bad')])),
      ).load();
      expect(feed.origin, CatalogueOrigin.bundled);
      expect(feed.cards.map((c) => c.id), ['b1']);
      expect(feed.skippedCardIds, ['bad']);
    });

    test('a v2-shaped bundled asset brings its directory', () async {
      final feed = await _loader(
        _FakeRepo(),
        bundled: () async => jsonEncode(v2Body([v2CardJson('b1')])),
      ).load();
      expect(feed.origin, CatalogueOrigin.bundled);
      expect(feed.directory.merchant('swiggy'), isNotNull);
    });

    test('nothing at all: an empty feed, not a throw', () async {
      final feed = await _loader(_FakeRepo()).load();
      expect(feed.cards, isEmpty);
      expect(feed.origin, CatalogueOrigin.none);
    });

    test('a corrupt bundled asset is an empty feed, not a throw', () async {
      final feed = await _loader(
        _FakeRepo(),
        bundled: () async => 'not json',
      ).load();
      expect(feed.cards, isEmpty);
    });

    test('a repository that only speaks v1 never gets a v2 call', () async {
      final calls = <String>[];
      final loader = CatalogueLoader(
        fetchV1: () async {
          calls.add('v1');
          return [parseCard(v1CardJson('old'))];
        },
        cache: _MapStore(),
        log: (_) {},
      );
      final feed = await loader.load();
      expect(calls, ['v1']);
      expect(feed.origin, CatalogueOrigin.liveV1);
    });
  });

  group('cache keys never cross versions', () {
    test('a v1 body under the v2 key is ignored, not read as v2', () async {
      final repo = _FakeRepo();
      final store = _MapStore({
        catalogueV2CacheKey: jsonEncode(v1Body([v1CardJson('v1-in-v2-slot')])),
      });
      final feed = await _loader(repo, cache: store).load();
      expect(feed.cards, isEmpty);
    });

    test('a v2 body under the old key is read as v1 (no directory)', () async {
      final repo = _FakeRepo();
      final store = _MapStore({
        catalogueV1CacheKey: jsonEncode(v2Body([v2CardJson('x')])),
      });
      final feed = await _loader(repo, cache: store).load();
      expect(feed.origin, CatalogueOrigin.cacheV1);
      expect(identical(feed.directory, MerchantDirectory.empty), isTrue);
    });

    test('a live v1 success writes only the old key and never puts a v1 body '
        'under the v2 key (an unreadable v2 entry is cleared)', () async {
      final store = _MapStore({
        catalogueV2CacheKey: 'sentinel-not-json',
      });
      final repo = _FakeRepo()
        ..onV1 = () async => [parseCard(v1CardJson('old'))];
      await _loader(repo, cache: store).load();
      expect(store.values.containsKey(catalogueV2CacheKey), isFalse);
      expect(store.values.containsKey(catalogueV1CacheKey), isTrue);
    });
  });

  group('tolerant parse at the cache sites', () {
    test('v2 cache: one bad card is skipped, the rest are served', () async {
      final store = _MapStore({
        catalogueV2CacheKey: jsonEncode(
          v2Body([v2CardJson('a'), badCardJson('bad'), v2CardJson('b')]),
        ),
      });
      final feed = await _loader(_FakeRepo(), cache: store).load();
      expect(feed.origin, CatalogueOrigin.cacheV2);
      expect(feed.cards.map((c) => c.id), ['a', 'b']);
      expect(feed.skippedCardIds, ['bad']);
    });

    test('v1 cache: one bad card is skipped, the rest are served', () async {
      final store = _MapStore({
        catalogueV1CacheKey: jsonEncode(
          v1Body([badCardJson('bad'), v1CardJson('a')]),
        ),
      });
      final feed = await _loader(_FakeRepo(), cache: store).load();
      expect(feed.origin, CatalogueOrigin.cacheV1);
      expect(feed.cards.map((c) => c.id), ['a']);
    });

    test('a v2 cache with only bad cards falls through to live', () async {
      final repo = _FakeRepo()
        ..onV2 = () async => _v2Fetch(v2Body([v2CardJson('live')]));
      final store = _MapStore({
        catalogueV2CacheKey: jsonEncode(v2Body([badCardJson('bad')])),
      });
      final feed = await _loader(repo, cache: store).load();
      expect(feed.origin, CatalogueOrigin.liveV2);
    });

    test('a corrupt cache entry falls through to live', () async {
      final repo = _FakeRepo()
        ..onV2 = () async => _v2Fetch(v2Body([v2CardJson('live')]));
      final feed = await _loader(
        repo,
        cache: _MapStore({catalogueV2CacheKey: '{oops'}),
      ).load();
      expect(feed.origin, CatalogueOrigin.liveV2);
    });
  });

  group('the cached v2 body is lossless', () {
    test('a card whose only v2 marker is a skipped rule stays v2-shaped '
        'after a cache round trip', () async {
      // The rule has an unknown rule_role: the parser skips it but marks
      // the card v2. CardProduct.toJson would lose that marker, which is why
      // the raw body is cached rather than re-serialised cards.
      final card = {
        'id': 'marker',
        'name': 'Marker Card',
        'network': 'visa',
        'base_reward_unit': 'points_per_100',
        'base_reward_rate': 1,
        'point_value_inr': 0.25,
        'reward_rules': [
          {
            'id': 'r1',
            'category_id': null,
            'merchant_pattern': null,
            'rail': null,
            'unit': 'points_per_100',
            'rate': 5,
            'priority': 10,
            'rule_role': 'a_role_from_the_future',
          },
        ],
        'cap_rules': <Map<String, dynamic>>[],
      };
      final repo = _FakeRepo()
        ..onV2 = () async => _v2Fetch(v2Body([card]));
      final store = _MapStore();
      final live = await _loader(repo, cache: store).load();
      expect(live.cards.single.isV2Shaped, isTrue);

      // A new session: only the cache.
      final cached = await _loader(_FakeRepo(), cache: store).load();
      expect(cached.origin, CatalogueOrigin.cacheV2);
      expect(cached.cards.single.isV2Shaped, isTrue);
      expect(cached.cards.single.skippedRules.keys, ['r1']);
    });

    test('every v2 card field survives live -> cache -> reload', () async {
      final body = v2Body([
        v2CardJson('a', modelStatus: 'verified', categoryId: 'cat-dining'),
      ]);
      final store = _MapStore();
      final live = await _loader(
        _FakeRepo()..onV2 = () async => _v2Fetch(body),
        cache: store,
      ).load();
      final reloaded = await _loader(_FakeRepo(), cache: store).load();

      final a = live.cards.single;
      final b = reloaded.cards.single;
      expect(b.toJson(), a.toJson());
      expect(b.modelStatus, ModelStatus.verified);
      expect(b.capRules.single.capKind, CapKind.bonusPoints);
      expect(b.capRules.single.capAmount, 1500);
      expect(b.capRules.single.targets, ['a-rule']);
      expect(reloaded.directory.toJson(), live.directory.toJson());
    });
  });

  group('refreshCache (background refresh)', () {
    test('writes the v2 key when v2 is live', () async {
      final store = _MapStore();
      final repo = _FakeRepo()
        ..onV2 = () async => _v2Fetch(v2Body([v2CardJson('a')]));
      expect(await _loader(repo, cache: store).refreshCache(), isTrue);
      expect(store.values.keys, [catalogueV2CacheKey]);
    });

    test('falls back to v1 and writes only the old key', () async {
      final store = _MapStore();
      final repo = _FakeRepo()
        ..onV1 = () async => [parseCard(v1CardJson('old'))];
      expect(await _loader(repo, cache: store).refreshCache(), isTrue);
      expect(store.values.keys, [catalogueV1CacheKey]);
    });

    test('a v1 fallback drops a stale v2 body so cache-first stops serving it',
        () async {
      // An earlier refresh cached v2; the server now only answers v1.
      final store = _MapStore({
        catalogueV2CacheKey: jsonEncode(v2Body([v2CardJson('stale-v2')])),
      });
      final repo = _FakeRepo()
        ..onV1 = () async => [parseCard(v1CardJson('fresh-v1'))];
      expect(await _loader(repo, cache: store).refreshCache(), isTrue);
      expect(store.values.containsKey(catalogueV2CacheKey), isFalse);
      expect(store.values.containsKey(catalogueV1CacheKey), isTrue);

      // The next load no longer serves the stale v2 cards.
      final feed = await _loader(repo, cache: store).load();
      expect(feed.cards.map((c) => c.id), ['fresh-v1']);
      expect(feed.origin, CatalogueOrigin.liveV1);
    });

    test('a failure to clear the stale v2 key does not fail the refresh',
        () async {
      final store = _ClearFailsStore({
        catalogueV2CacheKey: jsonEncode(v2Body([v2CardJson('stale-v2')])),
      });
      final repo = _FakeRepo()
        ..onV1 = () async => [parseCard(v1CardJson('fresh-v1'))];
      expect(await _loader(repo, cache: store).refreshCache(), isTrue);
      expect(store.values.containsKey(catalogueV1CacheKey), isTrue);
    });

    test('a v2 success keeps writing the v2 key and leaves the v1 key alone',
        () async {
      final store = _MapStore({
        catalogueV1CacheKey: jsonEncode(v1Body([v1CardJson('old')])),
      });
      final repo = _FakeRepo()
        ..onV2 = () async => _v2Fetch(v2Body([v2CardJson('a')]));
      await _loader(repo, cache: store).refreshCache();
      expect(store.values.containsKey(catalogueV2CacheKey), isTrue);
      expect(
        jsonDecode(store.values[catalogueV1CacheKey]!)['cards'],
        hasLength(1),
      );
    });

    test('writes nothing when both feeds fail', () async {
      final store = _MapStore({catalogueV2CacheKey: 'keep'});
      expect(await _loader(_FakeRepo(), cache: store).refreshCache(), isFalse);
      expect(store.values, {catalogueV2CacheKey: 'keep'});
    });
  });

  group('HttpCatalogueRepository', () {
    test('fetchV2 asks for ?schema=2 and returns the raw body', () async {
      Uri? requested;
      final body = jsonEncode(v2Body([v2CardJson('a'), badCardJson('bad')]));
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(body, 200);
        }),
      );
      final fetched = await repo.fetchV2();
      expect(requested.toString(), 'https://api.test/catalogue?schema=2');
      expect(fetched.rawBody, body);
      expect(fetched.feed.cards.map((c) => c.id), ['a']);
      expect(fetched.feed.skippedCardIds, ['bad']);
    });

    test('fetchV2 rejects a v1 body from an older server', () async {
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient(
          (_) async => http.Response(jsonEncode(v1Body([v1CardJson('a')])), 200),
        ),
      );
      expect(repo.fetchV2(), throwsA(isA<CatalogueSchemaMismatch>()));
    });

    test('fetchV2 throws on a non-200 status', () async {
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((_) async => http.Response('nope', 404)),
      );
      expect(repo.fetchV2(), throwsA(isA<ApiException>()));
    });

    test('fetchCatalogue hits /catalogue (v1) and skips a bad card', () async {
      Uri? requested;
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode(v1Body([v1CardJson('a'), badCardJson('bad')])),
            200,
          );
        }),
      );
      final cards = await repo.fetchCatalogue();
      expect(requested.toString(), 'https://api.test/catalogue');
      expect(cards.map((c) => c.id), ['a']);
    });

    test('the loader prefers v2 over a repository that also serves v1',
        () async {
      final paths = <String>[];
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((request) async {
          paths.add(request.url.toString());
          return http.Response(jsonEncode(v2Body([v2CardJson('a')])), 200);
        }),
      );
      final feed = await repo.loader(cache: _MapStore(), log: (_) {}).load();
      expect(feed.origin, CatalogueOrigin.liveV2);
      expect(paths, ['https://api.test/catalogue?schema=2']);
    });
  });
}
