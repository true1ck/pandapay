import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// H2 Account (real) — thin client for api/'s account-deletion endpoints.
/// Mirrors `ProfileApi`'s exact constructor/method shape (auth_api.dart) so
/// this reads as the same family of API client, not a new pattern.
///
/// Both routes only schedule/cancel deletion (`profiles.deletion_requested_at`
/// / `deletion_due_at`) — neither calls `pandapay.execute_account_deletion()`
/// directly. Actually executing the deletion once `deletion_due_at` passes
/// needs a scheduled sweep job, which is out of this screen's scope.
class AccountApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  AccountApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  /// Schedules deletion 30 days out. Returns the `deletion_due_at` the
  /// server computed (never trust a client-computed date for this).
  Future<DateTime> requestDeletion() async {
    final response = await _client.post(Uri.parse('$apiBaseUrl/account/delete-request'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('POST /account/delete-request failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final profile = body['profile'] as Map<String, dynamic>?;
    final dueAt = profile?['deletion_due_at'] as String?;
    if (dueAt == null) {
      throw ApiException('POST /account/delete-request did not return deletion_due_at');
    }
    return DateTime.parse(dueAt);
  }

  /// Cancels a pending deletion — clears both `deletion_requested_at` and
  /// `deletion_due_at` server-side.
  Future<void> cancelDeletion() async {
    final response = await _client.delete(Uri.parse('$apiBaseUrl/account/delete-request'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('DELETE /account/delete-request failed: ${response.statusCode} ${response.body}');
    }
  }
}
