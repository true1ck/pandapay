import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:test/test.dart';

void main() {
  group('haversineDistanceMeters', () {
    test('same point is zero distance', () {
      const p = GeoPoint(lat: 12.9716, lng: 77.5946); // Bengaluru
      expect(haversineDistanceMeters(p, p), 0.0);
    });

    test('a known real-world pair: Bengaluru MG Road to Bengaluru airport ~ 35km', () {
      // MG Road, Bengaluru vs. Kempegowda International Airport — real
      // coordinates, real known separation (~35km as the crow flies), not a
      // synthetic toy pair, so this pins the formula against reality.
      const mgRoad = GeoPoint(lat: 12.9756, lng: 77.6068);
      const airport = GeoPoint(lat: 13.1986, lng: 77.7066);

      final distance = haversineDistanceMeters(mgRoad, airport);

      // Allow a generous tolerance band — haversine ignores earth's
      // ellipsoidal shape, and "~35km" is not a precise ground-truth figure.
      expect(distance, greaterThan(25000));
      expect(distance, lessThan(35000));
    });

    test('a tiny synthetic offset (0.001 degree lat) is roughly 111 meters', () {
      const a = GeoPoint(lat: 12.9716, lng: 77.5946);
      const b = GeoPoint(lat: 12.9726, lng: 77.5946);

      final distance = haversineDistanceMeters(a, b);

      expect(distance, closeTo(111.0, 5.0));
    });

    test('distance is symmetric', () {
      const a = GeoPoint(lat: 12.9716, lng: 77.5946);
      const b = GeoPoint(lat: 13.0827, lng: 80.2707); // Chennai

      expect(haversineDistanceMeters(a, b), haversineDistanceMeters(b, a));
    });
  });

  group('findNearbyMerchants', () {
    const origin = GeoPoint(lat: 12.9716, lng: 77.5946);

    final near = NearbyMerchantCandidate(
      merchantId: 'near-merchant',
      displayName: 'Near Cafe',
      categoryId: 'dining',
      location: const GeoPoint(lat: 12.9720, lng: 77.5950), // a few hundred m
    );
    final far = NearbyMerchantCandidate(
      merchantId: 'far-merchant',
      displayName: 'Far Mall',
      categoryId: 'shopping',
      location: const GeoPoint(lat: 13.0827, lng: 80.2707), // Chennai, ~290km
    );
    final middling = NearbyMerchantCandidate(
      merchantId: 'middling-merchant',
      displayName: 'Middling Store',
      categoryId: 'shopping',
      location: const GeoPoint(lat: 12.9800, lng: 77.6050), // ~1.5km-ish
    );

    test('returns only candidates within the radius, nearest first', () {
      final matches = findNearbyMerchants(
        origin: origin,
        candidates: [far, middling, near],
        radiusMeters: 2000,
      );

      expect(matches.map((m) => m.candidate.merchantId).toList(), [
        'near-merchant',
        'middling-merchant',
      ]);
      expect(matches.first.distanceMeters, lessThan(matches.last.distanceMeters));
    });

    test('an empty candidate list returns no matches', () {
      final matches = findNearbyMerchants(origin: origin, candidates: [], radiusMeters: 5000);
      expect(matches, isEmpty);
    });

    test('radius of zero only matches the exact same point', () {
      final exact = NearbyMerchantCandidate(merchantId: 'exact', location: origin);
      final matches = findNearbyMerchants(
        origin: origin,
        candidates: [exact, near],
        radiusMeters: 0,
      );
      expect(matches.map((m) => m.candidate.merchantId).toList(), ['exact']);
    });

    test('a very large radius matches everything, still sorted nearest first', () {
      final matches = findNearbyMerchants(
        origin: origin,
        candidates: [far, near, middling],
        radiusMeters: 1000000,
      );
      expect(matches, hasLength(3));
      expect(matches.first.candidate.merchantId, 'near-merchant');
      expect(matches.last.candidate.merchantId, 'far-merchant');
    });
  });
}
