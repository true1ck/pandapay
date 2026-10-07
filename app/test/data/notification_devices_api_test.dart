import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/notification_devices_api.dart';

void main() {
  test('registers a device when the notification service confirms it', () async {
    late http.Request request;
    final api = NotificationDevicesApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'access-token',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response(
          jsonEncode({'configured': true, 'registered': true}),
          201,
        );
      }),
    );

    await api.register(token: 'fcm-token', platform: 'android');

    expect(request.url.path, '/notification-devices');
    expect(request.headers['Authorization'], 'Bearer access-token');
    expect(jsonDecode(request.body), {
      'token': 'fcm-token',
      'platform': 'android',
    });
  });

  test('does not treat an unconfigured 202 response as registration success', () async {
    final api = NotificationDevicesApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'access-token',
      client: MockClient((_) async {
        return http.Response(
          jsonEncode({'configured': false, 'registered': false}),
          202,
        );
      }),
    );

    await expectLater(
      api.register(token: 'fcm-token', platform: 'android'),
      throwsA(isA<ApiException>()),
    );
  });

  test('accepts a successful 202 response from a compatible deployment', () async {
    final api = NotificationDevicesApi(
      apiBaseUrl: 'https://api.test',
      accessToken: 'access-token',
      client: MockClient((_) async {
        return http.Response(
          jsonEncode({'configured': true, 'registered': true}),
          202,
        );
      }),
    );

    await api.register(token: 'fcm-token', platform: 'android');
  });
}
