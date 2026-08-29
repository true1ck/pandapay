import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../notifications/notification_gate.dart';
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
  final NotificationGate? gate;
  final double radiusMeters;
  final Duration notifyCooldown;

  StreamSubscription<Position>? _subscription;
  final Map<String, DateTime> _lastNotifiedAt = {};
  bool _initialized = false;

  GeofenceMonitorService({
    required this.repo,
    FlutterLocalNotificationsPlugin? notifications,
    this.gate,
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
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings();
      await notifications.initialize(const InitializationSettings(android: androidInit, iOS: iosInit));
    } catch (e) {
      // A second initialize() on the same plugin instance (NotificationGate
      // shares it) is a no-op that can still throw on some platforms — the
      // monitor does not need to abort for it.
      debugPrint('GeofenceMonitorService: notifications.initialize failed: $e');
    }
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
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return false;
      }

      // Background ("always") access is a SEPARATE grant the OS never bundles
      // with the foreground prompt on Android 10+. Calling
      // Geolocator.requestPermission() a second time here used to be the
      // upgrade path, but back-to-back calls can throw
      // PermissionRequestInProgressException on real devices — permission_handler's
      // Permission.locationAlways is the supported way to ask for the upgrade,
      // and it no-ops if already granted. On iOS this maps to the
      // "Change to Always Allow?" prompt (needs NSLocationAlwaysAndWhenInUseUsageDescription).
      if (permission != LocationPermission.always) {
        final always = await ph.Permission.locationAlways.request();
        if (!always.isGranted) return false;
      }

      await _ensureInitialized();
      if (Platform.isAndroid) {
        final androidPlugin = notifications
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        final granted = await androidPlugin?.requestNotificationsPermission();
        if (granted == false) return false;
      }
      return true;
    } catch (e) {
      debugPrint('GeofenceMonitorService.requestPermissions failed: $e');
      return false;
    }
  }

  Future<void> start() async {
    if (isMonitoring) return;
    await _ensureInitialized();

    // Re-check the grant right before opening the stream: the user may have
    // toggled permissions in system Settings since requestPermissions() ran,
    // and opening a foreground-service location stream without "always" throws
    // a SecurityException on Android 14+ that would otherwise crash the app.
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.always) {
      throw StateError(
        'Background location permission is not granted — enable "Allow all the time" in Settings.',
      );
    }

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

    _subscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      _onPosition,
      // Without onError, a stream error (GPS disabled mid-session, a transient
      // PlatformException, LocationServiceDisabledException) is an UNHANDLED
      // async error — which terminates the app. Swallow it here: the monitor
      // just stops producing updates until the next successful fix, same
      // posture as a failed single poll in _onPosition.
      onError: (Object e, StackTrace st) {
        debugPrint('GeofenceMonitorService position stream error: $e');
      },
      cancelOnError: false,
    );
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
    final name = match.candidate.displayName ?? 'a merchant you\'ve used before';
    final merchantId = match.candidate.merchantId;
    final title = 'You\'re near $name';
    const body = 'Open PandaPay to see which card to use here.';

    if (gate != null) {
      // UA-8.3 (B2): routed through the gate so category_location, quiet
      // hours, and the daily cap are actually honoured — this used to call
      // the plugin directly, bypassing all three despite category_location
      // existing as a setting for exactly this notification.
      //
      // The dedupe key is unique per attempt (timestamp-keyed), not
      // per-merchant: this._lastNotifiedAt above is what already
      // deduplicates repeat visits to the same merchant on a 30-minute
      // cooldown, and the gate's own dedupe store is meant for a different
      // job (suppressing re-checks of an unresolved state, e.g. a cap
      // that's still over threshold next time the app foregrounds) — using
      // a per-merchant key here would let the FIRST visit of the day
      // permanently block every later one.
      await gate!.fire(
        category: 'location',
        title: title,
        body: body,
        dedupeKey: 'geofence:$merchantId:${DateTime.now().millisecondsSinceEpoch}',
        merchantId: merchantId,
      );
      return;
    }

    // Fallback for direct construction without a gate (e.g. unit tests that
    // build this service on its own, or any future caller that hasn't been
    // wired to a NotificationGate yet) — same content, just without the
    // preference/quiet-hours/cap checks geofenceMonitorServiceProvider
    // always supplies in the real app.
    const androidDetails = AndroidNotificationDetails(
      'geofence_nearby_merchant',
      'Nearby merchants',
      channelDescription: 'Alerts when you\'re near a merchant you\'ve used before',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());
    await notifications.show(merchantId.hashCode, title, body, details);
  }
}
