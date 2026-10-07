import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/notification_devices_api.dart';

void main() {
  test('sendTestNotification accepts the provider-accepted response', () async {
    final api = NotificationDevicesApi(
      apiBaseUrl: 'https://api.example.test',
      accessToken: 'token',
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/notifications/test');
        expect(request.headers['authorization'], 'Bearer token');
        expect(request.body, isEmpty);
        return http.Response('{"ok":true,"requested":true}', 202);
      }),
    );

    await api.sendTestNotification();
  });

  test(
    'sendTestNotification surfaces an unconfigured production service',
    () async {
      final api = NotificationDevicesApi(
        apiBaseUrl: 'https://api.example.test',
        accessToken: 'token',
        client: MockClient(
          (_) async => http.Response(
            '{"error":"notification_service_not_configured"}',
            503,
          ),
        ),
      );

      expect(() => api.sendTestNotification(), throwsA(isA<ApiException>()));
    },
  );
}
