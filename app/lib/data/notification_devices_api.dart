import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Registers a mobile FCM token through PandaPay's authenticated API.
///
/// The notification-service project key is intentionally not present here:
/// shipping it in an APK/IPA would allow anyone to send notifications to
/// every PandaPay subscriber in that environment.
class NotificationDevicesApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  NotificationDevicesApi({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Future<void> register({
    required String token,
    required String platform,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/notification-devices'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'token': token, 'platform': platform}),
    );
    if (response.statusCode != 201 && response.statusCode != 202) {
      throw ApiException(
        'POST /notification-devices failed: ${response.statusCode} ${response.body}',
      );
    }

    // A 202 is intentionally used by the API when the optional external
    // notification service is not configured. That response is not a
    // registration success, so do not silently swallow it on the device.
    // The caller can retry after connectivity/service configuration returns.
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['registered'] == false) {
        throw ApiException(
          'POST /notification-devices was accepted but not registered: ${response.body}',
        );
      }
    } on ApiException {
      rethrow;
    } on FormatException {
      // Keep compatibility with older API deployments that returned an empty
      // 201/202 body after a successful registration.
    }
  }
}
