import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

import '../notifications/notification_branding.dart';
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
  static const _locationNotificationChannel =
      MethodChannel('app.pandapay/location_notification');
  static const proximityMeters = 20.0;
  static const visitExitMeters = 60.0;
  static const maxAlertsPerWindow = 2;
  static const alertWindow = Duration(minutes: 30);

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
  final String namespace;
  final Future<SharedPreferences> _preferences;

  StreamSubscription<Position>? _subscription;
  Future<void> _positionQueue = Future.value();
  bool _initialized = false;

  GeofenceMonitorService({
    required this.repo,
    FlutterLocalNotificationsPlugin? notifications,
    this.gate,
    this.recommendationTextBuilder,
    this.radiusMeters = 300,
    this.namespace = 'default',
    Future<SharedPreferences>? preferences,
  }) : notifications = notifications ?? FlutterLocalNotificationsPlugin(),
       _preferences = preferences ?? SharedPreferences.getInstance();

  @override
  bool get isMonitoring => _subscription != null;

  static bool locationQuotaReached(List<DateTime> sentAt, DateTime now) =>
      sentAt.where((time) => now.difference(time) < alertWindow).length >=
      maxAlertsPerWindow;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      await notifications.initialize(
        NotificationBranding.initializationSettings,
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
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationText: 'Checking for nearby businesses',
              notificationTitle: 'PandaPay is checking your location',
              notificationIcon: AndroidResource(
                name: NotificationBranding.smallIcon,
                defType: 'drawable',
              ),
              color: NotificationBranding.accentColor,
              enableWakeLock: true,
            ),
          )
        : (Platform.isIOS
              ? AppleSettings(
                  accuracy: LocationAccuracy.high,
                  distanceFilter: 5,
                  pauseLocationUpdatesAutomatically: false,
                  showBackgroundLocationIndicator: true,
                )
              : const LocationSettings(
                  accuracy: LocationAccuracy.high,
                  distanceFilter: 5,
                ));

    _subscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (position) {
            _positionQueue = _positionQueue
                .then((_) => _onPosition(position, generation))
                .catchError((Object error) {
                  debugPrint('GeofenceMonitorService position failed: $error');
                });
          },
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
    if (Platform.isAndroid) {
      // Geolocator owns the persistent notification. Its Dart API exposes a
      // small icon only, so Android adds our existing large logo once the
      // foreground service posts the notification.
      unawaited(_brandLocationNotification());
    }
    if (generation == _generation &&
        status.value == GeofenceMonitorStatus.starting) {
      status.value = GeofenceMonitorStatus.monitoring;
    }
  }

  Future<void> _brandLocationNotification() async {
    try {
      await _locationNotificationChannel.invokeMethod<void>(
        'applyBrandIcons',
        {
          'smallIcon': NotificationBranding.smallIcon,
          'largeIcon': NotificationBranding.largeIcon,
        },
      );
    } on Exception catch (error) {
      debugPrint('Could not brand location notification: $error');
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
    if (generation != _generation) return;
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
      final origin = GeoPoint(lat: position.latitude, lng: position.longitude);
      final matches = findNearbyMerchants(
        origin: origin,
        candidates: candidates,
        radiusMeters: radiusMeters,
      );
      final now = DateTime.now();
      final prefs = await _preferences;
      if (generation != _generation) return;
      final stateKey = '$namespace:nearby_visit_state_v1';
      final quotaKey = '$namespace:location_alert_times_v1';
      final visits = _decodeVisits(prefs.getString(stateKey));
      final sentAt = _decodeTimes(prefs.getString(quotaKey))
        ..removeWhere((time) => now.difference(time) >= alertWindow);

      // Keep an active visit latched until two accurate fixes confirm the user
      // has moved beyond the wider exit boundary. This prevents GPS jitter and
      // process restarts from turning one stay into repeated notifications.
      for (final entry in visits.entries.toList()) {
        final distance = haversineDistanceMeters(
          origin,
          GeoPoint(lat: entry.value.lat, lng: entry.value.lng),
        );
        if (position.accuracy <= proximityMeters) {
          entry.value.outsideFixes = distance > visitExitMeters
              ? entry.value.outsideFixes + 1
              : 0;
        }
        if (entry.value.outsideFixes >= 2) visits.remove(entry.key);
      }

      for (final match in matches.where(
        (m) =>
            position.accuracy <= proximityMeters &&
            m.distanceMeters <= proximityMeters,
      )) {
        final key = _visitKey(match.candidate);
        if (visits.containsKey(key) || locationQuotaReached(sentAt, now)) {
          continue;
        }
        if (generation != _generation) return;
        // Persist the reservation before delivery so a process death between
        // showing the alert and writing state cannot cause an immediate repeat.
        visits[key] = _VisitState(
          match.candidate.location.lat,
          match.candidate.location.lng,
        );
        sentAt.add(now);
        await prefs.setString(stateKey, _encodeVisits(visits));
        await prefs.setString(quotaKey, _encodeTimes(sentAt));
        var delivered = false;
        try {
          delivered = generation == _generation && await _notify(match);
        } catch (_) {
          // A failed attempt must not pin the visit or consume its quota.
          if (generation == _generation) {
            status.value = GeofenceMonitorStatus.unavailable;
          }
        }
        if (!delivered) {
          visits.remove(key);
          sentAt.removeLast();
          await prefs.setString(stateKey, _encodeVisits(visits));
          await prefs.setString(quotaKey, _encodeTimes(sentAt));
        }
      }
      await prefs.setString(stateKey, _encodeVisits(visits));
      await prefs.setString(quotaKey, _encodeTimes(sentAt));
    } catch (_) {
      if (generation == _generation) {
        status.value = GeofenceMonitorStatus.unavailable;
      }
    }
  }

  static String _visitKey(NearbyMerchantCandidate candidate) =>
      '${candidate.merchantId}:${candidate.location.lat.toStringAsFixed(6)}:${candidate.location.lng.toStringAsFixed(6)}';

  static Map<String, _VisitState> _decodeVisits(String? value) {
    try {
      final decoded = jsonDecode(value ?? '{}') as Map<String, dynamic>;
      return decoded.map((key, value) {
        final item = value as Map<String, dynamic>;
        return MapEntry(
          key,
          _VisitState(
            (item['lat'] as num).toDouble(),
            (item['lng'] as num).toDouble(),
            outsideFixes: (item['outside'] as num?)?.toInt() ?? 0,
          ),
        );
      });
    } catch (_) {
      return {};
    }
  }

  static String _encodeVisits(Map<String, _VisitState> visits) => jsonEncode({
    for (final entry in visits.entries)
      entry.key: {
        'lat': entry.value.lat,
        'lng': entry.value.lng,
        'outside': entry.value.outsideFixes,
      },
  });

  static List<DateTime> _decodeTimes(String? value) {
    try {
      return (jsonDecode(value ?? '[]') as List)
          .cast<String>()
          .map(DateTime.parse)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String _encodeTimes(List<DateTime> times) =>
      jsonEncode(times.map((time) => time.toIso8601String()).toList());

  Future<bool> _notify(NearbyMerchantMatch match) async {
    final name = match.candidate.displayName ?? 'a nearby business';
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
      // per-merchant: the persisted visit state above already deduplicates
      // alerts during a stay, and the gate's own dedupe store has a different
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
    await notifications.show(
      merchantId.hashCode,
      title,
      body,
      NotificationBranding.nearbyMerchantDetails,
    );
    return true;
  }
}

class _VisitState {
  final double lat;
  final double lng;
  int outsideFixes;

  _VisitState(this.lat, this.lng, {this.outsideFixes = 0});
}
