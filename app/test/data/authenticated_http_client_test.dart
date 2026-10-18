import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/api_exception.dart';

void main() {
  test(
    'refresh metadata failure cannot turn an accepted write into a failed save',
    () async {
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        onSuccessfulMutation: (_) => throw StateError('storage unavailable'),
        inner: MockClient((_) async => http.Response('saved', 201)),
      );
      addTearDown(client.close);
      final response = await client.post(
        Uri.parse('https://api.example.test/transactions'),
        body: '{}',
      );
      expect(response.statusCode, 201);
    },
  );
  test(
    'an old repository cannot submit data under a different signed-in account',
    () async {
      String token(String user) =>
          'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': user}))).replaceAll('=', '')}.sig';
      var requests = 0;
      final client = AuthenticatedHttpClient(
        currentAccessToken: () => token('b'),
        refreshAccessToken: () async => null,
        inner: MockClient((_) async {
          requests++;
          return http.Response('ok', 200);
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.post(
          Uri.parse('https://api.example.test/transactions'),
          headers: {'Authorization': 'Bearer ${token('a')}'},
          body: '{}',
        ),
        throwsA(isA<ApiException>()),
      );
      expect(requests, 0);
    },
  );
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
    'can recover a request when the live access token is temporarily missing',
    () async {
      var requests = 0;
      final client = AuthenticatedHttpClient(
        currentAccessToken: () => null,
        refreshAccessToken: () async => 'restored-token',
        inner: MockClient((request) async {
          requests++;
          if (requests == 1) {
            expect(request.headers['authorization'], isNull);
            return http.Response(
              jsonEncode({'error': 'Missing or invalid access token'}),
              401,
            );
          }
          expect(request.headers['authorization'], 'Bearer restored-token');
          return http.Response('ok', 200);
        }),
      );

      final response = await client.patch(
        Uri.parse('https://api.example.test/transactions/t1'),
        headers: {'Authorization': 'Bearer stale-token'},
        body: '{}',
      );

      expect(response.statusCode, 200);
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
