import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'nearby_merchants_repository.dart';

/// UA-8, extended: real background geofence monitoring, closing the gap the
/// original one-shot screen's doc-comment explicitly flagged ("always-on
/// background geofence monitoring... needs a foreground service + platform
/// review this sandbox can't responsibly build/verify").
///
/// What "background" means here, precisely: a `geolocator` position
/// stream backed by an Android foreground service (a persistent, visible
/// notification — required by Play policy for any background-location use,
/// not optional chrome) or iOS's background-location-updates mode. Both
/// keep the app PROCESS alive while backgrounded/screen-off; neither
/// survives the user force-killing the app or a device reboot — that would
/// need a headless callback entry point (`workmanager`/native
/// AlarmManager/BGTaskScheduler), a materially bigger undertaking than
/// this pass, and not attempted here. This is the same scope real
/// consumer apps ship as "background location" — not full always-on
/// tracking independent of the app's lifecycle.
///
/// A stream of coordinates that nothing surfaces isn't a geofence feature
/// a user could ever notice, so this also adds the one genuinely new
/// dependency in this pass — `flutter_local_notifications` — to actually
/// post "you're near X" while the app is backgrounded. Tapping the
/// notification opens the app; the existing NearbyMerchantsScreen/Home
/// ranking machinery (already tested) is what computes which card to use,
/// not this service — this service's only job is "detect proximity, tell
/// the user," same separation as the foreground screen already had.
class GeofenceMonitorService {
  final NearbyMerchantsRepository repo;
  final FlutterLocalNotificationsPlugin notifications;
  final double radiusMeters;
  final Duration notifyCooldown;

  StreamSubscription<Position>? _subscription;
  final Map<String, DateTime> _lastNotifiedAt = {};
  bool _initialized = false;

  GeofenceMonitorService({
    required this.repo,
    FlutterLocalNotificationsPlugin? notifications,
    this.radiusMeters = 300,
    this.notifyCooldown = const Duration(minutes: 30),
  }) : notifications = notifications ?? FlutterLocalNotificationsPlugin();

  bool get isMonitoring => _subscription != null;

  /// Pure decision logic — given when a merchant was last notified (if
  /// ever) and the current time, should this match fire another
  /// notification? Separated out so the dedupe/cooldown behavior is
  /// testable without a real GPS stream or notification plugin.
  static bool shouldNotify({
    required String merchantId,
    required DateTime now,
    required Map<String, DateTime> lastNotifiedAt,
    required Duration cooldown,
  }) {
    final last = lastNotifiedAt[merchantId];
    if (last == null) return true;
    return now.difference(last) >= cooldown;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await notifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );
    _initialized = true;
  }

  /// Requests the "always" location permission (needed for background
  /// updates on both platforms — WhenInUse/foreground-only is not
  /// sufficient) and, on Android 13+, the separate notification
  /// permission a foreground-service notification also requires. Returns
  /// false (does not throw) if the user declines either — callers show
  /// their own messaging, same "no fabricated success" posture as the
  /// original one-shot screen.
  Future<bool> requestPermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission != LocationPermission.always) {
      // On Android, requestPermission() only ever grants "whileInUse" in
      // one shot — the OS requires a second, separate prompt for
      // background access, which permission_handler's Permission
      // .locationAlways triggers. iOS's Geolocator.requestPermission()
      // can escalate directly to .always if NSLocationAlwaysAndWhenInUseUsageDescription
      // is present (which it now is), but a second nudge here is harmless
      // if already granted.
      permission = await Geolocator.requestPermission();
    }
    if (permission != LocationPermission.always) return false;

    await _ensureInitialized();
    if (Platform.isAndroid) {
      final androidPlugin = notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidPlugin?.requestNotificationsPermission();
      if (granted == false) return false;
    }
    return true;
  }

  Future<void> start() async {
    if (isMonitoring) return;
    await _ensureInitialized();

    final locationSettings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.medium,
            distanceFilter: 150,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationText: 'Watching for nearby merchants you\'ve used before',
              notificationTitle: 'PandaPay is checking your location',
              enableWakeLock: true,
            ),
          )
        : (Platform.isIOS
            ? AppleSettings(
                accuracy: LocationAccuracy.medium,
                distanceFilter: 150,
                pauseLocationUpdatesAutomatically: false,
                showBackgroundLocationIndicator: true,
              )
            : const LocationSettings(accuracy: LocationAccuracy.medium, distanceFilter: 150));

    _subscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen(_onPosition);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _onPosition(Position position) async {
    try {
      final candidates = await repo.fetchNearby(
        lat: position.latitude,
        lng: position.longitude,
        radiusM: radiusMeters,
      );
      final matches = findNearbyMerchants(
        origin: GeoPoint(lat: position.latitude, lng: position.longitude),
        candidates: candidates,
        radiusMeters: radiusMeters,
      );
      final now = DateTime.now();
      for (final match in matches) {
        if (!shouldNotify(
          merchantId: match.candidate.merchantId,
          now: now,
          lastNotifiedAt: _lastNotifiedAt,
          cooldown: notifyCooldown,
        )) {
          continue;
        }
        _lastNotifiedAt[match.candidate.merchantId] = now;
        await _notify(match);
      }
    } catch (_) {
      // A single failed poll (network blip, transient GPS glitch) isn't
      // fatal to the monitor — the next position update just retries.
      // Nothing to surface to a UI that isn't necessarily visible right now.
    }
  }

  Future<void> _notify(NearbyMerchantMatch match) async {
    const androidDetails = AndroidNotificationDetails(
      'geofence_nearby_merchant',
      'Nearby merchants',
      channelDescription: 'Alerts when you\'re near a merchant you\'ve used before',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());
    final name = match.candidate.displayName ?? 'a merchant you\'ve used before';
    await notifications.show(
      match.candidate.merchantId.hashCode,
      'You\'re near $name',
      'Open PandaPay to see which card to use here.',
      details,
    );
  }
}
