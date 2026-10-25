import 'dart:ui' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../app/design/app_theme.dart' show AppColors;

/// Shared Android notification artwork and presentation settings.
///
/// The Android drawable aliases in values/notification_branding.xml are the
/// single mapping from these names to the existing PandaPay icon assets.
abstract final class NotificationBranding {
  static const smallIcon = 'pandapay_notification_small_icon';
  static const largeIcon = 'pandapay_notification_large_icon';
  static const accentColor = Color(0xFF121316);

  static const initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings(smallIcon),
    iOS: DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    ),
  );

  static const alertDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'pandapay_alerts',
      'PandaPay alerts',
      channelDescription:
          'Cap, milestone, bill, and other card alerts you\'ve opted into',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: smallIcon,
      largeIcon: DrawableResourceAndroidBitmap(largeIcon),
      color: accentColor,
    ),
    iOS: DarwinNotificationDetails(),
  );

  static const nearbyMerchantDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'geofence_nearby_merchant',
      'Nearby merchants',
      channelDescription:
          'Alerts when nearby businesses are detected while monitoring is on',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: smallIcon,
      largeIcon: DrawableResourceAndroidBitmap(largeIcon),
      color: accentColor,
    ),
    iOS: DarwinNotificationDetails(),
  );
}
