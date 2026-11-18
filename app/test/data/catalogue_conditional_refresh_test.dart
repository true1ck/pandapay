import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/catalogue_v2.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/v2_catalogue_fixtures.dart';

/// The catalogue is the largest static download. The server already answers a
/// matching `If-None-Match` with a 304 before any heavy query; the app used to
/// never ask, so every open and resume re-downloaded, re-parsed and re-stored
/// the whole body. These tests pin the safe way to ask.
class _MapStore implements CatalogueCacheStore {
  final Map<String, String> values;
  final puts = <String>[];
  _MapStore([Map<String, String>? initial]) : values = {...?initial};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> put(String key, String rawJson) async {
    puts.add(key);
    values[key] = rawJson;
  }

  @override
  Future<void> clear(String key) async {
    values.remove(key);
  }
}

class _ValidatorWriteFails extends _MapStore {
  _ValidatorWriteFails();
  @override
  Future<void> put(String key, String rawJson) async {
    if (key == catalogueV2ValidatorCacheKey) throw StateError('disk full');
    return super.put(key, rawJson);
  }
}

/// A repository that serves v2 and answers `If-None-Match` like the server.
class _Server implements CatalogueRepository, ConditionalV2CatalogueSource {
  Future<CatalogueV2Fetch?> Function(String? etag)? onFetch;
  final sentValidators = <String?>[];
  int fullFetches = 0;

  @override
  Future<CatalogueV2Fetch> fetchV2() async {
    sentValidators.add(null);
    fullFetches++;
    return (await onFetch!(null))!;
  }

  @override
  Future<CatalogueV2Fetch?> fetchV2IfChanged(String etag) async {
    sentValidators.add(etag);
    final answer = await onFetch!(etag);
    if (answer != null) fullFetches++;
    return answer;
  }

  @override
  Future<List<CardProduct>> fetchCatalogue() async =>
      throw ApiException('GET /catalogue failed: 500');
}

CatalogueV2Fetch _fetch(List<String> ids, {String? etag}) {
  final raw = jsonEncode(v2Body([for (final id in ids) v2CardJson(id)]));
  return CatalogueV2Fetch(
    parseCatalogueBody(
      jsonDecode(raw),
      schema: 2,
      origin: CatalogueOrigin.liveV2,
      log: (_) {},
    ),
    raw,
    etag: etag,
  );
}

CatalogueLoader _loader(_Server server, CatalogueCacheStore store) =>
    CatalogueLoader(
      fetchV1: server.fetchCatalogue,
      v2Source: server,
      cache: store,
      log: (_) {},
    );

