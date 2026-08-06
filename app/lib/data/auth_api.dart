import 'dart:convert';
import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// UA-3: the user app's own OTP login flow against auth/ — mirrors
/// console/lib/data/admin_api.dart's AuthApi/AuthTokens (same auth/
/// service, same OTP endpoints), kept as a separate class rather than a
/// shared package because the two apps' account models diverge (the
/// console never signs a user up for a profiles row; the app does, via
/// api/'s POST /profile below).
class AuthTokens {
  final String accessToken;
  final String? refreshToken;
  const AuthTokens({required this.accessToken, this.refreshToken});
}

class AuthApi {
  final String authBaseUrl;
  final http.Client _client;
  AuthApi({required this.authBaseUrl, http.Client? client}) : _client = client ?? http.Client();

  Future<void> requestOtp(String phoneNumber) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/request-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber}),
    );
    if (response.statusCode != 200) {
      throw ApiException('OTP request failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<AuthTokens> verifyOtp(String phoneNumber, String code, String deviceId) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/verify-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber, 'code': code, 'device_id': deviceId}),
    );
    if (response.statusCode != 200) {
      throw ApiException('OTP verify failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String?,
    );
  }

  Future<AuthTokens> refresh(String refreshToken) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );
    if (response.statusCode != 200) {
      throw ApiException('Refresh failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String? ?? refreshToken,
    );
  }

  /// Email-based sign-in against auth/'s /auth/request-email-otp and
  /// /auth/verify-email-otp — the same OTP machinery as phone (2-minute TTL,
  /// bcrypt-hashed, rate-limited), just a different identifier. phone_number
  /// is deliberately omitted from the request body: the backend treats it as
  /// an optional "link this email to an existing phone account" field, and
  /// this app only ever offers Phone or Email as alternatives, never both at
  /// once.
  Future<void> requestEmailOtp(String email) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/request-email-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    if (response.statusCode != 200) {
      throw ApiException('OTP request failed: ${response.statusCode} ${response.body}');
    }
  }

  /// [phoneNumber] is optional and only sent at SIGN-UP, where we collect both
  /// identifiers so the account has a phone on file for SMS-based transaction
  /// detection (UA-5.3) even though the OTP itself goes to the email. auth/'s
  /// verify-email-otp links the two onto one users row and rejects the case
  /// where they already belong to different accounts. The key is omitted
  /// entirely when absent — sending an explicit null would fail that route's
  /// validatePhone() check rather than being treated as "not provided".
  Future<AuthTokens> verifyEmailOtp(
    String email,
    String code,
    String deviceId, {
    String? phoneNumber,
  }) async {
    final trimmedPhone = phoneNumber?.trim();
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/verify-email-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'code': code,
        'device_id': deviceId,
        if (trimmedPhone != null && trimmedPhone.isNotEmpty)
          'phone_number': trimmedPhone,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException('OTP verify failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String?,
    );
  }
}

/// api/'s owner-scoped /profile — proves the RLS-backed profile row works
/// end to end from the app side (Chunk 1 built and proved the backend;
/// nothing on the app side ever called it until now).
class ProfileApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;
  ProfileApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  Future<Map<String, dynamic>?> fetchProfile() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/profile'), headers: _headers);
    if (response.statusCode != 200) {
      throw ApiException('GET /profile failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['profile'] as Map<String, dynamic>?;
  }

  /// Idempotent — api/'s POST /profile is an upsert (ON CONFLICT DO UPDATE),
  /// so calling this on every login is the correct "ensure my profile row
  /// exists" pattern, not a bug waiting to duplicate anything.
  Future<Map<String, dynamic>> ensureProfile({String? displayName}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/profile'),
      headers: _headers,
      body: jsonEncode({'displayName': displayName}),
    );
    if (response.statusCode != 201) {
      throw ApiException('POST /profile failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['profile'] as Map<String, dynamic>;
  }
}
