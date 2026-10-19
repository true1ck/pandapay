import 'dart:async';
import 'dart:convert';

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

/// Manual place lookup used to test the proximity flow without relying on a
/// fresh handset GPS fix. Results are unverified OSM candidates and must stay
/// visibly separate from PandaPay's published merchant directory.
abstract class NearbyPlaceSearchRepository {
  Future<List<NearbyMerchantCandidate>> searchPlaces({
    required String query,
    double? lat,
    double? lng,
    double radiusM = 5000,
  });

  Future<NearbyPlaceSearchResult> searchPlacesWithStatus({
    required String query,
    double? lat,
    double? lng,
    double radiusM = 5000,
  }) async {
    return NearbyPlaceSearchResult(
      candidates: await searchPlaces(
        query: query,
        lat: lat,
        lng: lng,
        radiusM: radiusM,
      ),
    );
  }
}

class NearbyPlaceSearchResult {
  final List<NearbyMerchantCandidate> candidates;
  final bool unavailable;
  final String? message;

  const NearbyPlaceSearchResult({
    required this.candidates,
    this.unavailable = false,
    this.message,
  });
}

class NearbyMerchantCacheSnapshot {
  final DateTime fetchedAt;
  final List<NearbyMerchantCandidate> candidates;

  const NearbyMerchantCacheSnapshot({
    required this.fetchedAt,
    required this.candidates,
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
  // Keep the last successful result available through short public-map
  // provider outages. The cache key is rounded to ~100m and scoped to the
  // signed-in session, so this remains a local, coarse location snapshot.
  static const _maxStale = Duration(hours: 24);

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
  }) async {
    try {
      final prefs = await _preferences;
      final raw = prefs.getString(key(lat: lat, lng: lng, radiusM: radiusM));
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final fetchedAt = DateTime.parse(decoded['fetched_at'] as String);
      if (DateTime.now().difference(fetchedAt) > _maxStale) return null;
      final candidates = parseNearbyMerchantsPayload(
        jsonEncode({'merchants': decoded['merchants']}),
      );
      return NearbyMerchantCacheSnapshot(
        fetchedAt: fetchedAt,
        candidates: candidates,
      );
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
        'merchants': candidates.map(_candidateToJson).toList(),
      }),
    );
  }
}

class HttpNearbyMerchantsRepository
    implements
        NearbyMerchantDiscoveryRepository,
        NearbyMerchantCacheRepository,
        NearbyPlaceSearchRepository {
  final String baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  final SharedPreferencesNearbyMerchantCache? localCache;

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

  Future<http.Response> _get(Uri uri) async {
    try {
      return await _client.get(uri).timeout(requestTimeout);
    } on TimeoutException {
      throw ApiException(
        'GET ${uri.path} timed out',
        userMessage:
            'Nearby search took too long. Please check your connection and try again.',
      );
    }
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
  Future<List<NearbyMerchantCandidate>> searchPlaces({
    required String query,
    double? lat,
    double? lng,
    double radiusM = 5000,
  }) async {
    final result = await searchPlacesWithStatus(
      query: query,
      lat: lat,
      lng: lng,
      radiusM: radiusM,
    );
    return result.candidates;
  }

  @override
  Future<NearbyPlaceSearchResult> searchPlacesWithStatus({
    required String query,
    double? lat,
    double? lng,
    double radiusM = 5000,
  }) async {
    final uri = Uri.parse('$baseUrl/merchants/nearby/search');
    final response = await _postJson(uri, {
      'q': query.trim(),
      if (lat != null || lng != null) 'lat': lat,
      if (lat != null || lng != null) 'lng': lng,
      'radiusM': radiusM,
    });
    if (response.statusCode != 200) {
      // Keep builds compatible with an API deployment from before the manual
      // place-search route was added. The first-party directory is still a
      // useful answer for queries such as "panda", and avoids turning an
      // otherwise recoverable 404 into the generic error shown by the screen.
      if (response.statusCode == 404) {
        final directoryUri = Uri.parse(
          '$baseUrl/merchants/search',
        ).replace(queryParameters: {'q': query.trim()});
        final directoryResponse = await _get(directoryUri);
        if (directoryResponse.statusCode == 200) {
          return NearbyPlaceSearchResult(
            candidates: parseNearbyMerchantsPayload(
              directoryResponse.body,
              defaultSource: 'published',
            ),
          );
        }
      }
      throw ApiException(
        'GET /merchants/nearby/search failed: ${response.statusCode} ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return NearbyPlaceSearchResult(
      candidates: parseNearbyMerchantsPayload(response.body),
      unavailable: decoded['unavailable'] == true,
      message: decoded['message'] as String?,
    );
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
