import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Plan Phase 2.3 — the "Apply for this card" outbound link.
///
/// The client never holds the destination URL. It asks the server for one at
/// tap time, and the server records the click in the same transaction that
/// builds the URL (`pandapay.record_partner_click()`, migration 0030). That
/// ordering is the whole point: a URL cached in the app or shipped in the
/// catalogue could be opened without a click ever being recorded, which is
/// both a lost attribution and — worse — a number the business would then
/// quietly believe was complete.
class PartnerApplyRepository {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  PartnerApplyRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Returns the URL to hand to the OS browser, or null when the catalogue
  /// has no application link for this card.
  ///
  /// Null rather than an exception for the 404: "this card has no apply link"
  /// is an ordinary catalogue state, not a failure, and the caller's response
  /// to it is to say so plainly rather than to show an error.
  Future<String?> beginApply({required String cardProductId, String? placement}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/partner-clicks'),
      headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'cardProductId': cardProductId, 'placement': ?placement}),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 201) {
      throw ApiException('POST /partner-clicks failed: ${response.statusCode} ${response.body}');
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['url'] as String?;
  }
}
