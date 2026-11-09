import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// A recovery email is a second address that can get a person back into the
/// account if they lose their sign-in email. Adding or changing one takes two
/// codes: one to the sign-in email, one to the new address. Talks to auth/
/// (`/users/me/recovery-email`).
class RecoveryEmailStatus {
  final bool hasRecoveryEmail;

  /// Masked, such as `b•••@outlook.com`, or null when there is none.
  final String? hint;

  const RecoveryEmailStatus({required this.hasRecoveryEmail, this.hint});

  factory RecoveryEmailStatus.fromJson(Map<String, dynamic> json) =>
      RecoveryEmailStatus(
        hasRecoveryEmail: json['has_recovery_email'] == true,
        hint: json['recovery_email_hint'] as String?,
      );
}

/// What step one returns: a signed token that ties the two codes to this person
/// and this device. It is opaque to the app and kept only in memory.
class RecoveryEmailChallenge {
  final String token;
  final String contactHint;
  final DateTime expiresAt;

  const RecoveryEmailChallenge({
    required this.token,
    required this.contactHint,
    required this.expiresAt,
  });
}

class RecoveryEmailApi {
  static const _timeout = Duration(seconds: 20);

  final String authBaseUrl;
  final String accessToken;
  final http.Client _client;
  final DateTime Function() _now;

  RecoveryEmailApi({
    required this.authBaseUrl,
    required this.accessToken,
    http.Client? client,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Uri _uri([String suffix = '']) =>
      Uri.parse('$authBaseUrl/users/me/recovery-email$suffix');

  Future<RecoveryEmailStatus> status() async {
    final response = await _client.get(_uri(), headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) throw _failure('GET', response);
    return RecoveryEmailStatus.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Step one. Sends a code to the sign-in email and a code to [email].
  Future<RecoveryEmailChallenge> requestChange(
    String email, {
    required String deviceId,
  }) async {
    final response = await _client
        .post(
          _uri('/request'),
          headers: _headers,
          body: jsonEncode({'email': email.trim(), 'device_id': deviceId}),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) throw _failure('POST', response, '/request');
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final token = body['challenge'];
      final hint = body['contact_hint'];
      final seconds = body['expires_in'];
      if (token is! String || token.isEmpty || hint is! String ||
          body['version'] != 2 || body['code_length'] != 6 ||
          seconds is! int || seconds < 1 || seconds > 120) {
        throw const FormatException();
      }
      return RecoveryEmailChallenge(
        token: token,
        contactHint: hint,
        expiresAt: _now().add(Duration(seconds: seconds)),
      );
    } catch (_) {
      throw ApiException(
        'Recovery email challenge unavailable',
        userMessage: 'Unable to send the codes. Please try again shortly.',
      );
    }
  }

  /// Step two. Both codes must be right; the recovery email is then active.
  /// Returns the masked address.
  Future<String?> confirm(
    RecoveryEmailChallenge challenge, {
    required String signInCode,
    required String recoveryCode,
    required String deviceId,
  }) async {
    if (!_now().isBefore(challenge.expiresAt)) {
      throw ApiException(
        'Recovery email challenge expired',
        userMessage: 'The codes have expired. Start again to get new ones.',
      );
    }
    final response = await _client
        .post(
          _uri('/verify'),
          headers: _headers,
          body: jsonEncode({
            'challenge': challenge.token,
            'signin_code': signInCode,
            'recovery_code': recoveryCode,
            'device_id': deviceId,
          }),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) throw _failure('POST', response, '/verify');
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['recovery_email_hint'] as String?;
  }

  Future<void> remove() async {
    final response = await _client.delete(_uri(), headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) throw _failure('DELETE', response);
  }

  ApiException _failure(String method, http.Response response, [String suffix = '']) {
    String? message;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['message'] is String) {
        message = (decoded['message'] as String).trim();
      }
    } catch (_) {
      // Not JSON: use the generic wording.
    }
    return ApiException(
      '$method /users/me/recovery-email$suffix failed: ${response.statusCode} ${response.body}',
      userMessage: message == null || message.isEmpty ? null : message,
    );
  }
}
