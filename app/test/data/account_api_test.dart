import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/account_api.dart';
import 'package:pandapay/data/api_exception.dart';

void main() {
  const apiBaseUrl = 'https://api.example.test';
  const authBaseUrl = 'https://auth.example.test';
  const accessToken = 'test-access-token';

  group('AccountApi.resetUserData', () {
    test('checks authorization before resetting product data', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      });

      await AccountApi(
        apiBaseUrl: apiBaseUrl,
        authBaseUrl: authBaseUrl,
        accessToken: accessToken,
        client: client,
      ).resetUserData();

      expect(requests.map((request) => request.url.toString()), [
        '$authBaseUrl/users/me/deletion-check',
        '$apiBaseUrl/account/data-reset',
      ]);
      expect(
        requests.every(
          (request) =>
              request.headers['authorization'] == 'Bearer $accessToken',
        ),
        isTrue,
      );
      client.close();
    });

    test('does not reset data when the server rejects the check', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"error":"unauthorized"}', 401);
      });

      await expectLater(
        AccountApi(
          apiBaseUrl: apiBaseUrl,
          authBaseUrl: authBaseUrl,
          accessToken: accessToken,
          client: client,
        ).resetUserData(),
        throwsA(isA<ApiException>()),
      );

      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/users/me/deletion-check');
      client.close();
    });
  });

  group('AccountApi.deleteAccountPermanently', () {
    test('erases product rows before removing the auth account', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      });

      await AccountApi(
        apiBaseUrl: apiBaseUrl,
        authBaseUrl: authBaseUrl,
        accessToken: accessToken,
        client: client,
      ).deleteAccountPermanently();

      expect(requests.map((request) => '${request.method} ${request.url}'), [
        'POST $authBaseUrl/users/me/deletion-check',
        'POST $apiBaseUrl/account/erase',
        'DELETE $authBaseUrl/users/me',
      ]);
      client.close();
    });

    test(
      'does not delete auth identity when the product purge fails',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return http.Response(
            '{}',
            request.url.path == '/account/erase' ? 500 : 200,
          );
        });

        await expectLater(
          AccountApi(
            apiBaseUrl: apiBaseUrl,
            authBaseUrl: authBaseUrl,
            accessToken: accessToken,
            client: client,
          ).deleteAccountPermanently(),
          throwsA(isA<ApiException>()),
        );

        expect(requests, hasLength(2));
        expect(requests.last.url.path, '/account/erase');
        client.close();
      },
    );
  });
}
