import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// H9 Feedback & Support. Mirrors [ProfileApi]'s method shape (see auth_api.dart)
/// without embedding a Riverpod dependency, so the client stays testable.
///
/// Talks to `POST /support-tickets` (optional auth; signed-out submissions are
/// supported for OTP help). Success returns `{ticket: {id, kind, state,
/// created_at}}`; request text is bounded by the API.
class SupportApi {
  final String apiBaseUrl;
  final String? accessToken;
  final http.Client _client;

  SupportApi({required this.apiBaseUrl, this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  /// [kind] must be one of 'bug' | 'wrong_card_data' | 'card_request' |
  /// 'general' — the same four values the backend's `SUPPORT_TICKET_KINDS`
  /// enforces. [diagnostics] is sent verbatim as the ticket's jsonb
  /// `diagnostics` column; callers should pass exactly what they showed the
  /// user in the "what we'll send" preview, never a superset of it. The API
  /// accepts only bounded, flat scalar diagnostics.
  Future<void> submitTicket({
    required String kind,
    required String message,
    Map<String, dynamic>? diagnostics,
    String? appVersion,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/support-tickets'),
      headers: _headers,
      body: jsonEncode({
        'kind': kind,
        'message': message,
        'diagnostics': ?diagnostics,
        'appVersion': ?appVersion,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /support-tickets failed: ${response.statusCode} ${response.body}',
      );
    }
  }
}
