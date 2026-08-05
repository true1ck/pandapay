import 'dart:math' as math;

/// UA-8.1: pure geo-matching logic — zero IO, zero platform channels. The
/// only thing this module knows is "given a point and a list of merchant
/// points, which merchants are within radius X" — it has no idea how the
/// point was obtained (GPS, a test fixture, whatever). See
/// app/lib/features/geofence/ for the foreground-triggered caller that
/// actually reads a device location once and drives this.
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint({required this.lat, required this.lng});
}

/// A merchant location candidate to match against — shaped after the
/// `merchants`/`merchant_locations` tables (AD-6, Chunk 23): `merchants.id`/
/// `display_name`/`category_id` joined to one `merchant_locations` row's
/// `grid_lat`/`grid_lng`. One merchant can have multiple locations
/// (a chain); each location is its own `NearbyMerchantCandidate`.
class NearbyMerchantCandidate {
  final String merchantId;
  final String? displayName;
  final String? categoryId;
  final GeoPoint location;

  const NearbyMerchantCandidate({
    required this.merchantId,
    required this.location,
    this.displayName,
    this.categoryId,
  });
}

/// A candidate matched within the search radius, with the actual distance
/// so callers (UI, ranking) can sort/display by proximity.
class NearbyMerchantMatch {
  final NearbyMerchantCandidate candidate;
  final double distanceMeters;

  const NearbyMerchantMatch({required this.candidate, required this.distanceMeters});
}

/// Earth's mean radius in meters — same constant used by every standard
/// haversine implementation (WGS84 mean radius, ~6371.0088 km; the ~0.0088km
/// wobble is irrelevant at the merchant-proximity scale this is used for).
const double _earthRadiusMeters = 6371000.0;

double _toRadians(double degrees) => degrees * math.pi / 180.0;

/// UA-8.1.1: great-circle distance between two points, in meters, via the
/// haversine formula. Pure math, no IO — this is the thing a unit test can
/// actually pin down with synthetic coordinates, unlike anything involving
/// real device GPS.
double haversineDistanceMeters(GeoPoint a, GeoPoint b) {
  final dLat = _toRadians(b.lat - a.lat);
  final dLng = _toRadians(b.lng - a.lng);
  final lat1 = _toRadians(a.lat);
  final lat2 = _toRadians(b.lat);

  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  return _earthRadiusMeters * c;
}

/// UA-8.1.2: filters [candidates] to those within [radiusMeters] of
/// [origin], sorted nearest-first. This is the whole of the "geofencing"
/// logic PandaPay actually runs today — see PROGRESS.md's UA-8 chunk for why
/// always-on background geofence monitoring was scoped out.
List<NearbyMerchantMatch> findNearbyMerchants({
  required GeoPoint origin,
  required List<NearbyMerchantCandidate> candidates,
  required double radiusMeters,
}) {
  final matches = <NearbyMerchantMatch>[];
  for (final candidate in candidates) {
    final distance = haversineDistanceMeters(origin, candidate.location);
    if (distance <= radiusMeters) {
      matches.add(NearbyMerchantMatch(candidate: candidate, distanceMeters: distance));
    }
  }
  matches.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
  return matches;
}
