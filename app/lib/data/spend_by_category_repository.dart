import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'api_exception.dart';

/// One row of `GET /spend-by-category` — a trailing-window total for one
/// spend_categories row, or the `null`-keyed "uncategorized" bucket. Kept
/// as a distinct wire model rather than handed straight to [SpendProfile]
/// so the discover-new-cards screen can still show category names/slugs
/// for display, which [SpendProfile] itself has no reason to carry (the
/// acquisition engine only ever reads category IDs).
class CategorySpend {
  final String? categoryId;
  final String? categorySlug;
  final String? categoryName;
  final Money totalSpend;
  final int txnCount;

  const CategorySpend({
    required this.categoryId,
    required this.categorySlug,
    required this.categoryName,
    required this.totalSpend,
    required this.txnCount,
  });

  factory CategorySpend.fromJson(Map<String, dynamic> json) => CategorySpend(
    categoryId: json['categoryId'] as String?,
    categorySlug: json['categorySlug'] as String?,
    categoryName: json['categoryName'] as String?,
    totalSpend: Money.fromRupees((json['totalSpendInr'] as num).toDouble()),
    txnCount: json['txnCount'] as int,
  );

  /// Display label for the "why" breakdown — "Dining" for a real category,
  /// "Other spending" for the uncategorized bucket, never a bare `null`.
  String get displayName => categoryName ?? 'Other spending';
}

class SpendByCategoryRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  SpendByCategoryRepository({required this.apiBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Future<List<CategorySpend>> fetchSpendByCategory({int months = 12}) async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/spend-by-category?months=$months'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != 200) {
      throw ApiException('GET /spend-by-category failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['categories'] as List).cast<Map<String, dynamic>>().map(CategorySpend.fromJson).toList();
  }
}
