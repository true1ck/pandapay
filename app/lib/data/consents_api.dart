import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// H4 Privacy & Permissions. Thin IO boundary over Task H-0's
/// `user_consents` routes — mirrors ProfileApi's shape (app/lib/data/auth_api.dart):
/// constructor takes `{required apiBaseUrl, required accessToken}`, methods
/// throw [ApiException] on non-200.
///
/// `user_consents` is an append-only audit log (api/src/index.js's own
/// doc-comment on `POST /consents`: "Always inserts a NEW row ... a later
/// revocation is its own new row with granted=false, not an edit"), so both
/// reads below return every row the server chooses to hand back, already
/// ordered server-side — this class does no client-side sorting/collapsing.
class ConsentRecord {
  final String purpose;
  final bool granted;
  final DateTime grantedAt;
  final DateTime? revokedAt;
  final String? policyVersion;
  final String? sourceScreen;

  const ConsentRecord({
    required this.purpose,
    required this.granted,
    required this.grantedAt,
    this.revokedAt,
    this.policyVersion,
    this.sourceScreen,
  });

  factory ConsentRecord.fromJson(Map<String, dynamic> json) {
    return ConsentRecord(
      purpose: json['purpose'] as String,
      granted: json['granted'] as bool,
      grantedAt: DateTime.parse(json['granted_at'] as String),
      revokedAt: json['revoked_at'] == null ? null : DateTime.parse(json['revoked_at'] as String),
      policyVersion: json['policy_version'] as String?,
      sourceScreen: json['source_screen'] as String?,
    );
  }
}

class ConsentsApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  ConsentsApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  /// GET /consents — latest row per purpose (server-side `DISTINCT ON`).
  Future<List<ConsentRecord>> fetchLatest() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/consents'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /consents failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final consents = (body['consents'] as List).cast<Map<String, dynamic>>();
    return consents.map(ConsentRecord.fromJson).toList();
  }

  /// GET /consents/history — every row ever written, most recent first.
  Future<List<ConsentRecord>> fetchHistory() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/consents/history'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /consents/history failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final consents = (body['consents'] as List).cast<Map<String, dynamic>>();
    return consents.map(ConsentRecord.fromJson).toList();
  }

  /// POST /consents — A4's sign-up checkboxes (and any future H4 toggle)
  /// write through here. Always inserts a new row; see this class's own
  /// doc-comment above for why that's correct, not a bug.
  Future<void> submit({
    required String purpose,
    required bool granted,
    required String policyVersion,
    String? sourceScreen,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/consents'),
      headers: _headers,
      body: jsonEncode({
        'purpose': purpose,
        'granted': granted,
        'policyVersion': policyVersion,
        if (sourceScreen != null) 'sourceScreen': sourceScreen,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /consents failed: ${response.statusCode} ${response.body}');
    }
  }
}
