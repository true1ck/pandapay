import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'api_exception.dart';

/// The server's safe identity for a user-owned future category rule.
///
/// The API intentionally never requires the app to construct a VPA or a
/// merchant key.  The source transaction is supplied to preview/create and
/// the server derives the exact key from its owned data.
enum MerchantRuleMatchBasis {
  vpa,
  strictName,
  unknown;

  static MerchantRuleMatchBasis fromJson(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'vpa' => MerchantRuleMatchBasis.vpa,
      'strict_name' ||
      'strictname' ||
      'name' => MerchantRuleMatchBasis.strictName,
      _ => MerchantRuleMatchBasis.unknown,
    };
  }

  String get wireValue => switch (this) {
    MerchantRuleMatchBasis.vpa => 'vpa',
    MerchantRuleMatchBasis.strictName => 'strict_name',
    MerchantRuleMatchBasis.unknown => 'unknown',
  };
}

/// A user-owned merchant category rule.  [matchValue] is optional and is
/// retained only when the API explicitly returns a safe/masked value; callers
/// should use [displayMerchantName] for user-facing copy.
class MerchantCategoryRule {
  final String id;
  final String displayMerchantName;
  final MerchantRuleMatchBasis matchBasis;
  final String? matchValue;
  final String? categoryId;
  final String? userCategoryId;
  final String? categoryName;
  final bool isActive;
  final int version;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? sourceTransactionId;

  const MerchantCategoryRule({
    required this.id,
    required this.displayMerchantName,
    required this.matchBasis,
    this.matchValue,
    this.categoryId,
    this.userCategoryId,
    this.categoryName,
    required this.isActive,
    required this.version,
    this.createdAt,
    this.updatedAt,
    this.sourceTransactionId,
  });

  factory MerchantCategoryRule.fromJson(Map<String, dynamic> json) {
    final displayName = _firstString(json, const [
      'displayMerchantName',
      'display_merchant_name',
      'merchantName',
      'merchant_name',
    ]);
    final nestedCategory = _firstValue(json, const ['category']);
    final category = nestedCategory is Map
        ? Map<String, dynamic>.from(nestedCategory)
        : const <String, dynamic>{};
    return MerchantCategoryRule(
      id: _requiredString(json, const ['id', 'ruleId', 'rule_id']),
      displayMerchantName: displayName ?? 'This merchant',
      matchBasis: MerchantRuleMatchBasis.fromJson(
        _firstValue(json, const ['matchBasis', 'match_basis']),
      ),
      matchValue: _firstString(json, const ['matchValue', 'match_value']),
      categoryId:
          _firstString(json, const ['categoryId', 'category_id']) ??
          _firstString(category, const ['categoryId', 'category_id']),
      userCategoryId:
          _firstString(json, const ['userCategoryId', 'user_category_id']) ??
          _firstString(category, const ['userCategoryId', 'user_category_id']),
      categoryName:
          _firstString(json, const [
            'categoryName',
            'category_name',
            'targetCategoryName',
            'target_category_name',
          ]) ??
          _firstString(category, const ['categoryName', 'category_name']),
      isActive:
          _firstBool(json, const ['isActive', 'is_active', 'enabled']) ?? true,
      version: _firstInt(json, const ['version', 'revision']) ?? 1,
      createdAt: _optionalDateTime(json, const ['createdAt', 'created_at']),
      updatedAt: _optionalDateTime(json, const ['updatedAt', 'updated_at']),
      sourceTransactionId: _firstString(json, const [
        'sourceTransactionId',
        'source_transaction_id',
      ]),
    );
  }
}

/// One safe example shown before the user opts into a rule.  The server owns
/// which rows are eligible; the app only renders this redacted preview.
class MerchantRulePreviewTransaction {
  final String id;
  final DateTime occurredAt;
  final String amountLabel;
  final String? merchantName;
  final String? currentCategoryName;

  const MerchantRulePreviewTransaction({
    required this.id,
    required this.occurredAt,
    required this.amountLabel,
    this.merchantName,
    this.currentCategoryName,
  });

  factory MerchantRulePreviewTransaction.fromJson(Map<String, dynamic> json) {
    final amount = _firstValue(json, const [
      'amountLabel',
      'amount_label',
      'amountInr',
      'amount_inr',
      'amount',
    ]);
    return MerchantRulePreviewTransaction(
      id: _requiredString(json, const [
        'id',
        'transactionId',
        'transaction_id',
      ]),
      occurredAt: _requiredDateTime(json, const [
        'occurredAt',
        'occurred_at',
        'date',
      ]),
      amountLabel: amount is String
          ? amount
          : amount is num
          ? '₹${amount.toStringAsFixed(2)}'
          : 'Transaction',
      merchantName: _firstString(json, const [
        'merchantName',
        'merchant_name',
        'displayMerchantName',
        'display_merchant_name',
      ]),
      currentCategoryName: _firstString(json, const [
        'currentCategoryName',
        'current_category_name',
        'categoryName',
        'category_name',
      ]),
    );
  }
}

