import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/features/geofence/nearby_merchants_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
        expect(snapshot.candidates.single.categoryId, 'dining');
        expect(snapshot.candidates.single.source, 'published');
      },
    );
  });
}
