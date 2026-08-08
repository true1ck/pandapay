import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// A8 Request Unsupported Card (also reachable from C8 — same screen, same
/// API client, per implementation-plan-group-c-d.md's note that A8 and C8
/// are identical, not a fork). Mirrors `ProfileApi`'s exact constructor/
/// method shape (auth_api.dart): `{required apiBaseUrl, required
/// accessToken}`, throws [ApiException] on non-201.
///
/// POST /card-requests already exists server-side (api/src/index.js) — this
/// is the first client to call it. `imagePath` is a pre-uploaded storage
/// path, never a raw file (see that route's own doc-comment); this pass has
/// no upload endpoint of its own, so [submit] is only ever called with a
/// null [imagePath] until one exists — flagged, not silently worked around.
class CardRequestsApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  CardRequestsApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  Future<void> submit({
    required String issuerName,
    required String productName,
    String? networkGuess,
    String? imagePath,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/card-requests'),
      headers: _headers,
      body: jsonEncode({
        'issuerName': issuerName,
        'productName': productName,
        'networkGuess': ?networkGuess,
        'imagePath': ?imagePath,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /card-requests failed: ${response.statusCode} ${response.body}');
    }
  }
}
