import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/pandapay_domain.dart';

import 'api_exception.dart';

/// UA-1.2 (partial): fetches the published card catalogue from api/'s
/// GET /catalogue, which serves `v_card_catalogue_export` — the device sync
/// contract. Real production UA-1.2 also bundles a seed snapshot in the APK
/// and does incremental `data_version > local_max` sync (drift-backed local
/// cache); neither exists yet — this always does a full network fetch, so
/// there is currently no offline path. Flagged, not hidden.
abstract class CatalogueRepository {
  Future<List<CardProduct>> fetchCatalogue();
}

class HttpCatalogueRepository implements CatalogueRepository {
  final String baseUrl;
  final http.Client _client;

  HttpCatalogueRepository({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<List<CardProduct>> fetchCatalogue() async {
    final response = await _client.get(Uri.parse('$baseUrl/catalogue'));
    if (response.statusCode != 200) {
      throw ApiException('GET /catalogue failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final cards = (body['cards'] as List).cast<Map<String, dynamic>>();
    return cards.map((json) => CardProductJson.fromJson(json)).toList();
  }
}

/// spend_categories row shape from GET /categories — see providers.dart for
/// why this exists: reward_rules.category_id is a UUID FK, not a slug, and
/// every client-facing surface (B1 chips) refers to categories by slug.
class SpendCategory {
  final String id;
  final String slug;
  final String name;
  final bool isCustom;
  final String? parentCategoryId;
  final String? parentUserCategoryId;
  final List<String> matchTerms;
  const SpendCategory({
    required this.id,
    required this.slug,
    required this.name,
    this.isCustom = false,
    this.parentCategoryId,
    this.parentUserCategoryId,
    this.matchTerms = const [],
  });

  bool get isSubcategory =>
      parentCategoryId != null || parentUserCategoryId != null;

  String get displayName => isSubcategory ? '$parentName · $name' : name;

  // The picker fills this from its sibling list when it needs a fully
  // qualified label. Keeping the raw name here preserves existing callers.
  String get parentName => parentCategoryId ?? parentUserCategoryId ?? '';

  factory SpendCategory.fromJson(Map<String, dynamic> json) =>
      SpendCategory(
        id: json['id'] as String,
        slug: json['slug'] as String,
        name: json['name'] as String,
        isCustom: json['isCustom'] == true || json['is_custom'] == true,
        parentCategoryId: json['parentCategoryId'] as String? ??
            json['parent_category_id'] as String?,
        parentUserCategoryId: json['parentUserCategoryId'] as String? ??
            json['parent_user_category_id'] as String?,
        matchTerms: ((json['matchTerms'] as List?) ??
                (json['match_terms'] as List?) ??
                const [])
            .whereType<String>()
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'slug': slug,
    'name': name,
    if (isCustom) 'isCustom': true,
    if (parentCategoryId != null) 'parentCategoryId': parentCategoryId,
    if (parentUserCategoryId != null)
      'parentUserCategoryId': parentUserCategoryId,
    if (matchTerms.isNotEmpty) 'matchTerms': matchTerms,
  };
}

bool isCustomCategoryId(String? id) => id?.startsWith('custom:') == true;

String? categoryIdForServer(
  String? id, [
  Iterable<SpendCategory> categories = const <SpendCategory>[],
]) {
  if (!isCustomCategoryId(id)) return id;
  final selected = categories.where((category) => category.id == id).firstOrNull;
  return selected?.parentCategoryId;
}

String? userCategoryIdForServer(String? id) {
  if (!isCustomCategoryId(id)) return null;
  final value = id!.substring('custom:'.length);
  return value.isEmpty ? null : value;
}

abstract class CategoryRepository {
  Future<List<SpendCategory>> fetchCategories();
}

class HttpCategoryRepository implements CategoryRepository {
  final String baseUrl;
  final http.Client _client;

  HttpCategoryRepository({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  @override
  Future<List<SpendCategory>> fetchCategories() async {
    final response = await _client.get(Uri.parse('$baseUrl/categories'));
    if (response.statusCode != 200) {
      throw ApiException('GET /categories failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final categories = (body['categories'] as List).cast<Map<String, dynamic>>();
    return categories.map((json) => SpendCategory.fromJson(json)).toList();
  }
}
