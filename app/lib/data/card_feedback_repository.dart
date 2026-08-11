import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Task C-0b/C7/C8: user-submitted card-catalogue feedback — "report wrong
/// data" (C7) and "request a new card" (C8, same flow as onboarding's A8).
/// Both `POST /card-requests` and `POST /data-error-reports` are pre-upload-
/// path routes: any photo/screenshot has to already be uploaded elsewhere
/// and its storage path passed in, since no upload infra exists yet in this
/// pass (flagged explicitly in both backend routes' own doc-comments, not
/// silently worked around here) — [imagePath]/[attachmentPath] are
/// therefore always null from this client today.
class CardFeedbackRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  CardFeedbackRepository({required this.apiBaseUrl, required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<void> requestNewCard({
    required String issuerName,
    required String productName,
    String? networkGuess,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/card-requests'),
      headers: _headers,
      body: jsonEncode({'issuerName': issuerName, 'productName': productName, 'networkGuess': ?networkGuess}),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /card-requests failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> reportWrongData({
    required String cardProductId,
    required String fieldPath,
    String? shownValue,
    String? claimedValue,
    String? sourceUrl,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/data-error-reports'),
      headers: _headers,
      body: jsonEncode({
        'cardProductId': cardProductId,
        'fieldPath': fieldPath,
        'shownValue': ?shownValue,
        'claimedValue': ?claimedValue,
        'sourceUrl': ?sourceUrl,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /data-error-reports failed: ${response.statusCode} ${response.body}');
    }
  }
}
