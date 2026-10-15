import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/merchant_search_repository.dart';

void main() {
  group('HttpMerchantSearchRepository', () {
    test('parses a real-shaped GET /merchants/search response', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/merchants/search');
        expect(request.url.queryParameters['q'], 'dmart');
        return http.Response(
          jsonEncode({
            'merchants': [
              {
                'merchant_id': 'm1',
                'display_name': 'DMart Powai',
                'category_id': 'groceries',
                'confidence': 'high',
                'grid_lat': '19.11',
                'grid_lng': '72.90',
              },
            ],
          }),
          200,
        );
      });
      final repo = HttpMerchantSearchRepository(
        baseUrl: 'http://localhost:4000',
        client: client,
      );

      final result = await repo.search('dmart');

      expect(result, hasLength(1));
      expect(result.first.displayName, 'DMart Powai');
      expect(result.first.categoryId, 'groceries');
    });

    test('handles a merchant with no confirmed location row (null grid_lat/lng)', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'merchants': [
              {
                'merchant_id': 'm2',
                'display_name': 'New Merchant',
                'category_id': null,
                'confidence': 'low',
                'grid_lat': null,
                'grid_lng': null,
              },
            ],
          }),
          200,
        );
      });
      final repo = HttpMerchantSearchRepository(
        baseUrl: 'http://localhost:4000',
        client: client,
      );

      final result = await repo.search('new');

      expect(result, hasLength(1));
      expect(result.first.location.lat, 0);
      expect(result.first.location.lng, 0);
    });

    test('resolves the exact VPA before payment', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/merchants/resolve');
        expect(request.url.queryParameters['vpa'], 'paytmqr6z7fka@ptys');
        return http.Response(
          jsonEncode({
            'merchant': {
              'merchant_id': 'merchant-1',
              'vpa': 'paytmqr6z7fka@ptys',
              'display_name': 'Srimal Super Store',
              'mcc': '5411',
              'category_id': 'groceries-id',
              'category_name': 'Groceries',
              'category_slug': 'groceries',
              'confidence': 'high',
              'confidence_score': 0.98,
              'confirmation_count': 12,
              'is_p2p': false,
            },
          }),
          200,
        );
      });
      final repo = HttpMerchantSearchRepository(
        baseUrl: 'http://localhost:4000',
        client: client,
      );

      final result = await repo.resolveVpa('PaytmQR6z7fka@ptys');

      expect(result?.displayName, 'Srimal Super Store');
      expect(result?.mcc, '5411');
      expect(result?.categorySlug, 'groceries');
    });

    test('returns null when the exact VPA is not in the directory', () async {
      final client = MockClient((request) async {
        return http.Response(jsonEncode({'merchant': null}), 200);
      });
      final repo = HttpMerchantSearchRepository(
        baseUrl: 'http://localhost:4000',
        client: client,
      );

      expect(await repo.resolveVpa('unknown@upi'), isNull);
    });

    test('a non-200 response throws ApiException', () async {
      final client = MockClient((request) async => http.Response('bad', 400));
      final repo = HttpMerchantSearchRepository(
        baseUrl: 'http://localhost:4000',
        client: client,
      );

      expect(() => repo.search(''), throwsA(isA<ApiException>()));
    });
  });
}