void main() {
  group('CatalogueLoader.refreshCache with a validator', () {
    late _Server server;
    late _MapStore store;
    late CatalogueLoader loader;
    var currentEtag = '"v1-gz"';
    var currentIds = ['a', 'b'];

    setUp(() {
      currentEtag = '"v1-gz"';
      currentIds = ['a', 'b'];
      store = _MapStore();
      server = _Server()
        ..onFetch = (etag) async {
          if (etag != null && etag == currentEtag) return null; // 304
          return _fetch(currentIds, etag: currentEtag);
        };
      loader = _loader(server, store);
    });

    test(
      'the first refresh asks for everything and keeps the validator',
      () async {
        expect(await loader.refreshCache(), isTrue);

        expect(server.sentValidators, [null]);
        expect(store.values[catalogueV2CacheKey], contains('"schema":2'));
        expect(store.values[catalogueV2ValidatorCacheKey], currentEtag);
      },
    );

    test(
      'an unchanged catalogue costs a question, not a download or a write',
      () async {
        await loader.refreshCache();
        store.puts.clear();
        final bodyBefore = store.values[catalogueV2CacheKey];

        expect(await loader.refreshCache(), isTrue, reason: 'cache is current');

        expect(server.sentValidators, [null, currentEtag]);
        expect(server.fullFetches, 1, reason: 'only the first one downloaded');
        expect(store.puts, isEmpty, reason: 'the large body is not rewritten');
        expect(store.values[catalogueV2CacheKey], bodyBefore);
      },
    );

    test(
      'a changed catalogue replaces the body and the validator together',
      () async {
        await loader.refreshCache();
        currentEtag = '"v2-gz"';
        currentIds = ['a', 'b', 'c'];

        expect(await loader.refreshCache(), isTrue);

        expect(
          server.sentValidators.last,
          '"v1-gz"',
          reason: 'asked with the old one',
        );
        final cached = jsonDecode(store.values[catalogueV2CacheKey]!) as Map;
        expect((cached['cards'] as List).length, 3);
        expect(store.values[catalogueV2ValidatorCacheKey], '"v2-gz"');
        // and the next refresh asks with the new one
        await loader.refreshCache();
        expect(server.sentValidators.last, '"v2-gz"');
      },
    );

    test(
      'the cached feed is what the loader serves, before and after a 304',
      () async {
        await loader.refreshCache();
        final first = await loader.load();
        await loader.refreshCache(); // 304
        final second = await loader.load();

        expect(second.cards.map((c) => c.id), first.cards.map((c) => c.id));
        expect(second.cards.map((c) => c.id), ['a', 'b']);
        expect(second.origin, CatalogueOrigin.cacheV2);
      },
    );

    test(
      'a validator is never sent without the v2 body it belongs to',
      () async {
        await loader.refreshCache();
        store.values.remove(catalogueV2CacheKey); // body gone, validator left

        await loader.refreshCache();

        expect(server.sentValidators.last, isNull);
        expect(
          store.values[catalogueV2CacheKey],
          isNotNull,
          reason: 'refetched',
        );
      },
    );

    test(
      'a validator is never sent when the cached body is not a v2 body',
      () async {
        await loader.refreshCache();
        store.values[catalogueV2CacheKey] = '{"cards":[]}'; // a v1-shaped body

        await loader.refreshCache();

        expect(server.sentValidators.last, isNull);
        expect(jsonDecode(store.values[catalogueV2CacheKey]!)['schema'], 2);
      },
    );

    test(
      'an unreadable validator or body store never fails the refresh',
      () async {
        final broken = _ThrowingReadStore();
        final l = _loader(server, broken);

        expect(await l.refreshCache(), isTrue);
        expect(server.sentValidators, [
          null,
        ], reason: 'no validator, full fetch');
      },
    );

    test(
      'a response with no ETag drops the old validator with the old body',
      () async {
        await loader.refreshCache();
        expect(store.values[catalogueV2ValidatorCacheKey], isNotNull);
        server.onFetch = (etag) async => _fetch(['x']); // no etag header

        await loader.refreshCache();

        expect(store.values[catalogueV2ValidatorCacheKey], isNull);
        // so the next refresh is a plain full fetch, not a stale question
        await loader.refreshCache();
        expect(server.sentValidators.last, isNull);
      },
    );

    test(
      'a validator that could not be saved is removed, the body stays',
      () async {
        final l = _loader(server, _ValidatorWriteFails());
        expect(await l.refreshCache(), isTrue);
        await l.refreshCache();

        expect(server.sentValidators, [
          null,
          null,
        ], reason: 'never a half-saved one');
      },
    );

    test(
      'an older server (v1 body for ?schema=2) clears body and validator',
      () async {
        await loader.refreshCache();
        server.onFetch = (etag) async => throw const CatalogueSchemaMismatch();
        final withV1 = CatalogueLoader(
          fetchV1: () async => [
            for (final id in ['old'])
              CardProductJson.fromJson(v2CardJson(id), v1Mode: true),
          ],
          v2Source: server,
          cache: store,
          log: (_) {},
        );

        await withV1.refreshCache();

        expect(store.values[catalogueV2CacheKey], isNull);
        expect(store.values[catalogueV2ValidatorCacheKey], isNull);
      },
    );

    test('a failed question keeps the cached body and validator', () async {
      await loader.refreshCache();
      server.onFetch = (etag) async =>
          throw ApiException('GET /catalogue?schema=2 failed: 503');

      expect(await loader.refreshCache(), isFalse);

      expect(store.values[catalogueV2CacheKey], isNotNull);
      expect(store.values[catalogueV2ValidatorCacheKey], currentEtag);
    });

    test(
      'load() with no cache stores the validator for the next refresh',
      () async {
        final feed = await loader.load();

        expect(feed.origin, CatalogueOrigin.liveV2);
        expect(store.values[catalogueV2ValidatorCacheKey], currentEtag);
        await loader.refreshCache();
        expect(server.sentValidators.last, currentEtag);
      },
    );

    test(
      'a repository that only implements fetchV2 is never sent a validator',
      () async {
        final plain = _PlainSource(_fetch(['a'], etag: '"x"'));
        final l = CatalogueLoader(
          fetchV1: plain.fetchCatalogue,
          v2Source: plain,
          cache: store,
          log: (_) {},
        );

        await l.refreshCache();
        await l.refreshCache();

        expect(plain.calls, 2, reason: 'full fetch both times, as before');
      },
    );
  });

  group('HttpCatalogueRepository', () {
    String body() => jsonEncode(v2Body([v2CardJson('a')]));

    test('sends If-None-Match, treats 304 as unchanged', () async {
      http.BaseRequest? seen;
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((r) async {
          seen = r;
          return http.Response('', 304, headers: {'etag': '"e"'});
        }),
      );

      expect(await repo.fetchV2IfChanged('"e"'), isNull);
      expect(seen!.headers['If-None-Match'], '"e"');
      expect(seen!.url.toString(), 'https://api.test/catalogue?schema=2');
    });

    test('a 200 carries the ETag out with the body', () async {
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient(
          (r) async =>
              http.Response(body(), 200, headers: {'ETag': '"abc-gz"'}),
        ),
      );

      final fetched = (await repo.fetchV2IfChanged('"old"'))!;

      expect(fetched.etag, '"abc-gz"');
      expect(fetched.feed.cards.map((c) => c.id), ['a']);
      expect(fetched.rawBody, body());
    });

    test(
      'plain fetchV2 sends no validator and a 304 is an error there',
      () async {
        http.BaseRequest? seen;
        var status = 200;
        final repo = HttpCatalogueRepository(
          baseUrl: 'https://api.test',
          client: MockClient((r) async {
            seen = r;
            return status == 304
                ? http.Response('', 304)
                : http.Response(body(), 200, headers: {'etag': '"e"'});
          }),
        );

        expect((await repo.fetchV2()).etag, '"e"');
        expect(seen!.headers.containsKey('If-None-Match'), isFalse);

        status = 304;
        await expectLater(repo.fetchV2(), throwsA(isA<ApiException>()));
      },
    );

    test('an empty validator is never sent', () async {
      http.BaseRequest? seen;
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((r) async {
          seen = r;
          return http.Response(body(), 200);
        }),
      );

      expect((await repo.fetchV2IfChanged(''))!.etag, isNull);
      expect(seen!.headers.containsKey('If-None-Match'), isFalse);
    });

    test('other statuses still throw', () async {
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((r) async => http.Response('', 503)),
      );
      await expectLater(
        repo.fetchV2IfChanged('"e"'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}

/// A store whose reads fail: caching is best effort and must never break a refresh.
class _ThrowingReadStore extends _MapStore {
  @override
  Future<String?> get(String key) async => throw StateError('unreadable');
}

class _PlainSource implements CatalogueRepository, V2CatalogueSource {
  _PlainSource(this.fetch);
  final CatalogueV2Fetch fetch;
  int calls = 0;

  @override
  Future<CatalogueV2Fetch> fetchV2() async {
    calls++;
    return fetch;
  }

  @override
  Future<List<CardProduct>> fetchCatalogue() async =>
      throw ApiException('GET /catalogue failed: 500');
}
