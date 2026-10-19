import 'dart:async';
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
      'parses a real-shaped OpenStreetMap nearby response into candidates',
      () async {
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/merchants/nearby/discover');
          expect(request.url.queryParameters, isEmpty);
          expect(jsonDecode(request.body), {
            'lat': 12.9716,
            'lng': 77.5946,
            'radiusM': 1500.0,
          });
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

    test('nearby discovery sends the requested radius', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/merchants/nearby/discover');
        expect(jsonDecode(request.body), {
          'lat': 15.4,
          'lng': 74.0,
          'radiusM': 1500.0,
        });
        return http.Response(jsonEncode({'merchants': []}), 200);
      });

      final repo = HttpNearbyMerchantsRepository(
        baseUrl: 'http://localhost:4000',
        client: client,
      );
      await repo.fetchNearby(lat: 15.4, lng: 74.0, radiusM: 1500);
    });

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
      'nearby network calls stop waiting at the configured timeout',
      () async {
        final client = MockClient((_) => Completer<http.Response>().future);
        final repo = HttpNearbyMerchantsRepository(
          baseUrl: 'http://localhost:4000',
          client: client,
          requestTimeout: const Duration(milliseconds: 10),
        );

        await expectLater(
          repo.fetchNearby(lat: 12.97, lng: 77.59),
          throwsA(
            isA<ApiException>().having(
              (error) => error.userMessage,
              'userMessage',
              contains('took too long'),
            ),
          ),
        );
      },
    );

    test(
      'discovery requests the isolated fallback endpoint and preserves provenance',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, '/merchants/nearby/discover');
          expect(request.method, 'POST');
          expect(request.url.queryParameters, isEmpty);
          expect(jsonDecode(request.body), {
            'lat': 12.9716,
            'lng': 77.5946,
            'radiusM': 2000.0,
            'categoryId': 'groceries',
          });
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
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/merchants/nearby/discover');
          expect(request.url.queryParameters, isEmpty);
          return http.Response(jsonEncode({'merchants': []}), 200);
        });
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

    test('device cache keeps same-area results for up to 24 hours', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = SharedPreferencesNearbyMerchantCache(
        namespace: 'profile:test',
        preferences: Future.value(prefs),
      );
      final candidate = NearbyMerchantCandidate(
        merchantId: 'osm:node:42',
        displayName: 'Saved Petrol Station',
        categoryId: 'fuel',
        location: const GeoPoint(lat: 12.9717, lng: 77.5947),
        source: 'osm_candidate',
      );
      final key = cache.key(lat: 12.9716, lng: 77.5946, radiusM: 2000);

      await prefs.setString(
        key,
        jsonEncode({
          'fetched_at': DateTime.now()
              .subtract(const Duration(hours: 23))
              .toIso8601String(),
          'merchants': [
            {
              'merchant_id': candidate.merchantId,
              'display_name': candidate.displayName,
              'category_id': candidate.categoryId,
              'grid_lat': '12.9717',
              'grid_lng': '77.5947',
              'source': candidate.source,
            },
          ],
        }),
      );

      final snapshot = await cache.read(
        lat: 12.9716,
        lng: 77.5946,
        radiusM: 2000,
      );

      expect(snapshot, isNotNull);
      expect(snapshot!.candidates.single.displayName, 'Saved Petrol Station');
    });

    test('device cache expires results older than 24 hours', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cache = SharedPreferencesNearbyMerchantCache(
        namespace: 'profile:test',
        preferences: Future.value(prefs),
      );
      await prefs.setString(
        cache.key(lat: 12.9716, lng: 77.5946, radiusM: 2000),
        jsonEncode({
          'fetched_at': DateTime.now()
              .subtract(const Duration(hours: 25))
              .toIso8601String(),
          'merchants': [],
        }),
      );

      final snapshot = await cache.read(
        lat: 12.9716,
        lng: 77.5946,
        radiusM: 2000,
      );

      expect(snapshot, isNull);
    });
  });
}
