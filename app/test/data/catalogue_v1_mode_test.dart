import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/catalogue_v2.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../support/v1_feed_view.dart';

/// D32a: every schema-1 source is parsed in v1 mode. The v1 feed's rows are
/// `to_jsonb(row)` and carry the v2 columns; read as v2 they turned the card
/// v2-shaped while the precise v2 rows are not in the v1 feed, so
/// cashback-sbi-card earned ₹50 on ₹5,000 of bills, insurance and fuel
/// instead of 0. Real fixtures, served the way the v1 view serves them.
class _MapStore implements CatalogueCacheStore {
  final Map<String, String> values;
  _MapStore([Map<String, String>? initial]) : values = {...?initial};
  @override
  Future<String?> get(String key) async => values[key];
  @override
  Future<void> put(String key, String rawJson) async => values[key] = rawJson;
  @override
  Future<void> clear(String key) async => values.remove(key);
}

const _skip = ['bills', 'insurance', 'fuel'];

/// The real body has ₹ in it: serve it as UTF-8, as the server does.
http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Money _value(CardProduct card, String category) =>
    const RecommendationEngine()
        .rank(
          RecommendationContext(
            amount: Money.fromRupees(5000),
            categoryId: 'cat-$category',
            categorySlug: category,
            rail: TxnRail.swipe,
            now: DateTime(2026, 11, 6),
          ),
          [CardSnapshot(product: card)],
        )
        .single
        .expectedValue;

void _expectV1Shaped(CardProduct card) {
  expect(card.isV2Shaped, isFalse);
  for (final category in _skip) {
    expect(_value(card, category), const Money.zero(), reason: category);
  }
}

CatalogueLoader _loader({
  CatalogueCacheStore? cache,
  Future<List<CardProduct>> Function()? fetchV1,
  Future<String> Function()? bundled,
}) => CatalogueLoader(
  fetchV1: fetchV1 ?? () async => throw StateError('offline'),
  cache: cache,
  loadBundled: bundled,
  log: (_) {},
);

void main() {
  final v1Body = v1FeedBody(['cashback-sbi-card']);

  test('the fixture really has the defect without v1 mode (before D32a)', () {
    final card = CardProductJson.fromJson(
      v1Body['cards']![0] as Map<String, dynamic>,
    );
    expect(card.isV2Shaped, isTrue);
    expect(_value(card, 'bills'), Money.fromRupees(50));
  });

  group('every schema-1 source stays v1-shaped', () {
    test('parseCatalogueBody, schema 1', () {
      final feed = parseCatalogueBody(
        v1Body,
        schema: 1,
        origin: CatalogueOrigin.liveV1,
        log: (_) {},
      );
      _expectV1Shaped(feed.cards.single);
    });

    test('a schema-2 body is still parsed as v2', () {
      final feed = parseCatalogueBody(
        {
          'schema': 2,
          'cards': [fixtureCard('cashback-sbi-card')],
        },
        schema: 2,
        origin: CatalogueOrigin.liveV2,
        log: (_) {},
      );
      expect(feed.cards.single.isV2Shaped, isTrue);
      expect(feed.cards.single.modelStatus, isNotNull);
    });

    test('the live v1 fetch (HttpCatalogueRepository.fetchCatalogue)', () async {
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((_) async => _json(v1Body)),
      );
      _expectV1Shaped((await repo.fetchCatalogue()).single);
    });

    test('the `catalogue` cache holding the v1 body as received', () async {
      final feed = await _loader(
        cache: _MapStore({catalogueV1CacheKey: jsonEncode(v1Body)}),
      ).load();
      expect(feed.origin, CatalogueOrigin.cacheV1);
      _expectV1Shaped(feed.cards.single);
    });

    test('the bundled asset when it is a schema-1 body', () async {
      final feed = await _loader(
        bundled: () async => jsonEncode(v1Body),
      ).load();
      expect(feed.origin, CatalogueOrigin.bundled);
      _expectV1Shaped(feed.cards.single);
    });

    test('live v1 then an offline start: the cached card is the same '
        'v1-shaped card', () async {
      final store = _MapStore();
      final repo = HttpCatalogueRepository(
        baseUrl: 'https://api.test',
        client: MockClient((request) async {
          // An older server: ?schema=2 answers with the v1 body.
          return _json(v1Body);
        }),
      );
      final online = await repo.loader(cache: store, log: (_) {}).load();
      _expectV1Shaped(online.cards.single);

      // The cache holds the v1 body without v2 keys.
      final cached = jsonDecode(store.values[catalogueV1CacheKey]!) as Map;
      for (final rule in (cached['cards'] as List).single['reward_rules']) {
        expect((rule as Map).containsKey('rule_role'), isFalse);
        expect(rule.containsKey('max_engine_version'), isFalse);
      }
      expect(store.values.containsKey(catalogueV2CacheKey), isFalse);

      final offline = await _loader(cache: store).load();
      expect(offline.origin, CatalogueOrigin.cacheV1);
      _expectV1Shaped(offline.cards.single);
      for (final category in ['bills', 'insurance', 'fuel', 'travel', 'online']) {
        expect(
          _value(offline.cards.single, category),
          _value(online.cards.single, category),
          reason: category,
        );
      }
    });

    test('the shipped bundled asset stays v1-shaped', () {
      // 9 cards with no v2 keys at all.
      final cards =
          (jsonDecode(
                    File('assets/data/bundled_catalogue.json')
                        .readAsStringSync(),
                  )
                  as Map)['cards']
              as List;
      final feed = parseCatalogueBody(
        {'cards': cards},
        schema: 1,
        origin: CatalogueOrigin.bundled,
        log: (_) {},
      );
      expect(feed.cards, hasLength(cards.length));
      expect(feed.cards.any((c) => c.isV2Shaped), isFalse);
    });
  });
}
