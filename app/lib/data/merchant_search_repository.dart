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

  /// Resolves a published merchant directory entry by its exact UPI VPA.
  /// This is deliberately a separate operation from name search: a VPA is
  /// the stable identifier carried by a scanned QR, while the display name
  /// may be absent or provider-generic (for example, "Paytm").
  Future<MerchantResolution?> resolveVpa(String vpa) =>
      throw UnimplementedError(
        'VPA resolution is not supported by this repository',
      );
}

class MerchantResolution {
  final String merchantId;
  final String vpa;
  final String? displayName;
  final String? mcc;
  final String? categoryId;
  final String? categoryName;
  final String? categorySlug;
  final String? confidence;
  final double? confidenceScore;
  final int? confirmationCount;
  final bool isP2p;
  final bool mccOperatorVerified;

  const MerchantResolution({
    required this.merchantId,
    required this.vpa,
    this.displayName,
    this.mcc,
    this.categoryId,
    this.categoryName,
    this.categorySlug,
    this.confidence,
    this.confidenceScore,
    this.confirmationCount,
    this.isP2p = false,
    this.mccOperatorVerified = false,
  });

  factory MerchantResolution.fromJson(Map<String, dynamic> json) {
    final score = json['confidence_score'];
    final confirmations = json['confirmation_count'];
    return MerchantResolution(
      merchantId: json['merchant_id'] as String,
      vpa: json['vpa'] as String,
      displayName: json['display_name'] as String?,
      mcc: json['mcc'] as String?,
      categoryId: json['category_id'] as String?,
      categoryName: json['category_name'] as String?,
      categorySlug: json['category_slug'] as String?,
      confidence: json['confidence'] as String?,
      confidenceScore: score == null ? null : double.tryParse(score.toString()),
      confirmationCount: confirmations == null
          ? null
          : int.tryParse(confirmations.toString()),
      isP2p: json['is_p2p'] == true,
      mccOperatorVerified: json['mcc_operator_verified'] == true,
    );
  }
}

/// Supplies an MCC for an outbound UPI intent without guessing from merchant
/// name/category. QR-provided MCC remains authoritative. For unsigned static
/// QRs with no MCC, only an exact-VPA MCC explicitly verified by an operator
/// may be added; confidence scores alone do not prove the acquiring MCC.
String? safeMerchantMccForUpiHandoff({
  required String? qrMcc,
  required bool qrHasSignature,
  required MerchantResolution? resolution,
}) {
  if (qrMcc != null && qrMcc.isNotEmpty) return qrMcc;
  if (qrHasSignature || resolution == null || resolution.isP2p) return null;
  final mcc = resolution.mcc;
  if (mcc == null || mcc.isEmpty || !resolution.mccOperatorVerified) {
    return null;
  }
  return mcc;
}

class HttpMerchantSearchRepository implements MerchantSearchRepository {
  final String baseUrl;
  final String? accessToken;
  final http.Client _client;

  HttpMerchantSearchRepository({
    required this.baseUrl,
    this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        if (accessToken != null && accessToken!.isNotEmpty)
          'Authorization': 'Bearer $accessToken',
      };

  @override
  Future<List<NearbyMerchantCandidate>> search(String query) async {
    final uri = Uri.parse(
      '$baseUrl/merchants/search',
    ).replace(queryParameters: {'q': query});
    final response = await _client.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /merchants/search failed: ${response.statusCode} ${response.body}',
      );
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

  @override
  Future<MerchantResolution?> resolveVpa(String vpa) async {
    final normalized = vpa.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final uri = Uri.parse(
      '$baseUrl/merchants/resolve',
    ).replace(queryParameters: {'vpa': normalized});
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /merchants/resolve failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final merchant = body['merchant'];
    if (merchant is! Map<String, dynamic>) return null;
    return MerchantResolution.fromJson(merchant);
  }
}
