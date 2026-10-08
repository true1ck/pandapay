import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/authenticated_http_client.dart';

void main() {
  test(
    'refreshes once and retries a request rejected by an expired token',
    () async {
      var requests = 0;
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => 'fresh-token',
        inner: MockClient((request) async {
          requests++;
          if (requests == 1) {
            expect(request.headers['authorization'], 'Bearer stale-token');
            return http.Response(
              jsonEncode({'error': 'Missing or invalid access token'}),
              401,
            );
          }
          expect(request.headers['authorization'], 'Bearer fresh-token');
          return http.Response('{"ok":true}', 200);
        }),
      );

      final response = await client.get(
        Uri.parse('https://api.example.test/spend-report'),
        headers: {'Authorization': 'Bearer stale-token'},
      );

      expect(response.statusCode, 200);
      expect(response.body, '{"ok":true}');
      expect(requests, 2);
      client.close();
    },
  );

  test(
    'shares one refresh when multiple requests receive 401 together',
    () async {
      var refreshes = 0;
      var requests = 0;
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'fresh-token';
        },
        inner: MockClient((request) async {
          requests++;
          if (request.headers['authorization'] == 'Bearer stale-token') {
            return http.Response('expired', 401);
          }
          return http.Response('ok', 200);
        }),
      );

      final responses = await Future.wait([
        client.get(
          Uri.parse('https://api.example.test/one'),
          headers: {'Authorization': 'Bearer stale-token'},
        ),
        client.get(
          Uri.parse('https://api.example.test/two'),
          headers: {'Authorization': 'Bearer stale-token'},
        ),
      ]);

      expect(
        responses.map((response) => response.statusCode),
        everyElement(200),
      );
      expect(refreshes, 1);
      expect(requests, 4);
      client.close();
    },
  );
}
