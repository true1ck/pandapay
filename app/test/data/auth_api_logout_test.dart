import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/auth_api.dart';

void main() {
  test('logout revokes the refresh token with the access token', () async {
    late http.Request request;
    final api = AuthApi(
      authBaseUrl: 'https://auth.test',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response('{"ok":true}', 200);
      }),
    );

    await api.logout(accessToken: 'access-1', refreshToken: 'refresh-1');

    expect(request.method, 'POST');
    expect(request.url.toString(), 'https://auth.test/auth/logout');
    expect(request.headers['Authorization'], 'Bearer access-1');
    expect(jsonDecode(request.body), {'refresh_token': 'refresh-1'});
  });

  test('logout surfaces a rejected request with its status code', () async {
    final api = AuthApi(
      authBaseUrl: 'https://auth.test',
      client: MockClient((_) async => http.Response('nope', 401)),
    );

    await expectLater(
      api.logout(accessToken: 'a', refreshToken: 'r'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
    );
  });
}
