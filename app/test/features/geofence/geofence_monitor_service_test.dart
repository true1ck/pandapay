import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/features/geofence/geofence_monitor_service.dart';
import 'package:pandapay/features/geofence/nearby_merchants_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runtime monitoring status', () {
    late GeolocatorPlatform original;
    late _LocationPlatform location;
    late _PollingRepo repo;
    late GeofenceMonitorService service;
    late _Notifications notifications;
    var notificationsAllowed = true;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      original = GeolocatorPlatform.instance;
      location = _LocationPlatform();
      GeolocatorPlatform.instance = location;
      notificationsAllowed = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (_) async => notificationsAllowed ? 1 : 0,
          );
      repo = _PollingRepo();
      notifications = _Notifications();
      service = GeofenceMonitorService(
        repo: repo,
        notifications: notifications,
      );
    });
    tearDown(() async {
      await service.stop();
      await location.positions.close();
      GeolocatorPlatform.instance = original;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            null,
          );
    });

    test(
      'missing grants and disabled GPS pause instead of claiming active',
      () async {
        location.enabled = false;
        await service.start();
        expect(service.status.value, GeofenceMonitorStatus.locationOff);
        expect(service.isMonitoring, isFalse);
        location.enabled = true;
        location.permission = LocationPermission.whileInUse;
        await service.start();
        expect(service.status.value, GeofenceMonitorStatus.permissionRequired);
        location.permission = LocationPermission.always;
        notificationsAllowed = false;
        await service.start();
        expect(service.status.value, GeofenceMonitorStatus.notificationsOff);
        expect(location.streamStarts, 0);
      },
    );

    test(
      'permission revocation stops an active location subscription',
      () async {
        await service.start();
        expect(service.isMonitoring, isTrue);
        location.permission = LocationPermission.deniedForever;
        await service.start();
        expect(service.isMonitoring, isFalse);
        expect(service.status.value, GeofenceMonitorStatus.permissionRequired);
      },
    );

    test(
      'provider failure is visible and a later successful fix recovers',
      () async {
        await service.start();
        repo.fail = true;
        location.positions.add(_position());
        await Future<void>.delayed(Duration.zero);
        expect(service.status.value, GeofenceMonitorStatus.unavailable);
        repo.fail = false;
        location.positions.add(_position());
        await Future<void>.delayed(Duration.zero);
        expect(service.status.value, GeofenceMonitorStatus.monitoring);
        expect(repo.radius, 300);
      },
    );

    test(
      'stream errors and termination cannot leave an active-looking state',
      () async {
        await service.start();
        location.positions.addError(const LocationServiceDisabledException());
        await Future<void>.delayed(Duration.zero);
        expect(service.status.value, GeofenceMonitorStatus.locationOff);
        await location.positions.close();
        expect(service.isMonitoring, isFalse);
        expect(service.status.value, GeofenceMonitorStatus.unavailable);
      },
    );

    test(
      'a matched merchant delivers an alert and a failed delivery can retry',
      () async {
        repo.response = Future.value(const [
          NearbyMerchantCandidate(
            merchantId: 'near',
            displayName: 'Example Fuels',
            location: GeoPoint(lat: 15, lng: 73),
          ),
          NearbyMerchantCandidate(
            merchantId: 'far',
            displayName: 'Distant Store',
            location: GeoPoint(lat: 16, lng: 73),
          ),
        ]);
        notifications.fail = true;
        await service.start();
        location.positions.add(_position());
        await Future<void>.delayed(Duration.zero);
        expect(service.status.value, GeofenceMonitorStatus.unavailable);
        notifications.fail = false;
        location.positions.add(_position());
        await Future<void>.delayed(Duration.zero);
        expect(notifications.titles, ["You're near Example Fuels"]);
        expect(service.status.value, GeofenceMonitorStatus.monitoring);
        location.positions.add(_position());
        await Future<void>.delayed(Duration.zero);
        expect(notifications.titles, hasLength(1));
      },
    );

    test(
      'late lookup completion after stream termination cannot claim active',
      () async {
        final response = Completer<List<NearbyMerchantCandidate>>();
        repo.response = response.future;
        await service.start();
        location.positions.add(_position());
        await Future<void>.delayed(Duration.zero);
        await location.positions.close();
        response.complete(const []);
        await Future<void>.delayed(Duration.zero);
        expect(service.status.value, GeofenceMonitorStatus.unavailable);
        expect(service.isMonitoring, isFalse);
      },
    );

    test(
      'late lookup completion after stop cannot revive the monitor',
      () async {
        final response = Completer<List<NearbyMerchantCandidate>>();
        repo.response = response.future;
        await service.start();
        location.positions.add(_position());
        await Future<void>.delayed(Duration.zero);
        await service.stop();
        response.complete(const []);
        await Future<void>.delayed(Duration.zero);
        expect(service.status.value, GeofenceMonitorStatus.off);
        expect(service.isMonitoring, isFalse);
      },
    );

    test('stop while preferences load cannot deliver or persist a visit', () async {
      final preferences = Completer<SharedPreferences>();
      repo.response = Future.value(const [
        NearbyMerchantCandidate(
          merchantId: 'near',
          location: GeoPoint(lat: 15, lng: 73),
        ),
      ]);
      service = GeofenceMonitorService(
        repo: repo,
        notifications: notifications,
        preferences: preferences.future,
      );
      await service.start();
      location.positions.add(_position());
      await Future<void>.delayed(Duration.zero);
      await service.stop();
      final prefs = await SharedPreferences.getInstance();
      preferences.complete(prefs);
      await Future<void>.delayed(Duration.zero);

      expect(notifications.titles, isEmpty);
      expect(prefs.getString('default:nearby_visit_state_v1'), isNull);
      expect(service.status.value, GeofenceMonitorStatus.off);
    });
  });

  group('location alert policy', () {
    late GeolocatorPlatform original;

    setUp(() {
      original = GeolocatorPlatform.instance;
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (_) async => 1,
          );
    });

    tearDown(() {
      GeolocatorPlatform.instance = original;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            null,
          );
    });

    test(
      'allows two alerts, blocks the third until the rolling window passes',
      () {
        final now = DateTime(2026, 1, 1, 12, 30);
        expect(
          GeofenceMonitorService.locationQuotaReached([
            now.subtract(const Duration(minutes: 29)),
          ], now),
          isFalse,
        );
        expect(
          GeofenceMonitorService.locationQuotaReached([
            now.subtract(const Duration(minutes: 29)),
            now.subtract(const Duration(minutes: 1)),
          ], now),
          isTrue,
        );
        expect(
          GeofenceMonitorService.locationQuotaReached([
            now.subtract(const Duration(minutes: 30)),
            now.subtract(const Duration(minutes: 1)),
          ], now),
          isFalse,
        );
      },
    );

    test(
      'requires an accurate fix within 20m and persists once-per-visit',
      () async {
        final repo = _PollingRepo()
          ..response = Future.value(const [
            NearbyMerchantCandidate(
              merchantId: 'near',
              displayName: 'Example Cafe',
              location: GeoPoint(lat: 15, lng: 73),
            ),
          ]);
        final notifications = _Notifications();
        final firstLocation = _LocationPlatform();
        GeolocatorPlatform.instance = firstLocation;
        final first = GeofenceMonitorService(
          repo: repo,
          notifications: notifications,
        );
        await first.start();
        firstLocation.positions.add(_position(accuracy: 25));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(notifications.titles, isEmpty);
        firstLocation.positions.add(_position());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(notifications.titles, ["You're near Example Cafe"]);
        await first.stop();

        final secondLocation = _LocationPlatform();
        GeolocatorPlatform.instance = secondLocation;
        final second = GeofenceMonitorService(
          repo: repo,
          notifications: notifications,
        );
        await second.start();
        secondLocation.positions.add(_position());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(notifications.titles, hasLength(1));
        await second.stop();
        await firstLocation.positions.close();
        await secondLocation.positions.close();
      },
    );

    test('caps a single nearby burst at two notifications', () async {
      final repo = _PollingRepo()
        ..response = Future.value(const [
          NearbyMerchantCandidate(
            merchantId: 'a',
            location: GeoPoint(lat: 15, lng: 73),
          ),
          NearbyMerchantCandidate(
            merchantId: 'b',
            location: GeoPoint(lat: 15, lng: 73),
          ),
          NearbyMerchantCandidate(
            merchantId: 'c',
            location: GeoPoint(lat: 15, lng: 73),
          ),
        ]);
      final location = _LocationPlatform();
      GeolocatorPlatform.instance = location;
      final notifications = _Notifications();
      final service = GeofenceMonitorService(
        repo: repo,
        notifications: notifications,
      );
      await service.start();
      location.positions.add(_position());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(notifications.titles, hasLength(2));
      await service.stop();
      await location.positions.close();
    });

    test('rearms a visit only after leaving and returning', () async {
      final repo = _PollingRepo()
        ..response = Future.value(const [
          NearbyMerchantCandidate(
            merchantId: 'near',
            displayName: 'Example Cafe',
            location: GeoPoint(lat: 15, lng: 73),
          ),
        ]);
      final location = _LocationPlatform();
      GeolocatorPlatform.instance = location;
      final notifications = _Notifications();
      final service = GeofenceMonitorService(
        repo: repo,
        notifications: notifications,
      );
      await service.start();

      location.positions.add(_position());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      location.positions.add(_position(longitude: 73.001)); // ~107m away
      await Future<void>.delayed(const Duration(milliseconds: 10));
      location.positions.add(_position(longitude: 73.001));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      location.positions.add(_position());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(notifications.titles, [
        "You're near Example Cafe",
        "You're near Example Cafe",
      ]);
      await service.stop();
      await location.positions.close();
    });
  });

  group('GeofenceMonitorService construction/state', () {
    test('a freshly constructed service is not monitoring', () {
      final service = GeofenceMonitorService(
        repo: _FakeNearbyMerchantsRepository(),
      );
      expect(service.isMonitoring, isFalse);
    });

    test('stop() on a never-started service is a safe no-op', () async {
      final service = GeofenceMonitorService(
        repo: _FakeNearbyMerchantsRepository(),
      );
      await service.stop();
      expect(service.isMonitoring, isFalse);
    });
  });
}

