import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../notifications/notification_gate.dart';
import 'nearby_merchants_repository.dart';

/// Runtime health is separate from the account's saved opt-in.
enum GeofenceMonitorStatus {
  off,
  starting,
  monitoring,
  locationOff,
  permissionRequired,
  notificationsOff,
  unavailable,
}

abstract class BackgroundMerchantMonitor {
  ValueListenable<GeofenceMonitorStatus> get status;
  bool get isMonitoring;
  Future<bool> requestPermissions();
  Future<void> start();
  Future<void> stop();
}

/// Watches published merchants while the process runs in the background.
/// A force-stop or reboot ends this stream; the controller restores it when
/// the signed-in app opens again. This service never discovers map candidates.
class GeofenceMonitorService implements BackgroundMerchantMonitor {
  @override
  final ValueNotifier<GeofenceMonitorStatus> status = ValueNotifier(
    GeofenceMonitorStatus.off,
  );
  int _generation = 0;
  final NearbyMerchantsRepository repo;
  final FlutterLocalNotificationsPlugin notifications;
  final NotificationGate? gate;
  final String? Function(NearbyMerchantMatch match)? recommendationTextBuilder;
  final double radiusMeters;
  final Duration notifyCooldown;

  StreamSubscription<Position>? _subscription;
  final Map<String, DateTime> _lastNotifiedAt = {};
  bool _initialized = false;

  GeofenceMonitorService({
    required this.repo,
    FlutterLocalNotificationsPlugin? notifications,
    this.gate,
    this.recommendationTextBuilder,
    this.radiusMeters = 300,
    this.notifyCooldown = const Duration(minutes: 30),
  }) : notifications = notifications ?? FlutterLocalNotificationsPlugin();

  @override
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
      const iosInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await notifications.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
      );
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
  @override
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
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final granted = await androidPlugin?.requestNotificationsPermission();
        if (granted == false) return false;
      } else if (Platform.isIOS) {
        if (!(await ph.Permission.notification.request()).isGranted) {
          return false;
        }
      }
      return true;
    } catch (e) {
      debugPrint('GeofenceMonitorService.requestPermissions failed: $e');
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await stop();
      status.value = GeofenceMonitorStatus.locationOff;
      return;
    }
    await _ensureInitialized();

    // Re-check the grant right before opening the stream: the user may have
    // toggled permissions in system Settings since requestPermissions() ran,
    // and opening a foreground-service location stream without "always" throws
    // a SecurityException on Android 14+ that would otherwise crash the app.
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.always) {
      await stop();
      status.value = GeofenceMonitorStatus.permissionRequired;
      return;
    }

    final notificationsAllowed = Platform.isAndroid
        ? await notifications
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.areNotificationsEnabled()
        : await ph.Permission.notification.isGranted;
    if (notificationsAllowed == false) {
      await stop();
      status.value = GeofenceMonitorStatus.notificationsOff;
      return;
    }
    if (isMonitoring && status.value == GeofenceMonitorStatus.monitoring) {
      return;
    }
    await stop();
    status.value = GeofenceMonitorStatus.starting;
    final generation = ++_generation;

    final locationSettings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.medium,
            distanceFilter: 150,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationText:
                  'Watching for published PandaPay merchants nearby',
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
              : const LocationSettings(
                  accuracy: LocationAccuracy.medium,
                  distanceFilter: 150,
                ));

    _subscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (position) => _onPosition(position, generation),
          // Surface failures without losing the user's saved opt-in. A later
          // successful fix or an app-resume retry can recover the monitor.
          onError: (Object e, StackTrace st) {
            debugPrint('GeofenceMonitorService position stream error: $e');
            if (generation == _generation) {
              status.value = e is LocationServiceDisabledException
                  ? GeofenceMonitorStatus.locationOff
                  : GeofenceMonitorStatus.unavailable;
            }
          },
          onDone: () {
            if (generation != _generation) return;
            ++_generation;
            _subscription = null;
            status.value = GeofenceMonitorStatus.unavailable;
          },
          cancelOnError: false,
        );
    if (generation == _generation &&
        status.value == GeofenceMonitorStatus.starting) {
      status.value = GeofenceMonitorStatus.monitoring;
    }
  }

  @override
  Future<void> stop() async {
    ++_generation;
    final subscription = _subscription;
    _subscription = null;
    status.value = GeofenceMonitorStatus.off;
    await subscription?.cancel();
  }

  Future<void> _onPosition(Position position, int generation) async {
    try {
      final candidates = await repo
          .fetchNearby(
            lat: position.latitude,
            lng: position.longitude,
            radiusM: radiusMeters,
          )
          .timeout(const Duration(seconds: 15));
      if (generation != _generation) return;
      status.value = GeofenceMonitorStatus.monitoring;
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
        if (generation != _generation) return;
        if (await _notify(match)) {
          _lastNotifiedAt[match.candidate.merchantId] = now;
        }
      }
    } catch (_) {
      if (generation == _generation) {
        status.value = GeofenceMonitorStatus.unavailable;
      }
    }
  }

  Future<bool> _notify(NearbyMerchantMatch match) async {
    final name =
        match.candidate.displayName ?? 'a merchant you\'ve used before';
    final merchantId = match.candidate.merchantId;
    final title = 'You\'re near $name';
    final body =
        recommendationTextBuilder?.call(match) ??
        'Open PandaPay to see which card to use here.';

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
      return gate!.fire(
        category: 'location',
        title: title,
        body: body,
        dedupeKey:
            'geofence:$merchantId:${DateTime.now().millisecondsSinceEpoch}',
        merchantId: merchantId,
      );
    }

    // Fallback for direct construction without a gate (e.g. unit tests that
    // build this service on its own, or any future caller that hasn't been
    // wired to a NotificationGate yet) — same content, just without the
    // preference/quiet-hours/cap checks geofenceMonitorServiceProvider
    // always supplies in the real app.
    const androidDetails = AndroidNotificationDetails(
      'geofence_nearby_merchant',
      'Nearby merchants',
      channelDescription:
          'Alerts when you\'re near a merchant you\'ve used before',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    await notifications.show(merchantId.hashCode, title, body, details);
    return true;
  }
}
