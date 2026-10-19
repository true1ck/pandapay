import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/api_exception.dart';

/// Foreground nearby lookup radius. Keep it at or below 2 km so Home and the
/// Nearby list search the same area.
const _nearbyMerchantSearchRadiusRaw = String.fromEnvironment(
  'PANDAPAY_NEARBY_RADIUS_METERS',
  defaultValue: '2000',
);
const _nearbyLookupTimeout = Duration(seconds: 25);

/// A successful nearby result remains usable on the device for this long.
///
/// This is deliberately a long, local-only freshness window. Nearby places
/// are slow-moving data, and the product is a convenience feature rather
/// than a live map. Explicit refreshes still bypass this gate.
const nearbyMerchantClientFreshness = Duration(days: 30);

/// A cached result is reused while the device remains in the same practical
/// nearby zone. The current location is still used to re-sort merchants, so
/// moving inside this zone does not require a backend/provider request.
const nearbyMerchantCacheReuseDistanceMeters = 750.0;

/// Keep very old local results available as an offline fallback, but do not
/// allow an unbounded location history to accumulate in SharedPreferences.
const nearbyMerchantCacheMaxAge = Duration(days: 90);

/// Home may paint this in-memory snapshot immediately while it obtains a
/// current local GPS fix. The fix then decides whether the cached zone still
/// applies; this prevents a tab remount from permanently showing a stale
/// merchant after the user has travelled elsewhere.
const nearbyMerchantHomeSnapshotWarmup = Duration(minutes: 5);

final nearbyMerchantSearchRadiusMeters = () {
  final parsed = double.tryParse(_nearbyMerchantSearchRadiusRaw);
  return parsed != null && parsed > 0 && parsed <= 2000 ? parsed : 2000.0;
}();

/// HTTP client for nearby recommendations and typed place search. Both use
/// OpenStreetMap data and normalize to the same candidate model.
abstract class NearbyMerchantsRepository {
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
    bool forceRefresh = false,
  });
}

abstract class NearbyMerchantDiscoveryRepository
    implements NearbyMerchantsRepository {
  /// Free discovery lookup. The default deliberately delegates to the
  /// nearby lookup so existing fakes and background monitoring
  /// keep their old behaviour unless a concrete repository opts in.
  Future<List<NearbyMerchantCandidate>> discoverNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
    String? categoryId,
  }) => fetchNearby(lat: lat, lng: lng, radiusM: radiusM);
}

class NearbyMerchantCacheSnapshot {
  final DateTime fetchedAt;
  final List<NearbyMerchantCandidate> candidates;

  const NearbyMerchantCacheSnapshot({
    required this.fetchedAt,
    required this.candidates,
  });
}

/// The last resolved Home context. This is deliberately an app-memory
/// snapshot, not a persisted location history entry: it lets Home paint the
/// previous answer while a fresh local position is checked after a remount.
class NearbyContextSnapshot {
  final DateTime resolvedAt;
  final GeoPoint origin;
  final NearbyMerchantMatch? match;

  const NearbyContextSnapshot({
    required this.resolvedAt,
    required this.origin,
    required this.match,
  });
}

abstract class NearbyMerchantCacheRepository {
  Future<NearbyMerchantCacheSnapshot?> readCachedNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
  });
}

/// Best-effort device cache for public nearby-place data.
///
/// The namespace is supplied by the app's session cache namespace so a cached
/// location result from one signed-in profile is never shown to another.
class SharedPreferencesNearbyMerchantCache {
  // Keep the last successful result available for a meaningful movement-based
  // cache window. The cache key is only an index; the stored coordinates and
  // Haversine distance decide whether a zone can actually be reused.
  static const _maxStale = nearbyMerchantCacheMaxAge;
  static const _maxCachedZones = 48;

  final String namespace;
  final Future<SharedPreferences> _preferences;

