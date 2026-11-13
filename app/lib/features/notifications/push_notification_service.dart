import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../data/notification_devices_api.dart';
import 'notification_gate.dart';
import 'push_deep_link.dart';

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

  /// Called with a validated in-app path when the user taps a push.
  final void Function(String link)? onOpenLink;

  StreamSubscription<RemoteMessage>? _openedSubscription;
  bool _handledInitialMessage = false;
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  Timer? _registrationRetryTimer;
  Timer? _startupRetryTimer;
  String? _lastToken;
  int _registrationRetryAttempt = 0;
  int _startupRetryAttempt = 0;
  int _lifecycleGeneration = 0;
  bool _started = false;

  /// Reads this phone's current FCM token. Replaceable so sign-out can be
  /// tested without Firebase.
  final Future<String?> Function()? readToken;

  /// Deletes this phone's FCM token so the provider stops delivering to it.
  final Future<void> Function()? deleteToken;

  PushNotificationService({
    required this.api,
    required this.gate,
    this.readToken,
    this.deleteToken,
    this.onOpenLink,
  });

  /// How long [start] waits for `FirebaseMessaging.getToken()`.
  static const tokenReadTimeout = Duration(seconds: 8);

  /// Bounds a token read so a hung Firebase call becomes a retryable
  /// [TimeoutException] instead of leaving [start] waiting forever.
  @visibleForTesting
  static Future<String?> boundedTokenRead(
    Future<String?> pending, {
    Duration timeout = tokenReadTimeout,
  }) => pending.timeout(timeout);

  void _openLink(RemoteMessage message) {
    final link = pushDeepLink(message.data['deepLink']);
    debugPrint(
      'PandaPay push tap received (link ${link == null ? 'rejected' : 'accepted'})',
    );
    if (link != null) onOpenLink?.call(link);
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final generation = ++_lifecycleGeneration;
    try {
      await Firebase.initializeApp();
      if (!_started || generation != _lifecycleGeneration) return;
      final messaging = FirebaseMessaging.instance;
      // Keep Firebase auto-init explicit. This matters on a fresh install or
      // after an app update where the platform may not have created an FCM
      // token by the time the first authenticated shell is rendered.
      await messaging.setAutoInitEnabled(true);
      // Permission is requested from an explained, user-initiated action in
      // onboarding/settings. Starting token registration must not display an
      // OS dialog over the SMS disclosure or immediately after sign-in.
      // On iOS, foreground FCM messages are otherwise delivered to Dart but
      // not presented by the OS. Android uses the local notification gate
      // below for foreground delivery; this call is harmless there.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      if (!_started || generation != _lifecycleGeneration) return;
      FirebaseMessaging.onBackgroundMessage(
        pandaPayFirebaseMessagingBackgroundHandler,
      );
      _messageSubscription = FirebaseMessaging.onMessage.listen(
        _showForeground,
      );
      _tokenSubscription = messaging.onTokenRefresh.listen(_registerToken);
      // Taps on a push shown by the system while the app was in the background
      // or closed. The initial message is consumed once per process.
      _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        _openLink,
      );
      if (!_handledInitialMessage) {
        _handledInitialMessage = true;
        final initial = await messaging.getInitialMessage();
        if (initial != null) _openLink(initial);
      }
      // getToken() has no Dart-side deadline and can hang with no network or
      // while Google Play Services is unreachable. A TimeoutException lands in
      // the catch below, which tears the attempt down and schedules the
      // existing backoff retry.
      final token = await boundedTokenRead(messaging.getToken());
      if (!_started || generation != _lifecycleGeneration) return;
      if (token == null || token.isEmpty) {
        // getToken() can legitimately be empty during the first few seconds
        // after install/update while Google Play Services finishes setup.
        // Tear down this attempt so the bounded startup retry can recreate
        // the Firebase listeners and try token acquisition again.
        debugPrint('PandaPay FCM token is not ready; scheduling startup retry');
        await _tokenSubscription?.cancel();
        await _messageSubscription?.cancel();
        _tokenSubscription = null;
        _messageSubscription = null;
        _started = false;
        _scheduleStartupRetry();
        return;
      }
      // Never log the token itself: it is a device credential. This marker
      // makes it possible to verify token acquisition from a release APK's
      // logcat without exposing the credential.
      debugPrint('PandaPay FCM token acquired');
      await _registerToken(token);
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
    if (!_started || token.isEmpty) return;
    _lastToken = token;
    _registrationRetryTimer?.cancel();
    _registrationRetryTimer = null;
    try {
      await api.register(token: token, platform: _platformName());
      _registrationRetryAttempt = 0;
      debugPrint('PandaPay FCM device registration accepted');
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
    _lifecycleGeneration++;
    _registrationRetryTimer?.cancel();
    _startupRetryTimer?.cancel();
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _openedSubscription?.cancel();
    _tokenSubscription = null;
    _messageSubscription = null;
    _openedSubscription = null;
    _registrationRetryTimer = null;
    _startupRetryTimer = null;
    _lastToken = null;
    _registrationRetryAttempt = 0;
    _startupRetryAttempt = 0;
    _started = false;
  }

  /// Sign-out: stops listening, asks the API to drop this phone's token, then
  /// deletes the token on the phone. The local delete runs even when the API
  /// call fails (offline), because it alone stops delivery to this phone.
  /// Rethrows the API failure afterwards so the caller can tell.
  Future<void> unregister() async {
    final knownToken = _lastToken;
    await stop();
    Object? apiError;
    try {
      final token = knownToken ?? await _currentToken();
      if (token != null && token.isNotEmpty) {
        await api.unregister(token: token);
      }
    } catch (error) {
      apiError = error;
    }
    try {
      await (deleteToken ?? _deleteFirebaseToken)();
    } catch (error) {
      debugPrint('PandaPay FCM token delete failed: $error');
    }
    if (apiError != null) throw apiError;
  }

  Future<String?> _currentToken() async {
    final read = readToken;
    if (read != null) return read();
    await Firebase.initializeApp();
    return FirebaseMessaging.instance.getToken();
  }

  static Future<void> _deleteFirebaseToken() async {
    await Firebase.initializeApp();
    await FirebaseMessaging.instance.deleteToken();
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
