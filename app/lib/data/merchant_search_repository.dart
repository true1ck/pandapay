import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'api_exception.dart';

/// B5 — HTTP client for GET /merchants/search. Public read, no auth, same
/// pattern as HttpNearbyMerchantsRepository (nearby_merchants_repository.dart)
/// — deserializes into the SAME NearbyMerchantCandidate shape that repo
/// uses, minus a distance (search has no origin point).
abstract class MerchantSearchRepository {
  Future<List<NearbyMerchantCandidate>> search(String query);
}

class HttpMerchantSearchRepository implements MerchantSearchRepository {
  final String baseUrl;
  final http.Client _client;

  HttpMerchantSearchRepository({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async {
    final uri = Uri.parse('$baseUrl/merchants/search').replace(queryParameters: {'q': query});
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException('GET /merchants/search failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final merchants = (body['merchants'] as List).cast<Map<String, dynamic>>();
    return merchants.map((json) {
      final lat = json['grid_lat'];
      final lng = json['grid_lng'];
      return NearbyMerchantCandidate(
        merchantId: json['merchant_id'] as String,
        displayName: json['display_name'] as String?,
        categoryId: json['category_id'] as String?,
        // Some merchants have no confirmed location row yet — grid_lat/lng
        // can be null. GeoPoint has no "unknown" state, so this falls back
        // to (0, 0) purely as a placeholder the UI never uses for distance
        // math (search results don't sort/filter by distance, unlike the
        // nearby-merchants screen) — only categoryId/displayName matter here.
        location: GeoPoint(
          lat: lat == null ? 0 : double.parse(lat.toString()),
          lng: lng == null ? 0 : double.parse(lng.toString()),
        ),
      );
    }).toList();
  }
}