  SharedPreferencesNearbyMerchantCache({
    required this.namespace,
    Future<SharedPreferences>? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance();

  String key({
    required double lat,
    required double lng,
    required double radiusM,
  }) {
    return '$namespace:nearby_merchants:${lat.toStringAsFixed(3)}:${lng.toStringAsFixed(3)}:${radiusM.round()}';
  }

  Future<NearbyMerchantCacheSnapshot?> read({
    required double lat,
    required double lng,
    double radiusM = 2000,
    Duration maxAge = _maxStale,
  }) async {
    try {
      final prefs = await _preferences;
      NearbyMerchantCacheSnapshot? best;
      var bestDistance = double.infinity;

      // Search all nearby-zone entries in this session instead of only a
      // 3x3 set of rounded buckets. A three-decimal key is about 100m, while
      // the reusable zone is intentionally larger; scanning the small local
      // index makes movement across any bucket boundary harmless.
      final radiusSuffix = ':${radiusM.round()}';
      final keys = prefs.getKeys().where(
        (candidateKey) =>
            candidateKey.startsWith('$namespace:nearby_merchants:') &&
            candidateKey.endsWith(radiusSuffix),
      );

      for (final candidateKey in keys) {
        final raw = prefs.getString(candidateKey);
        if (raw == null) continue;
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final fetchedAt = DateTime.parse(decoded['fetched_at'] as String);
        final age = DateTime.now().difference(fetchedAt);
        if (age < Duration.zero || age > maxAge) continue;

        // Entries written before the coordinate metadata was added remain
        // readable in their exact bucket; adjacent legacy entries are not
        // safe to reuse because their original centre is unknown.
        final cachedLat = _number(decoded['lat']);
        final cachedLng = _number(decoded['lng']);
        final distance = cachedLat != null && cachedLng != null
            ? _distanceMeters(lat, lng, cachedLat, cachedLng)
            : candidateKey == key(lat: lat, lng: lng, radiusM: radiusM)
            ? 0.0
            : double.infinity;
        if (distance > nearbyMerchantCacheReuseDistanceMeters ||
            distance >= bestDistance) {
          continue;
        }

        final candidates = parseNearbyMerchantsPayload(
          jsonEncode({'merchants': decoded['merchants']}),
        );
        bestDistance = distance;
        best = NearbyMerchantCacheSnapshot(
          fetchedAt: fetchedAt,
          candidates: candidates,
        );
      }
      return best;
    } catch (_) {
      // A corrupt or unavailable local cache must never block the live lookup.
      return null;
    }
  }

  Future<void> write({
    required double lat,
    required double lng,
    required double radiusM,
    required List<NearbyMerchantCandidate> candidates,
  }) async {
    final prefs = await _preferences;
    await prefs.setString(
      key(lat: lat, lng: lng, radiusM: radiusM),
      jsonEncode({
        'fetched_at': DateTime.now().toIso8601String(),
        'lat': lat,
        'lng': lng,
        'merchants': candidates.map(_candidateToJson).toList(),
      }),
    );

    // Keep the local index bounded. This is only local app cache data; it is
    // safe to discard the oldest zones and prevents a long-lived commuter
    // from growing SharedPreferences forever.
    final entries = <String, DateTime>{};
    for (final candidateKey in prefs.getKeys().where(
      (candidateKey) =>
          candidateKey.startsWith('$namespace:nearby_merchants:') &&
          candidateKey.endsWith(':${radiusM.round()}'),
    )) {
      final raw = prefs.getString(candidateKey);
      if (raw == null) continue;
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        entries[candidateKey] = DateTime.parse(decoded['fetched_at'] as String);
      } catch (_) {
        // Ignore malformed entries here; read() already treats them as a
        // cache miss and a later write will naturally replace the index.
      }
    }
    final staleKeys = entries.keys.toList()
      ..sort((a, b) => entries[b]!.compareTo(entries[a]!));
    for (final staleKey in staleKeys.skip(_maxCachedZones)) {
      await prefs.remove(staleKey);
    }
  }
}

class HttpNearbyMerchantsRepository
    implements
        NearbyMerchantDiscoveryRepository,
        NearbyMerchantCacheRepository {
  final String baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  final SharedPreferencesNearbyMerchantCache? localCache;
  final Map<String, Future<List<NearbyMerchantCandidate>>> _inflight = {};

  HttpNearbyMerchantsRepository({
    required this.baseUrl,
    http.Client? client,
    this.requestTimeout = _nearbyLookupTimeout,
    this.localCache,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<http.Response> _postJson(Uri uri, Map<String, Object?> body) async {
    try {
      return await _client
          .post(
            uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw ApiException(
        'POST ${uri.path} timed out',
        userMessage:
            'Nearby search took too long. Please check your connection and try again.',
      );
    }
  }

  @override
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = await localCache?.read(
        lat: lat,
        lng: lng,
        radiusM: radiusM,
        maxAge: nearbyMerchantClientFreshness,
      );
      if (cached != null) return cached.candidates;
    }

    // Home, Nearby, and the monitor can converge on the same fix at once.
    // Coalesce that burst before it becomes multiple device -> API calls.
    final requestKey = _requestKey(lat: lat, lng: lng, radiusM: radiusM);
    final existing = _inflight[requestKey];
    if (existing != null) return existing;

    final request = _fetchAndCache(lat: lat, lng: lng, radiusM: radiusM);
    _inflight[requestKey] = request;
    try {
      return await request;
    } finally {
      if (identical(_inflight[requestKey], request)) {
        _inflight.remove(requestKey);
      }
    }
  }

  Future<List<NearbyMerchantCandidate>> _fetchAndCache({
    required double lat,
    required double lng,
    required double radiusM,
  }) async {
    // Nearby checks and typed place searches use the same public OSM service.
    // The latitude/longitude endpoint avoids depending on the separate Google
    // scraper for the primary Nearby button flow.
    final candidates = await discoverNearby(
      lat: lat,
      lng: lng,
      radiusM: radiusM,
    );
    try {
      await localCache?.write(
        lat: lat,
        lng: lng,
        radiusM: radiusM,
        candidates: candidates,
      );
    } catch (_) {
      // Local cache writes are optional and must not turn a successful fetch
      // into a failed nearby-merchants request.
    }
    return candidates;
  }

  @override
  Future<List<NearbyMerchantCandidate>> discoverNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
    String? categoryId,
  }) async {
    final uri = Uri.parse('$baseUrl/merchants/nearby/discover');
    final response = await _postJson(uri, {
      'lat': lat,
      'lng': lng,
      'radiusM': radiusM,
      if (categoryId != null && categoryId.isNotEmpty) 'categoryId': categoryId,
    });
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /merchants/nearby/discover failed: ${response.statusCode} ${response.body}',
      );
    }
    return parseNearbyMerchantsPayload(response.body);
  }

  @override
  Future<NearbyMerchantCacheSnapshot?> readCachedNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
  }) {
    final cache = localCache;
    if (cache == null) return Future.value(null);
    return cache.read(lat: lat, lng: lng, radiusM: radiusM);
  }

  String _requestKey({
    required double lat,
    required double lng,
    required double radiusM,
  }) =>
      '${lat.toStringAsFixed(3)}:${lng.toStringAsFixed(3)}:${radiusM.round()}';
}

