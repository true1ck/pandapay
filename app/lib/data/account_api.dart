import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Client for account reset and erasure endpoints across API and auth.
/// Mirrors `ProfileApi`'s exact constructor/method shape (auth_api.dart) so
/// this reads as the same family of API client, not a new pattern.
///
/// The legacy request/cancel methods remain for users with an older pending
/// deletion request. New deletion requests erase the product and auth records.
class AccountApi {
  final String apiBaseUrl;
  final String authBaseUrl;
  final String accessToken;
  final http.Client _client;

  AccountApi({required this.apiBaseUrl, required this.authBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  /// Erases account-owned product rows while retaining the login identity.
  Future<void> resetUserData() async {
    final authorization = await _client.post(
      Uri.parse('$authBaseUrl/users/me/deletion-check'),
      headers: _headers,
    );
    if (authorization.statusCode != 200) {
      throw ApiException(
        'POST /users/me/deletion-check failed: ${authorization.statusCode} ${authorization.body}',
      );
    }
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/account/data-reset'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'POST /account/data-reset failed: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Erases product records first, then removes the auth identity. If auth
  /// deletion fails, the server-side product purge is safe to retry.
  Future<void> deleteAccountPermanently() async {
    final preflight = await _client.post(
      Uri.parse('$authBaseUrl/users/me/deletion-check'),
      headers: _headers,
    );
    if (preflight.statusCode != 200) {
      throw ApiException(
        'POST /users/me/deletion-check failed: ${preflight.statusCode} ${preflight.body}',
      );
    }
    final erase = await _client.post(
      Uri.parse('$apiBaseUrl/account/erase'),
      headers: _headers,
    );
    if (erase.statusCode != 200) {
      throw ApiException(
        'POST /account/erase failed: ${erase.statusCode} ${erase.body}',
      );
    }
    final deletion = await _client.delete(
      Uri.parse('$authBaseUrl/users/me'),
      headers: _headers,
    );
    if (deletion.statusCode != 200) {
      throw ApiException(
        'DELETE /users/me failed: ${deletion.statusCode} ${deletion.body}',
      );
    }
  }

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
