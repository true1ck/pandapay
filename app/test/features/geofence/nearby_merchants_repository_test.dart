import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/features/geofence/nearby_merchants_repository.dart';

void main() {
  group('HttpNearbyMerchantsRepository', () {
    test('parses a real-shaped GET /merchants/nearby response into candidates', () async {
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

      final repo = HttpNearbyMerchantsRepository(baseUrl: 'http://localhost:4000', client: client);
      final result = await repo.fetchNearby(lat: 12.9716, lng: 77.5946, radiusM: 1500);

      expect(result, hasLength(1));
      expect(result.first.merchantId, 'm1');
      expect(result.first.displayName, 'Test Cafe');
      expect(result.first.categoryId, 'dining');
      expect(result.first.location.lat, closeTo(12.9720, 0.0001));
      expect(result.first.location.lng, closeTo(77.5950, 0.0001));
    });

    test('a non-200 response throws NearbyMerchantsException', () async {
      final client = MockClient((request) async => http.Response('error', 500));
      final repo = HttpNearbyMerchantsRepository(baseUrl: 'http://localhost:4000', client: client);

      expect(
        () => repo.fetchNearby(lat: 0, lng: 0),
        throwsA(isA<NearbyMerchantsException>()),
      );
    });

    test('an empty merchants list parses to an empty list, not an error', () async {
      final client = MockClient((request) async => http.Response(jsonEncode({'merchants': []}), 200));
      final repo = HttpNearbyMerchantsRepository(baseUrl: 'http://localhost:4000', client: client);

      final result = await repo.fetchNearby(lat: 0, lng: 0);
      expect(result, isEmpty);
    });
  });
}