class MerchantCategoryRulePreview {
  final String sourceTransactionId;
  final String displayMerchantName;
  final MerchantRuleMatchBasis matchBasis;
  final String? categoryId;
  final String? userCategoryId;
  final String? categoryName;
  final bool canCreate;
  final bool? offlineSafe;
  final MerchantCategoryRule? existingRule;
  final List<MerchantRulePreviewTransaction> examples;

  const MerchantCategoryRulePreview({
    required this.sourceTransactionId,
    required this.displayMerchantName,
    required this.matchBasis,
    this.categoryId,
    this.userCategoryId,
    this.categoryName,
    required this.canCreate,
    this.offlineSafe,
    this.existingRule,
    this.examples = const [],
  });

  bool get hasUsableIdentity =>
      matchBasis == MerchantRuleMatchBasis.vpa ||
      matchBasis == MerchantRuleMatchBasis.strictName;

  factory MerchantCategoryRulePreview.fromJson(Map<String, dynamic> json) {
    final rawExamples = _firstValue(json, const [
      'examples',
      'previewTransactions',
      'preview_transactions',
      'transactions',
    ]);
    final existing = _firstValue(json, const [
      'existingRule',
      'existing_rule',
      'rule',
    ]);
    final nestedCategoryValue = _firstValue(json, const ['category']);
    final nestedCategory = nestedCategoryValue is Map
        ? Map<String, dynamic>.from(nestedCategoryValue)
        : const <String, dynamic>{};
    return MerchantCategoryRulePreview(
      sourceTransactionId: _requiredString(json, const [
        'sourceTransactionId',
        'source_transaction_id',
        'transactionId',
        'transaction_id',
      ]),
      displayMerchantName:
          _firstString(json, const [
            'displayMerchantName',
            'display_merchant_name',
            'merchantName',
            'merchant_name',
          ]) ??
          'This merchant',
      matchBasis: MerchantRuleMatchBasis.fromJson(
        _firstValue(json, const ['matchBasis', 'match_basis']),
      ),
      categoryId:
          _firstString(json, const ['categoryId', 'category_id']) ??
          _firstString(nestedCategory, const ['categoryId', 'category_id']),
      userCategoryId:
          _firstString(json, const ['userCategoryId', 'user_category_id']) ??
          _firstString(nestedCategory, const [
            'userCategoryId',
            'user_category_id',
          ]),
      categoryName:
          _firstString(json, const [
            'categoryName',
            'category_name',
            'targetCategoryName',
            'target_category_name',
          ]) ??
          _firstString(nestedCategory, const ['categoryName', 'category_name']),
      canCreate:
          _firstBool(json, const ['canCreate', 'can_create', 'eligible']) ??
          true,
      offlineSafe: _firstBool(json, const ['offlineSafe', 'offline_safe']),
      existingRule: existing is Map
          ? MerchantCategoryRule.fromJson(Map<String, dynamic>.from(existing))
          : null,
      examples: rawExamples is List
          ? rawExamples
                .whereType<Map>()
                .map(
                  (item) => MerchantRulePreviewTransaction.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class MerchantRuleConflictException extends ApiException {
  final MerchantCategoryRule? currentRule;

  MerchantRuleConflictException(String debugMessage, {this.currentRule})
    : super(
        debugMessage,
        userMessage:
            'A future rule for this merchant changed on another device. Review it before updating.',
      );
}

class MerchantCategoryRulesRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  MerchantCategoryRulesRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<List<MerchantCategoryRule>> fetchRules({
    bool includeDisabled = true,
    int? limit,
    String? cursor,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/merchant-category-rules').replace(
      queryParameters: {
        'includeDisabled': includeDisabled.toString(),
        if (limit != null) 'limit': '$limit',
        if (cursor != null) 'cursor': cursor,
      },
    );
    final response = await _client.get(uri, headers: _headers);
    _ensure(response, 'GET /merchant-category-rules', {200});
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final raw =
        decoded['rules'] ?? decoded['merchantCategoryRules'] ?? decoded['data'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (item) =>
              MerchantCategoryRule.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  Future<MerchantCategoryRulePreview> preview({
    required String sourceTransactionId,
    String? categoryId,
    String? userCategoryId,
  }) async {
    _requireCategory(categoryId, userCategoryId);
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/merchant-category-rules/preview'),
      headers: _headers,
      body: jsonEncode({
        'sourceTransactionId': sourceTransactionId,
        if (categoryId != null) 'categoryId': categoryId,
        if (userCategoryId != null) 'userCategoryId': userCategoryId,
      }),
    );
    _ensure(response, 'POST /merchant-category-rules/preview', {200});
    return MerchantCategoryRulePreview.fromJson(_unwrap(response, 'preview'));
  }

  Future<MerchantCategoryRule> create({
    required String sourceTransactionId,
    String? categoryId,
    String? userCategoryId,
    int? expectedVersion,
    String? idempotencyKey,
  }) async {
    _requireCategory(categoryId, userCategoryId);
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/merchant-category-rules'),
      headers: _headers,
      body: jsonEncode({
        'sourceTransactionId': sourceTransactionId,
        if (categoryId != null) 'categoryId': categoryId,
        if (userCategoryId != null) 'userCategoryId': userCategoryId,
        if (expectedVersion != null) 'expectedVersion': expectedVersion,
        'idempotencyKey': idempotencyKey ?? const Uuid().v4(),
      }),
    );
    return _ruleResponse(response, 'POST /merchant-category-rules', {200, 201});
  }

  Future<MerchantCategoryRule> update(
    String ruleId, {
    String? categoryId,
    String? userCategoryId,
    bool? isActive,
    int? expectedVersion,
  }) async {
    if (categoryId == null && userCategoryId == null && isActive == null) {
      throw ArgumentError('A category or active state is required');
    }
    final response = await _client.patch(
      Uri.parse('$apiBaseUrl/merchant-category-rules/$ruleId'),
      headers: _headers,
      body: jsonEncode({
        if (categoryId != null) 'categoryId': categoryId,
        if (userCategoryId != null) 'userCategoryId': userCategoryId,
        if (isActive != null) 'isActive': isActive,
        if (expectedVersion != null) 'expectedVersion': expectedVersion,
      }),
    );
    return _ruleResponse(response, 'PATCH /merchant-category-rules/:id', {200});
  }

  Future<MerchantCategoryRule> disable(
    String ruleId, {
    int? expectedVersion,
  }) async {
    final uri = Uri.parse('$apiBaseUrl/merchant-category-rules/$ruleId');
    final response = await _client.delete(
      uri,
      headers: _headers,
      body: jsonEncode({
        if (expectedVersion != null) 'expectedVersion': expectedVersion,
      }),
    );
    return _ruleResponse(response, 'DELETE /merchant-category-rules/:id', {
      200,
      204,
    });
  }

  static void _requireCategory(String? categoryId, String? userCategoryId) {
    if ((categoryId == null || categoryId.isEmpty) &&
        (userCategoryId == null || userCategoryId.isEmpty)) {
      throw ArgumentError('A category id or user category id is required');
    }
  }

  MerchantCategoryRule _ruleResponse(
    http.Response response,
    String operation,
    Set<int> successCodes,
  ) {
    if (response.statusCode == 409) {
      final body = _decodeMap(response.body);
      final current =
          body['currentRule'] ?? body['current_rule'] ?? body['rule'];
      throw MerchantRuleConflictException(
        '$operation failed: ${response.statusCode} ${response.body}',
        currentRule: current is Map
            ? MerchantCategoryRule.fromJson(Map<String, dynamic>.from(current))
            : null,
      );
    }
    _ensure(response, operation, successCodes);
    if (response.statusCode == 204 || response.body.trim().isEmpty) {
      throw ApiException('$operation returned no rule payload');
    }
    return MerchantCategoryRule.fromJson(_unwrap(response, 'rule'));
  }

  static Map<String, dynamic> _unwrap(http.Response response, String key) {
    final decoded = _decodeMap(response.body);
    final value =
        decoded[key] ??
        decoded['merchantCategoryRule'] ??
        decoded['merchant_category_rule'] ??
        decoded['data'] ??
        decoded;
    if (value is! Map)
      throw const FormatException('Missing rule response payload');
    return Map<String, dynamic>.from(value);
  }

  static Map<String, dynamic> _decodeMap(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map)
      throw const FormatException('Expected object response');
    return Map<String, dynamic>.from(decoded);
  }

  static void _ensure(
    http.Response response,
    String operation,
    Set<int> success,
  ) {
    if (success.contains(response.statusCode)) return;
    throw ApiException(
      '$operation failed: ${response.statusCode} ${response.body}',
    );
  }
}

dynamic _firstValue(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    if (json.containsKey(key) && json[key] != null) return json[key];
  }
  return null;
}

String? _firstString(Map<String, dynamic> json, List<String> keys) {
  final value = _firstValue(json, keys);
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _requiredString(Map<String, dynamic> json, List<String> keys) {
  final value = _firstString(json, keys);
  if (value == null) throw const FormatException('Missing required string');
  return value;
}

int? _firstInt(Map<String, dynamic> json, List<String> keys) {
  final value = _firstValue(json, keys);
  if (value is num) return value.toInt();
  return value is String ? int.tryParse(value) : null;
}

bool? _firstBool(Map<String, dynamic> json, List<String> keys) {
  final value = _firstValue(json, keys);
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return null;
}

DateTime _requiredDateTime(Map<String, dynamic> json, List<String> keys) {
  final value = _firstString(json, keys);
  if (value == null) throw const FormatException('Missing required date');
  return DateTime.parse(value);
}

DateTime? _optionalDateTime(Map<String, dynamic> json, List<String> keys) {
  final value = _firstString(json, keys);
  return value == null ? null : DateTime.tryParse(value);
}