List<NearbyMerchantCandidate> parseNearbyMerchantsPayload(
  String body, {
  String? defaultSource,
}) {
  final decoded = jsonDecode(body) as Map<String, dynamic>;
  final merchants = (decoded['merchants'] as List).cast<Map<String, dynamic>>();
  return merchants.map((json) {
    return NearbyMerchantCandidate(
      merchantId: json['merchant_id'] as String,
      displayName: json['display_name'] as String?,
      address: json['address'] as String?,
      categoryId: json['category_id'] as String?,
      location: GeoPoint(
        // Directory matches are allowed to have no confirmed location yet.
        // Search results do not use distance math, so (0, 0) is a safe
        // placeholder; a nearby lookup never returns null coordinates.
        lat: _coordinateValue(json['grid_lat']),
        lng: _coordinateValue(json['grid_lng']),
      ),
      source: json['source'] as String? ?? defaultSource,
      confidence: _confidenceValue(json['confidence']),
    );
  }).toList();
}

double _coordinateValue(Object? value) {
  if (value == null) return 0;
  return double.tryParse(value.toString()) ?? 0;
}

double? _confidenceValue(Object? value) {
  if (value is num) return value.toDouble();
  if (value == 'high') return 0.9;
  if (value == 'medium') return 0.65;
  if (value == 'low') return 0.35;
  return null;
}

Map<String, dynamic> _candidateToJson(NearbyMerchantCandidate candidate) => {
  'merchant_id': candidate.merchantId,
  'display_name': candidate.displayName,
  'address': candidate.address,
  'category_id': candidate.categoryId,
  'source': candidate.source,
  'confidence': candidate.confidence,
  'grid_lat': candidate.location.lat,
  'grid_lng': candidate.location.lng,
};

double? _number(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value');

double _distanceMeters(double latA, double lngA, double latB, double lngB) {
  const earthRadiusMeters = 6371000.0;
  final radians = math.pi / 180;
  final dLat = (latB - latA) * radians;
  final dLng = (lngB - lngA) * radians;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(latA * radians) *
          math.cos(latB * radians) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * earthRadiusMeters * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
