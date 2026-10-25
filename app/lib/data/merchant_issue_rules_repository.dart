import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'api_exception.dart';

/// The action discriminator shared by the future merchant-rule contract.
///
/// Category rules already ship on `/merchant-category-rules`. Issue flags use
/// the same owner-scoped contract with `action: issue_flag`; keeping the
/// discriminator explicit prevents a flag opt-in from silently changing a
/// transaction category. The API may expose this as a separate route while
/// it rolls out; the repository deliberately keeps the wire shape typed so a
/// route switch does not leak into the UI.
enum MerchantRuleAction {
  category('category'),
  flag('flag');

  final String wireValue;
  const MerchantRuleAction(this.wireValue);

  static MerchantRuleAction fromJson(dynamic value) => switch (
    value?.toString().trim().toLowerCase()
  ) {
    'flag' || 'issue_flag' => MerchantRuleAction.flag,
    _ => MerchantRuleAction.category,
  };
}

/// Values shown by Report an issue and persisted as the future flag action.
enum MerchantIssueKind {
  wrongReward('wrong_reward', 'Wrong reward'),
  duplicateCharge('duplicate_charge', 'Duplicate charge'),
  cardNotRecognized('card_not_recognized', 'Card not recognized'),
  other('other', 'Other');

  final String wireValue;
  final String label;
  const MerchantIssueKind(this.wireValue, this.label);
}

class MerchantIssueCandidate {
  final String id;
  final DateTime occurredAt;
  final String amountLabel;
  final String? merchantName;
  final String? currentFlagLabel;
  final bool isSelectable;
  final bool isDefaultSelected;
  final String? reason;

  const MerchantIssueCandidate({
    required this.id,
    required this.occurredAt,
    required this.amountLabel,
    this.merchantName,
    this.currentFlagLabel,
    this.isSelectable = true,
    this.isDefaultSelected = true,
    this.reason,
  });

  factory MerchantIssueCandidate.fromJson(Map<String, dynamic> json) {
    final amount = _first(json, const [
      'amountLabel',
      'amount_label',
      'amountInr',
      'amount_inr',
      'amount',
    ]);
    return MerchantIssueCandidate(
      id: _requiredString(json, const ['id', 'transactionId', 'transaction_id']),
      occurredAt: _date(json, const ['occurredAt', 'occurred_at', 'date']),
      amountLabel: amount is String
          ? amount
          : amount is num
          ? '₹${amount.toStringAsFixed(2)}'
          : 'Transaction',
      merchantName: _string(json, const [
        'merchantName',
        'merchant_name',
        'displayMerchantName',
        'display_merchant_name',
      ]),
      currentFlagLabel: _string(json, const [
        'currentFlagLabel',
        'current_flag_label',
        'issueLabel',
        'issue_label',
      ]),
      isSelectable: _bool(json, const ['isSelectable', 'is_selectable']) ?? true,
      isDefaultSelected:
          _bool(json, const ['isDefaultSelected', 'is_default_selected', 'selected']) ?? true,
      reason: _string(json, const ['reason', 'ineligibleReason', 'ineligible_reason']),
    );
  }
}

class MerchantIssueRulePreview {
  final String previewId;
  final String sourceTransactionId;
  final String displayMerchantName;
  final String matchBasis;
  final MerchantIssueKind issueKind;
  final bool canCreate;
  final bool? offlineSafe;
  final List<MerchantIssueCandidate> candidates;

  const MerchantIssueRulePreview({
    required this.previewId,
    required this.sourceTransactionId,
    required this.displayMerchantName,
    required this.matchBasis,
    required this.issueKind,
    required this.canCreate,
    this.offlineSafe,
    this.candidates = const [],
  });

