import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/card_overrides_repository.dart';

void main() {
  group('CardOverridesRepository', () {
    test('fetchOverrides parses a real-shaped GET /card-overrides response', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/card-overrides');
        return http.Response(
          jsonEncode({
            'overrides': [
              {
                'id': 'o1',
                'user_card_id': 'uc1',
                'scope': 'vpa',
                'vpa': 'merchant@upi',
                'merchant_name': null,
                'category_id': null,
                'category_name': null,
                'reason_note': 'always this one',
                'is_enabled': true,
                'created_at': '2026-01-01T00:00:00Z',
                'card_name': 'HDFC Millennia',
                'card_nickname': null,
              },
            ],
          }),
          200,
        );
      });
      final repo = CardOverridesRepository(apiBaseUrl: 'http://localhost:4000', accessToken: 't', client: client);

      final result = await repo.fetchOverrides();

      expect(result, hasLength(1));
      expect(result.first.scope, OverrideScope.vpa);
      expect(result.first.vpa, 'merchant@upi');
      expect(result.first.cardDisplayName, 'HDFC Millennia');
    });

    test('a non-201 response from createOverride throws ApiException', () async {
      final client = MockClient((request) async => http.Response('bad', 400));
      final repo = CardOverridesRepository(apiBaseUrl: 'http://localhost:4000', accessToken: 't', client: client);

      expect(
        () => repo.createOverride(userCardId: 'uc1', scope: OverrideScope.category, categoryId: 'cat1'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
