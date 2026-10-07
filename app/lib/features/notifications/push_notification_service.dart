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
  Timer? _registrationRetryTimer;
  Timer? _startupRetryTimer;
  String? _lastToken;
  int _registrationRetryAttempt = 0;
  int _startupRetryAttempt = 0;
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
      _startupRetryAttempt = 0;
    } catch (error) {
      // Native Firebase configuration is environment-specific. A missing
      // google-services.json/GoogleService-Info.plist must not break login or
      // the existing local notification feature.
      debugPrint('PandaPay push notifications unavailable: $error');
      // Do not leave a logged-in device permanently unregistered after a
      // transient Firebase/Google Play Services startup failure. Keep the
      // existing app usable and retry in the background.
      await _tokenSubscription?.cancel();
      await _messageSubscription?.cancel();
      _tokenSubscription = null;
      _messageSubscription = null;
      _started = false;
      _scheduleStartupRetry();
    }
  }

  Future<void> _registerToken(String token) async {
    _lastToken = token;
    _registrationRetryTimer?.cancel();
    _registrationRetryTimer = null;
    try {
      await api.register(token: token, platform: _platformName());
      _registrationRetryAttempt = 0;
    } catch (error) {
      // A later token refresh or next sign-in retries registration. Push
      // delivery is additive and must not block the user's financial actions.
      debugPrint('PandaPay FCM token registration failed: $error');
      _scheduleRegistrationRetry();
    }
  }

  void _scheduleRegistrationRetry() {
    if (!_started || _lastToken == null || _registrationRetryTimer != null) {
      return;
    }
    final exponent = _registrationRetryAttempt.clamp(0, 5).toInt();
    final seconds = (5 * (1 << exponent)).clamp(5, 120).toInt();
    _registrationRetryAttempt++;
    _registrationRetryTimer = Timer(Duration(seconds: seconds), () {
      _registrationRetryTimer = null;
      final token = _lastToken;
      if (token != null && _started) unawaited(_registerToken(token));
    });
  }

  void _scheduleStartupRetry() {
    if (_startupRetryTimer != null) return;
    final exponent = _startupRetryAttempt.clamp(0, 5).toInt();
    final seconds = (10 * (1 << exponent)).clamp(10, 300).toInt();
    _startupRetryAttempt++;
    _startupRetryTimer = Timer(Duration(seconds: seconds), () {
      _startupRetryTimer = null;
      unawaited(start());
    });
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
    _registrationRetryTimer?.cancel();
    _startupRetryTimer?.cancel();
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    _tokenSubscription = null;
    _messageSubscription = null;
    _registrationRetryTimer = null;
    _startupRetryTimer = null;
    _lastToken = null;
    _registrationRetryAttempt = 0;
    _startupRetryAttempt = 0;
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
