import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// H9 Feedback & Support. Mirrors [ProfileApi]'s constructor/method shape
/// (see auth_api.dart) — plain `{required apiBaseUrl, required accessToken}`
/// client, one method per backend call, no Riverpod dependency baked in so
/// it stays trivially testable/mockable.
///
/// Talks to `POST /support-tickets` (requireAuth) — verified live against
/// the running api/ during this task: 201 on success with
/// `{ticket: {id, kind, state, created_at}}`, 400 on an invalid `kind` or an
/// empty/whitespace-only `message`.
class SupportApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  SupportApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  /// [kind] must be one of 'bug' | 'wrong_card_data' | 'card_request' |
  /// 'general' — the same four values the backend's `SUPPORT_TICKET_KINDS`
  /// enforces. [diagnostics] is sent verbatim as the ticket's jsonb
  /// `diagnostics` column; callers should pass exactly what they showed the
  /// user in the "what we'll send" preview, never a superset of it.
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
        if (diagnostics != null) 'diagnostics': diagnostics,
        if (appVersion != null) 'appVersion': appVersion,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /support-tickets failed: ${response.statusCode} ${response.body}');
    }
  }
}
