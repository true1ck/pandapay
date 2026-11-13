import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/notifications/push_notification_service.dart';

void main() {
  test('FCM token read has an 8 second deadline', () {
    expect(
      PushNotificationService.tokenReadTimeout,
      const Duration(seconds: 8),
    );
  });

  test('a token read that never completes becomes a TimeoutException', () async {
    final never = Completer<String?>().future;
    await expectLater(
      PushNotificationService.boundedTokenRead(
        never,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a prompt token read passes through unchanged', () async {
    expect(
      await PushNotificationService.boundedTokenRead(
        Future<String?>.value('synthetic-token'),
      ),
      'synthetic-token',
    );
    expect(
      await PushNotificationService.boundedTokenRead(Future<String?>.value(null)),
      isNull,
    );
  });
}
