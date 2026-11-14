import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Task H3 (Notification Settings). Mirrors GET/PUT /notification-preferences
/// exactly — see api/src/index.js's own doc-comments on those routes. The
/// server always returns every column (either the real row or its
/// conservative column defaults for a user who's never opened this screen),
/// so [fromJson] never needs to synthesize a default client-side.
class NotificationPreferences {
  final bool categoryLocation;
  final bool categoryCaps;
  final bool categoryMilestones;
  final bool categoryFeeWaivers;
  final bool categoryBills;
  final bool categoryExpiry;
  final bool categoryMonthlyReport;
  final bool categoryNeedsReview;
  final bool categoryTransactions;

  /// Two budget categories, not one. "Over budget" is a post-mortem and
  /// "running ahead of pace" is still actionable — someone who wants the
  /// early warning shouldn't be forced to take the late one as well.
  final bool categoryBudgetWarning;
  final bool categoryBudgetExceeded;

  /// "HH:MM:SS" (or "HH:MM") strings straight from Postgres `time` columns,
  /// or null when quiet hours aren't set. Kept as raw strings rather than
  /// parsed into TimeOfDay here — the repository layer stays UI-framework-free,
  /// the screen parses/formats for display.
  final String? quietHoursStart;
  final String? quietHoursEnd;

  final int dailyCap;

  const NotificationPreferences({
    required this.categoryLocation,
    required this.categoryCaps,
    required this.categoryMilestones,
    required this.categoryFeeWaivers,
    required this.categoryBills,
    required this.categoryExpiry,
    required this.categoryMonthlyReport,
    required this.categoryNeedsReview,
    this.categoryTransactions = true,
    this.categoryBudgetWarning = true,
    this.categoryBudgetExceeded = true,
    this.quietHoursStart,
    this.quietHoursEnd,
    required this.dailyCap,
  });

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    return NotificationPreferences(
      categoryLocation: json['category_location'] as bool? ?? false,
      categoryCaps: json['category_caps'] as bool? ?? true,
      categoryMilestones: json['category_milestones'] as bool? ?? true,
      categoryFeeWaivers: json['category_fee_waivers'] as bool? ?? true,
      categoryBills: json['category_bills'] as bool? ?? true,
      categoryExpiry: json['category_expiry'] as bool? ?? true,
      categoryMonthlyReport: json['category_monthly_report'] as bool? ?? false,
      categoryNeedsReview: json['category_needs_review'] as bool? ?? true,
      categoryTransactions: json['category_transactions'] as bool? ?? true,
      categoryBudgetWarning: json['category_budget_warning'] as bool? ?? true,
      categoryBudgetExceeded: json['category_budget_exceeded'] as bool? ?? true,
      quietHoursStart: json['quiet_hours_start'] as String?,
      quietHoursEnd: json['quiet_hours_end'] as String?,
      dailyCap: _dailyCapOf(json['daily_cap']),
    );
  }

  /// What a brand-new account gets from GET /notification-preferences (the
  /// server returns its own column defaults for a user with no row; these are
  /// the same values: location and the monthly report opt-in, everything else
  /// on, cap 3, no quiet hours). Used when there is neither a network nor a
  /// cached copy, so local alerts still follow the conservative defaults.
  static const NotificationPreferences defaults = NotificationPreferences(
    categoryLocation: false,
    categoryCaps: true,
    categoryMilestones: true,
    categoryFeeWaivers: true,
    categoryBills: true,
    categoryExpiry: true,
    categoryMonthlyReport: false,
    categoryNeedsReview: true,
    dailyCap: _defaultDailyCap,
  );

  static const int _defaultDailyCap = 3;

  static int _dailyCapOf(Object? raw) {
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? _defaultDailyCap;
  }

  /// Snake_case column names, the same shape the server returns and
  /// [fromJson] reads, so a copy can be kept in the local response cache.
  Map<String, dynamic> toJson() => {
    'category_location': categoryLocation,
    'category_caps': categoryCaps,
    'category_milestones': categoryMilestones,
    'category_fee_waivers': categoryFeeWaivers,
    'category_bills': categoryBills,
    'category_expiry': categoryExpiry,
    'category_monthly_report': categoryMonthlyReport,
    'category_needs_review': categoryNeedsReview,
    'category_transactions': categoryTransactions,
    'category_budget_warning': categoryBudgetWarning,
    'category_budget_exceeded': categoryBudgetExceeded,
    'quiet_hours_start': quietHoursStart,
    'quiet_hours_end': quietHoursEnd,
    'daily_cap': dailyCap,
  };
}

/// One row from `notification_muted_merchants`, joined with the merchant's
/// display name server-side (GET /notification-preferences/muted-merchants).
class MutedMerchant {
  final String merchantId;
  final DateTime mutedAt;
  final String merchantName;

  const MutedMerchant({required this.merchantId, required this.mutedAt, required this.merchantName});

  factory MutedMerchant.fromJson(Map<String, dynamic> json) {
    return MutedMerchant(
      merchantId: json['merchant_id'] as String,
      mutedAt: DateTime.parse(json['muted_at'] as String),
      merchantName: json['merchant_name'] as String? ?? 'Unknown merchant',
    );
  }

  Map<String, dynamic> toJson() => {
    'merchant_id': merchantId,
    'muted_at': mutedAt.toUtc().toIso8601String(),
    'merchant_name': merchantName,
  };
}

class NotificationPreferencesRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  NotificationPreferencesRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<NotificationPreferences> fetch() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/notification-preferences'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /notification-preferences failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return NotificationPreferences.fromJson(body['preferences'] as Map<String, dynamic>);
  }

  /// [changes] keys must be the exact snake_case column names (e.g.
  /// `category_caps`, `quiet_hours_start`, `daily_cap`) — the server matches
  /// them directly against `notification_preferences`'s own columns.
  Future<NotificationPreferences> update(Map<String, dynamic> changes) async {
    final response = await _client.put(
      Uri.parse('$apiBaseUrl/notification-preferences'),
      headers: _headers,
      body: jsonEncode(changes),
    );
    if (response.statusCode != 200) {
      throw ApiException('PUT /notification-preferences failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return NotificationPreferences.fromJson(body['preferences'] as Map<String, dynamic>);
  }

  Future<List<MutedMerchant>> fetchMutedMerchants() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/notification-preferences/muted-merchants'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /notification-preferences/muted-merchants failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['mutedMerchants'] as List).cast<Map<String, dynamic>>().map(MutedMerchant.fromJson).toList();
  }

  Future<void> muteMerchant(String merchantId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/notification-preferences/muted-merchants'),
      headers: _headers,
      body: jsonEncode({'merchantId': merchantId}),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /notification-preferences/muted-merchants failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  Future<void> unmuteMerchant(String merchantId) async {
    final response = await _client.delete(
      Uri.parse('$apiBaseUrl/notification-preferences/muted-merchants/$merchantId'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'DELETE /notification-preferences/muted-merchants/$merchantId failed: ${response.statusCode} ${response.body}',
      );
    }
  }
}
