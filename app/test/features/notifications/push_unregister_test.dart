import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/notification_devices_api.dart';
import 'package:pandapay/features/notifications/notification_gate.dart';
import 'package:pandapay/features/notifications/push_notification_service.dart';

final _gateProvider = Provider<NotificationGate>(
  (ref) => NotificationGate(
    ref: ref,
    notifications: FlutterLocalNotificationsPlugin(),
  ),
);

NotificationGate _gate() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container.read(_gateProvider);
}

void main() {
  test('unregister drops the token on the server, then on the phone', () async {
    final log = <String>[];
    final service = PushNotificationService(
      api: NotificationDevicesApi(
        apiBaseUrl: 'https://api.test',
        accessToken: 'access',
        client: MockClient((request) async {
          log.add('${request.method} ${jsonDecode(request.body)['token']}');
          return http.Response('', 204);
        }),
      ),
      gate: _gate(),
      readToken: () async => 'fcm-token-abc',
      deleteToken: () async => log.add('deleteToken'),
    );

    await service.unregister();

    expect(log, ['DELETE fcm-token-abc', 'deleteToken']);
  });

  test(
    'unregister still deletes the phone token when the server is down',
    () async {
      final log = <String>[];
      final service = PushNotificationService(
        api: NotificationDevicesApi(
          apiBaseUrl: 'https://api.test',
          accessToken: 'access',
          client: MockClient((_) async => http.Response('{}', 502)),
        ),
        gate: _gate(),
        readToken: () async => 'fcm-token-abc',
        deleteToken: () async => log.add('deleteToken'),
      );

      await expectLater(service.unregister(), throwsA(anything));
      expect(log, ['deleteToken']);
    },
  );

  test('unregister with no token only deletes locally', () async {
    final log = <String>[];
    final service = PushNotificationService(
      api: NotificationDevicesApi(
        apiBaseUrl: 'https://api.test',
        accessToken: 'access',
        client: MockClient((request) async {
          log.add('unexpected ${request.method}');
          return http.Response('', 204);
        }),
      ),
      gate: _gate(),
      readToken: () async => null,
      deleteToken: () async => log.add('deleteToken'),
    );

    await service.unregister();

    expect(log, ['deleteToken']);
  });
}
