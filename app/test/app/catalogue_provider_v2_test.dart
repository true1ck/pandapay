import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/catalogue_v2.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/v2_catalogue_fixtures.dart';

/// WP9: catalogueProvider runs the v2 -> v1 -> cache -> bundle chain, and
/// the engine receives the directory that arrived with the feed.
ProviderContainer _container({
  required MockClient client,
  required ResponseCache cache,
}) {
  final container = ProviderContainer(
    overrides: [
      catalogueRepositoryProvider.overrideWithValue(
        HttpCatalogueRepository(baseUrl: 'https://api.test', client: client),
      ),
      responseCacheProvider.overrideWith((ref) async => cache),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ResponseCache cache;

  setUp(() {
    cache = ResponseCache(openInMemoryForTesting());
  });

  test('v2 live: cards, directory and the engine all come from one load',
      () async {
    final container = _container(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(v2Body([v2CardJson('a'), badCardJson('bad')])),
          200,
        ),
      ),
      cache: cache,
    );

    final cards = await container.read(catalogueProvider.future);
    expect(cards.map((c) => c.id), ['a']);
    expect(cards.single.isV2Shaped, isTrue);

    final directory = container.read(merchantDirectoryProvider);
    expect(directory.merchant('swiggy'), isNotNull);

    final engine = container.read(recommendationEngineProvider);
    expect(engine.merchantDirectory, same(directory));

    // Cached losslessly under the versioned key, not the old one.
    expect(await cache.get(catalogueV2CacheKey), isNotNull);
    expect(await cache.get(catalogueV1CacheKey), isNull);
  });

  test('an older server: v1 fallback, empty directory, old cache key only',
      () async {
    final container = _container(
      client: MockClient((request) async {
        if (request.url.query.contains('schema=2')) {
          // An older server ignores the parameter and answers in v1.
          return http.Response(jsonEncode(v1Body([v1CardJson('old')])), 200);
        }
        return http.Response(jsonEncode(v1Body([v1CardJson('old')])), 200);
      }),
      cache: cache,
    );

    final cards = await container.read(catalogueProvider.future);
    expect(cards.single.id, 'old');
    expect(container.read(merchantDirectoryProvider).merchants, isEmpty);
    expect(
      container.read(recommendationEngineProvider).merchantDirectory,
      isNotNull,
    );
    expect(await cache.get(catalogueV2CacheKey), isNull);
    expect(await cache.get(catalogueV1CacheKey), isNotNull);
  });

  test('invalidating catalogueProvider reloads the directory with the cards',
      () async {
    var served = 'first';
    final container = _container(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            v2Body(
              [v2CardJson(served)],
              merchants: [
                {'slug': served, 'name': served, 'aliases': [served]},
              ],
            ),
          ),
          200,
        ),
      ),
      cache: cache,
    );
    // Keep the engine alive so its dependency chain is exercised.
    container.listen(recommendationEngineProvider, (_, _) {});

    await container.read(catalogueProvider.future);
    expect(container.read(merchantDirectoryProvider).merchant('first'),
        isNotNull);

    served = 'second';
    // The first load is cached, so the cache wins until it is refreshed
    // (today's cache-first policy); refresh it, then invalidate.
    await container
        .read(catalogueRepositoryProvider)
        .loader(cache: ResponseCacheCatalogueStore(cache))
        .refreshCache();
    container.invalidate(catalogueProvider);
    await container.read(catalogueProvider.future);

    final directory = container.read(merchantDirectoryProvider);
    expect(directory.merchant('first'), isNull);
    expect(directory.merchant('second'), isNotNull);
    expect(
      container.read(recommendationEngineProvider).merchantDirectory,
      same(directory),
    );
  });

  test('a stale load finishing late never overwrites the newer directory '
      '(M1)', () async {
    // Load 1 starts and hangs on its HTTP response; the catalogue is then
    // invalidated and load 2 completes with a different directory. When load 1
    // finally answers, its directory must not replace load 2's.
    final hold = Completer<void>();
    var requests = 0;
    String body(String slug) => jsonEncode(
      v2Body(
        [v2CardJson(slug)],
        merchants: [
          {'slug': slug, 'name': slug, 'aliases': [slug]},
        ],
      ),
    );
    final container = _container(
      client: MockClient((request) async {
        requests++;
        if (requests == 1) {
          await hold.future;
          return http.Response(body('stale'), 200);
        }
        return http.Response(body('fresh'), 200);
      }),
      cache: cache,
    );
    container.listen(merchantDirectoryProvider, (_, _) {});

    final first = container.read(catalogueProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    container.invalidate(catalogueProvider);
    final second = await container.read(catalogueProvider.future);
    expect(second.single.id, 'fresh');
    expect(container.read(merchantDirectoryProvider).merchant('fresh'),
        isNotNull);

    hold.complete();
    await first.catchError((Object _) => <CardProduct>[]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // A stale write is latent until the directory provider next recomputes:
    // when the catalogue is invalidated again it rebuilds for the loading
    // state and reads whatever the holder holds at that moment, which must
    // still be load 2's directory.
    container.invalidate(catalogueProvider);
    final directory = container.read(merchantDirectoryProvider);
    expect(directory.merchant('fresh'), isNotNull);
    expect(directory.merchant('stale'), isNull);
  });

  test('everything unreachable: the bundled asset or an empty list, never a '
      'throw', () async {
    final container = _container(
      client: MockClient((_) async => http.Response('down', 503)),
      cache: cache,
    );
    final cards = await container.read(catalogueProvider.future);
    // The bundled asset is a v1 file: it has cards and no directory.
    expect(cards, isA<List<CardProduct>>());
    expect(container.read(merchantDirectoryProvider).merchants, isEmpty);
  });
}