  factory MerchantIssueRulePreview.fromJson(Map<String, dynamic> json) {
    final raw = _first(json, const [
      'candidates',
      'previewTransactions',
      'preview_transactions',
      'transactions',
      'examples',
    ]);
    final issue = _string(json, const ['issueKind', 'issue_kind', 'flag', 'flagKind']);
    return MerchantIssueRulePreview(
      previewId: _string(json, const ['previewId', 'preview_id', 'id']) ??
          _requiredString(json, const ['sourceTransactionId', 'source_transaction_id']),
      sourceTransactionId: _requiredString(json, const [
        'sourceTransactionId',
        'source_transaction_id',
        'transactionId',
        'transaction_id',
      ]),
      displayMerchantName: _string(json, const [
            'displayMerchantName',
            'display_merchant_name',
            'merchantName',
            'merchant_name',
          ]) ??
          'This merchant',
      matchBasis: _string(json, const ['matchBasis', 'match_basis']) ?? 'unknown',
      issueKind: MerchantIssueKind.values.firstWhere(
        (kind) => kind.wireValue == issue,
        orElse: () => MerchantIssueKind.other,
      ),
      canCreate: _bool(json, const ['canCreate', 'can_create', 'eligible']) ?? true,
      offlineSafe: _bool(json, const ['offlineSafe', 'offline_safe']),
      candidates: raw is List
          ? raw
                .whereType<Map>()
                .map((item) => MerchantIssueCandidate.fromJson(Map<String, dynamic>.from(item)))
                .toList(growable: false)
          : const [],
    );
  }
}

class MerchantIssueBulkApplyResult {
  final int changedCount;
  final int skippedCount;
  final List<String> changedTransactionIds;

  const MerchantIssueBulkApplyResult({
    required this.changedCount,
    this.skippedCount = 0,
    this.changedTransactionIds = const [],
  });

  factory MerchantIssueBulkApplyResult.fromJson(Map<String, dynamic> json) {
    final ids = _first(json, const ['changedTransactionIds', 'changed_transaction_ids']);
    return MerchantIssueBulkApplyResult(
      changedCount: _int(json, const ['changedCount', 'changed_count', 'appliedCount']) ??
          (ids is List ? ids.length : 0),
      skippedCount: _int(json, const ['skippedCount', 'skipped_count']) ?? 0,
      changedTransactionIds:
          ids is List ? ids.whereType<String>().toList(growable: false) : const [],
    );
  }
}

/// API adapter for future issue flags. The endpoint names are intentionally
/// centralized here because the server may alias them during rollout.
class MerchantIssueRulesRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  MerchantIssueRulesRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<MerchantIssueRulePreview> preview({
    required String sourceTransactionId,
    required MerchantIssueKind issueKind,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/merchant-category-rules/preview'),
      headers: _headers,
      body: jsonEncode({
        'sourceTransactionId': sourceTransactionId,
        'action': MerchantRuleAction.flag.wireValue,
        'flag': issueKind.wireValue,
      }),
    );
    _ensure(response, 'POST /merchant-category-rules/preview', {200});
    return MerchantIssueRulePreview.fromJson(_unwrap(response, 'preview'));
  }

  /// Creates only the future rule. Existing transactions have no persisted
  /// issue-flag field, so there is deliberately no historical bulk mutation
  /// endpoint. The preview's examples are informational and are never marked
  /// by this operation.
  Future<void> createFutureRule({
    required String sourceTransactionId,
    required MerchantIssueKind issueKind,
    String? idempotencyKey,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/merchant-category-rules'),
      headers: _headers,
      body: jsonEncode({
        'sourceTransactionId': sourceTransactionId,
        'action': MerchantRuleAction.flag.wireValue,
        'flag': issueKind.wireValue,
        'idempotencyKey': idempotencyKey ?? const Uuid().v4(),
      }),
    );
    _ensure(response, 'POST /merchant-category-rules', {200, 201});
  }
}

dynamic _first(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    if (json[key] != null) return json[key];
  }
  return null;
}

String? _string(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}

String _requiredString(Map<String, dynamic> json, List<String> keys) =>
    _string(json, keys) ?? (throw const FormatException('Missing required id'));

DateTime _date(Map<String, dynamic> json, List<String> keys) {
  final value = _string(json, keys);
  if (value == null) throw const FormatException('Missing transaction date');
  return DateTime.parse(value);
}

bool? _bool(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return null;
}

int? _int(Map<String, dynamic> json, List<String> keys) {
  final value = _first(json, keys);
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

Map<String, dynamic> _decode(http.Response response) {
  final decoded = jsonDecode(response.body);
  if (decoded is! Map) throw const FormatException('Expected object response');
  return Map<String, dynamic>.from(decoded);
}

Map<String, dynamic> _unwrap(http.Response response, String key) {
  final decoded = _decode(response);
  final value = decoded[key] ?? decoded['data'] ?? decoded;
  if (value is! Map) throw const FormatException('Missing preview payload');
  return Map<String, dynamic>.from(value);
}

void _ensure(http.Response response, String operation, Set<int> success) {
  if (success.contains(response.statusCode)) return;
  throw ApiException('$operation failed: ${response.statusCode} ${response.body}');
}
