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

    test('updateOverride only sends the fields that were passed', () async {
      Map<String, dynamic>? sentBody;
      final client = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      final repo = CardOverridesRepository(apiBaseUrl: 'http://localhost:4000', accessToken: 't', client: client);

      await repo.updateOverride('o1', reasonNote: 'new note', userCardId: 'uc2');

      expect(sentBody, {'reasonNote': 'new note', 'userCardId': 'uc2'});
    });

    test('updateOverride sends an empty reasonNote (not omitted) to let the backend clear it', () async {
      Map<String, dynamic>? sentBody;
      final client = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      final repo = CardOverridesRepository(apiBaseUrl: 'http://localhost:4000', accessToken: 't', client: client);

      await repo.updateOverride('o1', reasonNote: '');

      expect(sentBody, {'reasonNote': ''});
    });

    test('setEnabled sends only isEnabled, via updateOverride', () async {
      Map<String, dynamic>? sentBody;
      final client = MockClient((request) async {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      final repo = CardOverridesRepository(apiBaseUrl: 'http://localhost:4000', accessToken: 't', client: client);

      await repo.setEnabled('o1', false);

      expect(sentBody, {'isEnabled': false});
    });

    test('a non-200 response from updateOverride throws ApiException', () async {
      final client = MockClient((request) async => http.Response('bad', 400));
      final repo = CardOverridesRepository(apiBaseUrl: 'http://localhost:4000', accessToken: 't', client: client);

      expect(
        () => repo.updateOverride('o1', reasonNote: 'x'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
