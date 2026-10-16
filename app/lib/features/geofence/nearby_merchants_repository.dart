import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/api_exception.dart';

/// UA-8.3: HTTP client for api/'s `GET /merchants/nearby` — public read, no
/// auth required (same pattern as CatalogueRepository/CategoryRepository).
/// This is the thin IO boundary; the actual radius-matching math lives in
/// packages/pandapay_domain's pure `findNearbyMerchants` (the API already
/// filters server-side too, via its own SQL haversine expression — this
/// repository just deserializes what comes back into the same
/// [NearbyMerchantCandidate] shape the pure Dart matcher understands, so a
/// caller could re-filter/re-sort client-side without duplicating parsing).
abstract class NearbyMerchantsRepository {
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
  });
}

abstract class NearbyMerchantDiscoveryRepository
    implements NearbyMerchantsRepository {
  /// Free discovery fallback. The default deliberately delegates to the
  /// published-merchant lookup so existing fakes and background monitoring
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
        NearbyMerchantCacheRepository {
  final String baseUrl;
  final http.Client _client;
  final SharedPreferencesNearbyMerchantCache? localCache;

  HttpNearbyMerchantsRepository({
    required this.baseUrl,
    http.Client? client,
    this.localCache,
  }) : _client = client ?? http.Client();

  @override
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
  }) async {
    final uri = Uri.parse('$baseUrl/merchants/nearby').replace(
      queryParameters: {
        'lat': lat.toString(),
        'lng': lng.toString(),
        'radiusM': radiusM.toString(),
      },
    );
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /merchants/nearby failed: ${response.statusCode} ${response.body}',
      );
    }
    final candidates = parseNearbyMerchantsPayload(response.body);
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
    final uri = Uri.parse('$baseUrl/merchants/nearby/discover').replace(
      queryParameters: {
        'lat': lat.toString(),
        'lng': lng.toString(),
        'radiusM': radiusM.toString(),
        if (categoryId != null && categoryId.isNotEmpty)
          'categoryId': categoryId,
      },
    );
    final response = await _client.get(uri);
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
}

List<NearbyMerchantCandidate> parseNearbyMerchantsPayload(String body) {
  final decoded = jsonDecode(body) as Map<String, dynamic>;
  final merchants = (decoded['merchants'] as List).cast<Map<String, dynamic>>();
  return merchants.map((json) {
    return NearbyMerchantCandidate(
      merchantId: json['merchant_id'] as String,
      displayName: json['display_name'] as String?,
      categoryId: json['category_id'] as String?,
      location: GeoPoint(
        lat: double.parse(json['grid_lat'].toString()),
        lng: double.parse(json['grid_lng'].toString()),
      ),
      source: json['source'] as String?,
      confidence: _confidenceValue(json['confidence']),
    );
  }).toList();
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
  'category_id': candidate.categoryId,
  'source': candidate.source,
  'confidence': candidate.confidence,
  'grid_lat': candidate.location.lat,
  'grid_lng': candidate.location.lng,
};
