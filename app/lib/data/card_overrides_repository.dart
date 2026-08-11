import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

enum OverrideScope { vpa, merchantName, category }

OverrideScope _scopeFromJson(String raw) => switch (raw) {
  'vpa' => OverrideScope.vpa,
  'merchant_name' => OverrideScope.merchantName,
  'category' => OverrideScope.category,
  _ => throw ApiException('Unknown override scope: $raw'),
};

String _scopeToJson(OverrideScope scope) => switch (scope) {
  OverrideScope.vpa => 'vpa',
  OverrideScope.merchantName => 'merchant_name',
  OverrideScope.category => 'category',
};

/// B8: a single "always use X here" rule — mirrors `card_overrides`
/// (db/supabase/migrations/0004_user_domain.sql). Exactly one of
/// [vpa]/[merchantName]/[categoryId] is non-null, matching [scope] and the
/// table's `override_scope_populated` CHECK.
class CardOverride {
  final String id;
  final String userCardId;
  final OverrideScope scope;
  final String? vpa;
  final String? merchantName;
  final String? categoryId;
  final String? categoryName;
  final String? reasonNote;
  final bool isEnabled;
  final DateTime createdAt;
  final String cardName;
  final String? cardNickname;

  const CardOverride({
    required this.id,
    required this.userCardId,
    required this.scope,
    this.vpa,
    this.merchantName,
    this.categoryId,
    this.categoryName,
    this.reasonNote,
    required this.isEnabled,
    required this.createdAt,
    required this.cardName,
    this.cardNickname,
  });

  /// What the override screen and B1's "override active" chip show —
  /// nickname if the user set one, else the product name (same fallback
  /// TransactionEntry.cardDisplayName uses in user_cards_repository.dart).
  String get cardDisplayName => (cardNickname?.isNotEmpty == true) ? cardNickname! : cardName;

  factory CardOverride.fromJson(Map<String, dynamic> json) => CardOverride(
    id: json['id'] as String,
    userCardId: json['user_card_id'] as String,
    scope: _scopeFromJson(json['scope'] as String),
    vpa: json['vpa'] as String?,
    merchantName: json['merchant_name'] as String?,
    categoryId: json['category_id'] as String?,
    categoryName: json['category_name'] as String?,
    reasonNote: json['reason_note'] as String?,
    isEnabled: json['is_enabled'] as bool,
    createdAt: DateTime.parse(json['created_at'] as String),
    cardName: json['card_name'] as String,
    cardNickname: json['card_nickname'] as String?,
  );

  /// Offline-cache round-trip only (docs/superpowers/plans/2026-08-08-offline-first-local-cache.md).
  Map<String, dynamic> toJson() => {
    'id': id,
    'user_card_id': userCardId,
    'scope': _scopeToJson(scope),
    'vpa': vpa,
    'merchant_name': merchantName,
    'category_id': categoryId,
    'category_name': categoryName,
    'reason_note': reasonNote,
    'is_enabled': isEnabled,
    'created_at': createdAt.toIso8601String(),
    'card_name': cardName,
    'card_nickname': cardNickname,
  };
}

class CardOverridesRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  CardOverridesRepository({required this.apiBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<List<CardOverride>> fetchOverrides() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/card-overrides'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /card-overrides failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['overrides'] as List).cast<Map<String, dynamic>>().map(CardOverride.fromJson).toList();
  }

  Future<CardOverride> createOverride({
    required String userCardId,
    required OverrideScope scope,
    String? vpa,
    String? merchantName,
    String? categoryId,
    String? reasonNote,
  }) async {
    final requestBody = {
      'userCardId': userCardId,
      'scope': _scopeToJson(scope),
      if (vpa != null) 'vpa': vpa,
      if (merchantName != null) 'merchantName': merchantName,
      if (categoryId != null) 'categoryId': categoryId,
      if (reasonNote != null) 'reasonNote': reasonNote,
    };
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/card-overrides'),
      headers: _headers,
      body: jsonEncode(requestBody),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /card-overrides failed: ${response.statusCode} ${response.body}');
    }
    return CardOverride.fromJson(
      (jsonDecode(response.body) as Map<String, dynamic>)['override'] as Map<String, dynamic>,
    );
  }

  /// B8 edit: PATCHes only the fields the caller actually passes (mirrors
  /// the backend route's `if (x !== undefined)` per-field logic exactly —
  /// see api/src/index.js's `PATCH /card-overrides/:id`). Only
  /// [isEnabled]/[reasonNote]/[userCardId] are ever sent: scope/vpa/
  /// merchantName/categoryId are NOT patchable by design (per Task 1's
  /// brief) — changing what a rule targets is a delete-and-recreate in the
  /// UI, not an edit, so this method has no parameters for them.
  ///
  /// To clear an existing note, pass `reasonNote: ''` explicitly (the
  /// backend turns an empty string into SQL NULL) — passing `null` (the
  /// default) omits the field from the PATCH body entirely, leaving it
  /// untouched.
  Future<void> updateOverride(String id, {bool? isEnabled, String? reasonNote, String? userCardId}) async {
    final requestBody = <String, dynamic>{
      if (isEnabled != null) 'isEnabled': isEnabled,
      if (reasonNote != null) 'reasonNote': reasonNote,
      if (userCardId != null) 'userCardId': userCardId,
    };
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/card-overrides/$id'),
      headers: _headers,
      body: jsonEncode(requestBody),
    );
    if (response.statusCode != 200) {
      throw ApiException('PATCH /card-overrides/$id failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> setEnabled(String id, bool enabled) => updateOverride(id, isEnabled: enabled);

  Future<void> delete(String id) async {
    final response = await _client.delete(Uri.parse('$apiBaseUrl/card-overrides/$id'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('DELETE /card-overrides/$id failed: ${response.statusCode} ${response.body}');
    }
  }
}
