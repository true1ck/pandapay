import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../data/notification_devices_api.dart';
import 'notification_gate.dart';

/// Firebase Messaging background entry point.
///
/// Notification messages sent by the private service are displayed by the
/// operating system while the app is backgrounded. Initialising Firebase here
/// keeps the handler valid for data-only messages as well, without touching
/// PandaPay's authenticated API from a background isolate.
@pragma('vm:entry-point')
Future<void> pandaPayFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp();
}

/// Bridges FCM to the existing notification gate and PandaPay API.
///
/// Firebase is optional at build time: debug builds without native Firebase
/// client files simply log that push is unavailable and continue to work with
/// the existing inbox/local-notification paths.
class PushNotificationService {
  final NotificationDevicesApi api;
  final NotificationGate gate;

  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  bool _started = false;

  PushNotificationService({required this.api, required this.gate});

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      FirebaseMessaging.onBackgroundMessage(
        pandaPayFirebaseMessagingBackgroundHandler,
      );
      _messageSubscription = FirebaseMessaging.onMessage.listen(
        _showForeground,
      );
      _tokenSubscription = messaging.onTokenRefresh.listen(_registerToken);
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) await _registerToken(token);
    } catch (error) {
      // Native Firebase configuration is environment-specific. A missing
      // google-services.json/GoogleService-Info.plist must not break login or
      // the existing local notification feature.
      debugPrint('PandaPay push notifications unavailable: $error');
      await stop();
    }
  }

  Future<void> _registerToken(String token) async {
    try {
      await api.register(token: token, platform: _platformName());
    } catch (error) {
      // A later token refresh or next sign-in retries registration. Push
      // delivery is additive and must not block the user's financial actions.
      debugPrint('PandaPay FCM token registration failed: $error');
    }
  }

  Future<void> _showForeground(RemoteMessage message) async {
    final title = message.notification?.title ?? message.data['title'];
    final body = message.notification?.body ?? message.data['body'];
    if (title == null || body == null || title.isEmpty || body.isEmpty) return;
    await gate.presentRemote(
      category: message.data['category'] ?? 'general',
      title: title,
      body: body,
      dedupeKey: message.data['dedupeKey'] ?? message.messageId,
      deepLink: message.data['deepLink'],
    );
  }

  Future<void> stop() async {
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    _tokenSubscription = null;
    _messageSubscription = null;
    _started = false;
  }

  String _platformName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'web';
    }
  }
}
