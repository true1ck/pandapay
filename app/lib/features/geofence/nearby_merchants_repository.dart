import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

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

class HttpNearbyMerchantsRepository implements NearbyMerchantsRepository {
  final String baseUrl;
  final http.Client _client;

  HttpNearbyMerchantsRepository({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  @override
  Future<List<NearbyMerchantCandidate>> fetchNearby({
    required double lat,
    required double lng,
    double radiusM = 2000,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/merchants/nearby',
    ).replace(queryParameters: {'lat': lat.toString(), 'lng': lng.toString(), 'radiusM': radiusM.toString()});
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('GET /merchants/nearby failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final merchants = (body['merchants'] as List).cast<Map<String, dynamic>>();
    return merchants.map((json) {
      return NearbyMerchantCandidate(
        merchantId: json['merchant_id'] as String,
        displayName: json['display_name'] as String?,
        categoryId: json['category_id'] as String?,
        location: GeoPoint(
          lat: double.parse(json['grid_lat'].toString()),
          lng: double.parse(json['grid_lng'].toString()),
        ),
      );
    }).toList();
  }
}
