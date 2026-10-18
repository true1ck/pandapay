import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/features/geofence/nearby_merchants_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'foreground search radius is positive and within the discovery limit',
    () {
      expect(nearbyMerchantSearchRadiusMeters, greaterThan(0));
      expect(nearbyMerchantSearchRadiusMeters, lessThanOrEqualTo(5000));
    },
  );

  group('HttpNearbyMerchantsRepository', () {
    test(
      'parses a real-shaped GET /merchants/nearby response into candidates',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, '/merchants/nearby');
          expect(request.url.queryParameters['lat'], '12.9716');
          expect(request.url.queryParameters['lng'], '77.5946');
          expect(request.url.queryParameters['radiusM'], '1500.0');
          return http.Response(
            jsonEncode({
              'merchants': [
                {
                  'merchant_id': 'm1',
                  'display_name': 'Test Cafe',
                  'address': 'Main Road, Panaji',
                  'category_id': 'dining',
                  'confidence': 'high',
                  'grid_lat': '12.9720',
                  'grid_lng': '77.5950',
                  'distance_meters': 62.1,
                },
              ],
            }),
            200,
          );
        });

        final repo = HttpNearbyMerchantsRepository(
          baseUrl: 'http://localhost:4000',
          client: client,
        );
        final result = await repo.fetchNearby(
          lat: 12.9716,
          lng: 77.5946,
          radiusM: 1500,
        );

        expect(result, hasLength(1));
        expect(result.first.merchantId, 'm1');
        expect(result.first.displayName, 'Test Cafe');
        expect(result.first.address, 'Main Road, Panaji');
        expect(result.first.categoryId, 'dining');
        expect(result.first.location.lat, closeTo(12.9720, 0.0001));
        expect(result.first.location.lng, closeTo(77.5950, 0.0001));
      },
    );

    test('a non-200 response throws NearbyMerchantsException', () async {
      final client = MockClient((request) async => http.Response('error', 500));
      final repo = HttpNearbyMerchantsRepository(
        baseUrl: 'http://localhost:4000',
        client: client,
      );

      expect(
        () => repo.fetchNearby(lat: 0, lng: 0),
        throwsA(isA<ApiException>()),
      );
    });

    test(
      'discovery requests the isolated fallback endpoint and preserves provenance',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, '/merchants/nearby/discover');
          expect(request.url.queryParameters['categoryId'], 'groceries');
          return http.Response(
            jsonEncode({
              'source': 'openstreetmap',
              'merchants': [
                {
                  'merchant_id': 'osm:node:42',
                  'display_name': 'Example Market',
                  'category_id': 'groceries',
                  'source': 'osm_candidate',
                  'confidence': 'low',
                  'grid_lat': '12.9717',
                  'grid_lng': '77.5947',
                },
              ],
            }),
            200,
          );
        });

        final repo = HttpNearbyMerchantsRepository(
          baseUrl: 'http://localhost:4000',
          client: client,
        );
        final result = await repo.discoverNearby(
          lat: 12.9716,
          lng: 77.5946,
          radiusM: 2000,
          categoryId: 'groceries',
        );

        expect(result, hasLength(1));
        expect(result.first.merchantId, 'osm:node:42');
        expect(result.first.source, 'osm_candidate');
        expect(result.first.confidence, closeTo(0.35, 0.001));
      },
    );

    test('manual place search requests the place-search endpoint', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/merchants/nearby/search');
        expect(request.url.queryParameters['q'], 'petrol pump');
        return http.Response(
          jsonEncode({
            'source': 'openstreetmap',
            'merchants': [
              {
                'merchant_id': 'osm_search:node:7',
                'display_name': 'Example Petrol Pump',
                'category_id': 'fuel',
                'source': 'osm_search_candidate',
                'confidence': 'low',
                'grid_lat': '15.4900',
                'grid_lng': '73.8300',
              },
            ],
          }),
          200,
        );
      });

      final repo = HttpNearbyMerchantsRepository(
        baseUrl: 'http://localhost:4000',
        client: client,
      );
      final result = await repo.searchPlaces(query: 'petrol pump');

      expect(result, hasLength(1));
      expect(result.first.displayName, 'Example Petrol Pump');
      expect(result.first.categoryId, 'fuel');
      expect(result.first.source, 'osm_search_candidate');
    });

    test(
      'an unavailable provider returns a valid empty search result',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, '/merchants/nearby/search');
          return http.Response(
            jsonEncode({
              'source': 'unavailable',
              'merchants': [],
              'unavailable': true,
              'message':
                  'The public place search provider is temporarily unavailable',
            }),
            200,
          );
        });

        final repo = HttpNearbyMerchantsRepository(
          baseUrl: 'http://localhost:4000',
          client: client,
        );
        final result = await repo.searchPlacesWithStatus(query: 'panda');

        expect(result.candidates, isEmpty);
        expect(result.unavailable, isTrue);
        expect(result.message, contains('temporarily unavailable'));
      },
    );

    test(
      'manual search falls back to the published directory on an old API',
      () async {
        final client = MockClient((request) async {
          if (request.url.path == '/merchants/nearby/search') {
            return http.Response('not found', 404);
          }
          expect(request.url.path, '/merchants/search');
          expect(request.url.queryParameters['q'], 'panda');
          return http.Response(
            jsonEncode({
              'merchants': [
                {
                  'merchant_id': 'm1',
                  'display_name': 'Panda Cafe',
                  'category_id': 'dining',
                  'grid_lat': null,
                  'grid_lng': null,
                },
              ],
            }),
            200,
          );
        });

        final repo = HttpNearbyMerchantsRepository(
          baseUrl: 'http://localhost:4000',
          client: client,
        );
        final result = await repo.searchPlaces(query: 'panda');

        expect(result.single.displayName, 'Panda Cafe');
        expect(result.single.location.lat, 0);
        expect(result.single.source, 'published');
      },
    );

    test(
      'an empty merchants list parses to an empty list, not an error',
      () async {
        final client = MockClient(
          (request) async => http.Response(jsonEncode({'merchants': []}), 200),
        );
        final repo = HttpNearbyMerchantsRepository(
          baseUrl: 'http://localhost:4000',
          client: client,
        );

        final result = await repo.fetchNearby(lat: 0, lng: 0);
        expect(result, isEmpty);
      },
    );

    test('a directory result without a confirmed location still parses', () {
      final result = parseNearbyMerchantsPayload(
        jsonEncode({
          'merchants': [
            {
              'merchant_id': 'm2',
              'display_name': 'Panda Cafe',
              'category_id': 'dining',
              'confidence': 'medium',
              'grid_lat': null,
              'grid_lng': null,
              'source': 'published',
            },
          ],
        }),
        defaultSource: 'published',
      );

      expect(result.single.displayName, 'Panda Cafe');
      expect(result.single.location.lat, 0);
      expect(result.single.location.lng, 0);
      expect(result.single.source, 'published');
    });

    test(
      'device cache round-trips nearby candidates within a session namespace',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final cache = SharedPreferencesNearbyMerchantCache(
          namespace: 'profile:test',
          preferences: Future.value(prefs),
        );
        final candidate = NearbyMerchantCandidate(
          merchantId: 'm1',
          displayName: 'Test Cafe',
          address: 'Main Road, Panaji',
          categoryId: 'dining',
          location: const GeoPoint(lat: 12.9717, lng: 77.5947),
          source: 'published',
        );

        await cache.write(
          lat: 12.9716,
          lng: 77.5946,
          radiusM: 2000,
          candidates: [candidate],
        );
        final snapshot = await cache.read(
          lat: 12.9716,
          lng: 77.5946,
          radiusM: 2000,
        );

        expect(snapshot, isNotNull);
        expect(snapshot!.candidates.single.displayName, 'Test Cafe');
        expect(snapshot.candidates.single.address, 'Main Road, Panaji');
        expect(snapshot.candidates.single.categoryId, 'dining');
        expect(snapshot.candidates.single.source, 'published');
      },
    );
  });
}