Position _position({
  double latitude = 15,
  double longitude = 73,
  double accuracy = 5,
}) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: DateTime(2026, 10, 18),
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

class _LocationPlatform extends GeolocatorPlatform {
  bool enabled = true;
  LocationPermission permission = LocationPermission.always;
  int streamStarts = 0;
  final positions = StreamController<Position>.broadcast();
  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    streamStarts++;
    return positions.stream;
  }
}

class _PollingRepo implements NearbyMerchantsRepository {
  bool fail = false;
  double? radius;
  Future<List<NearbyMerchantCandidate>>? response;
  @override
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
    bool forceRefresh = false,
  }) async {
    radius = radiusM;
    if (fail) throw StateError('provider unavailable');
    return await response ?? const [];
  }
}

class _Notifications implements FlutterLocalNotificationsPlugin {
  bool fail = false;
  final titles = <String?>[];
  @override
  Future<bool?> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;
  @override
  Future<void> show(
    int id,
    String? title,
    String? body,
    NotificationDetails? details, {
    String? payload,
  }) async {
    if (fail) throw StateError('notification delivery failed');
    titles.add(title);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeNearbyMerchantsRepository implements NearbyMerchantsRepository {
  // Only used to satisfy GeofenceMonitorService's constructor for the
  // state tests above — no test here exercises a real position stream.
  @override
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
    bool forceRefresh = false,
  }) async => const [];
}
