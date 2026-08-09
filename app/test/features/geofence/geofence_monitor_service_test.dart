import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/geofence/geofence_monitor_service.dart';
import 'package:pandapay/features/geofence/nearby_merchants_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  group('GeofenceMonitorService.shouldNotify', () {
    test('a merchant never notified before should notify', () {
      final result = GeofenceMonitorService.shouldNotify(
        merchantId: 'm1',
        now: DateTime(2026, 1, 1, 12, 0),
        lastNotifiedAt: {},
        cooldown: const Duration(minutes: 30),
      );
      expect(result, isTrue);
    });

    test('a merchant notified within the cooldown window should not notify again', () {
      final lastNotifiedAt = {'m1': DateTime(2026, 1, 1, 12, 0)};
      final result = GeofenceMonitorService.shouldNotify(
        merchantId: 'm1',
        now: DateTime(2026, 1, 1, 12, 10),
        lastNotifiedAt: lastNotifiedAt,
        cooldown: const Duration(minutes: 30),
      );
      expect(result, isFalse);
    });

    test('a merchant notified exactly at the cooldown boundary should notify again', () {
      final lastNotifiedAt = {'m1': DateTime(2026, 1, 1, 12, 0)};
      final result = GeofenceMonitorService.shouldNotify(
        merchantId: 'm1',
        now: DateTime(2026, 1, 1, 12, 30),
        lastNotifiedAt: lastNotifiedAt,
        cooldown: const Duration(minutes: 30),
      );
      expect(result, isTrue);
    });

    test('a merchant notified past the cooldown window should notify again', () {
      final lastNotifiedAt = {'m1': DateTime(2026, 1, 1, 12, 0)};
      final result = GeofenceMonitorService.shouldNotify(
        merchantId: 'm1',
        now: DateTime(2026, 1, 1, 13, 0),
        lastNotifiedAt: lastNotifiedAt,
        cooldown: const Duration(minutes: 30),
      );
      expect(result, isTrue);
    });

    test('cooldown for one merchant does not affect a different merchant', () {
      final lastNotifiedAt = {'m1': DateTime(2026, 1, 1, 12, 0)};
      final result = GeofenceMonitorService.shouldNotify(
        merchantId: 'm2',
        now: DateTime(2026, 1, 1, 12, 5),
        lastNotifiedAt: lastNotifiedAt,
        cooldown: const Duration(minutes: 30),
      );
      expect(result, isTrue);
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

class _FakeNearbyMerchantsRepository implements NearbyMerchantsRepository {
  // Only used to satisfy GeofenceMonitorService's constructor for the
  // state tests above — no test here exercises a real position stream.
  @override
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
  }) async =>
      const [];
}
