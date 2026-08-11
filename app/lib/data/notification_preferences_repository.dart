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
      quietHoursStart: json['quiet_hours_start'] as String?,
      quietHoursEnd: json['quiet_hours_end'] as String?,
      dailyCap: json['daily_cap'] is int ? json['daily_cap'] as int : int.parse(json['daily_cap'].toString()),
    );
  }
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
