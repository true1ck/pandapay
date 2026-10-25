import 'dart:convert';
import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'recovery_api.dart';

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

/// The challenge stays in memory for one request on one installation. A lost
/// challenge is retried after expiry; the client never downgrades a v2 code.
class OtpChallenge {
  final String id;
  final String deviceId;
  final String identifier;
  final bool email;
  final bool recoveryOnly;
  final DateTime expiresAt;
  const OtpChallenge._({
    required this.id,
    required this.deviceId,
    required this.identifier,
    required this.email,
    required this.recoveryOnly,
    required this.expiresAt,
  });
}

class AuthApi {
  // Auth is used during cold start. A network that is offline or a hosted
  // service that is slow must never hold the app's first frame indefinitely.
  static const _requestTimeout = Duration(seconds: 8);

  final String authBaseUrl;
  final http.Client _client;
  final bool versionedOtpEnabled;
  final DateTime Function() _now;
  int get otpCodeLength => versionedOtpEnabled ? 6 : 4;
  AuthApi({
    required this.authBaseUrl,
    http.Client? client,
    this.versionedOtpEnabled = false,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  String _otpPath(String name) =>
      '$authBaseUrl/auth/${versionedOtpEnabled ? 'v2/' : ''}$name';
  String _contact(String value, bool email) =>
      email ? value.trim().toLowerCase() : value.trim();
  String _requestDevice(String? id) {
    if (id == null || !RegExp(r'^[A-Za-z0-9:_-]{4,128}$').hasMatch(id)) {
      throw StateError('Please try requesting a new sign-in code.');
    }
    return id;
  }

  OtpChallenge? _challenge(
    http.Response response,
    String identifier,
    bool email,
    bool recoveryOnly,
    String? deviceId,
  ) {
    if (!versionedOtpEnabled) return null;
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final id = body['challenge_id'];
      final seconds = body['expires_in'];
      if (body['ok'] != true ||
          body['version'] != 2 ||
          body['code_length'] != 6 ||
          id is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            caseSensitive: false,
          ).hasMatch(id) ||
          seconds is! int ||
          seconds < 1 ||
          seconds > 120) {
        throw const FormatException();
      }
      return OtpChallenge._(
        id: id,
        deviceId: _requestDevice(deviceId),
        identifier: _contact(identifier, email),
        email: email,
        recoveryOnly: recoveryOnly,
        expiresAt: _now().add(Duration(seconds: seconds)),
      );
    } catch (_) {
      throw ApiException(
        'OTP challenge unavailable',
        userMessage: 'Unable to start sign-in. Please try again shortly.',
      );
    }
  }

  Map<String, Object?> _challengeFields(
    OtpChallenge? challenge,
    String identifier,
    String code,
    String deviceId,
    bool email,
    bool recoveryOnly,
  ) {
    if (!versionedOtpEnabled) {
      if (challenge != null) {
        throw StateError('Please request a new sign-in code.');
      }
      return const {};
    }
    if (challenge == null ||
        challenge.email != email ||
        challenge.identifier != _contact(identifier, email) ||
        challenge.deviceId != deviceId ||
        challenge.recoveryOnly != recoveryOnly ||
        !_now().isBefore(challenge.expiresAt) ||
        !RegExp(r'^\d{6}$').hasMatch(code)) {
      throw StateError('Please request a new sign-in code for this device.');
    }
    return {'challenge_id': challenge.id};
  }

  RecoveryApi recoveryApiFor(String accessToken) => RecoveryApi(
    authBaseUrl: authBaseUrl,
    accessToken: accessToken,
    client: _client,
    versionedOtpEnabled: versionedOtpEnabled,
  );

  Future<OtpChallenge?> requestOtp(
    String phoneNumber, {
    bool recoveryOnly = false,
    String? deviceId,
  }) async {
    final response = await _client
        .post(
          Uri.parse(_otpPath('request-otp')),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone_number': phoneNumber,
            if (versionedOtpEnabled) 'device_id': _requestDevice(deviceId),
            if (recoveryOnly) 'recovery_only': true,
          }),
        )
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'OTP request failed: ${response.statusCode} ${response.body}',
      );
    }
    return _challenge(response, phoneNumber, false, recoveryOnly, deviceId);
  }

  Future<AuthTokens> verifyOtp(
    String phoneNumber,
    String code,
    String deviceId, {
    bool recoveryOnly = false,
    Map<String, Object?>? deviceInfo,
    OtpChallenge? challenge,
  }) async {
    final response = await _client
        .post(
          Uri.parse(_otpPath('verify-otp')),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone_number': phoneNumber,
            'code': code,
            'device_id': deviceId,
            ..._challengeFields(
              challenge,
              phoneNumber,
              code,
              deviceId,
              false,
              recoveryOnly,
            ),
            'device_info': ?deviceInfo,
            if (recoveryOnly) 'recovery_only': true,
          }),
        )
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'OTP verify failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String?,
    );
  }

  Future<AuthTokens> refresh(String refreshToken, {String? requestId}) async {
    final response = await _client
        .post(
          Uri.parse('$authBaseUrl/auth/refresh'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'refresh_token': refreshToken,
            'refresh_request_id': ?requestId,
          }),
        )
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'Refresh failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String? ?? refreshToken,
    );
  }

  /// Existing email OTP. Legacy requests retain their supported request
  /// fields. V2 requests send only email/device; a phone claim cannot select
  /// an identity or prove phone ownership. There is no automatic downgrade.
  Future<OtpChallenge?> requestEmailOtp(
    String email, {
    bool isSignUp = false,
    String? phoneNumber,
    bool recoveryOnly = false,
    String? deviceId,
  }) async {
    final response = await _client
        .post(
          Uri.parse(_otpPath('request-email-otp')),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': email,
            if (versionedOtpEnabled) 'device_id': _requestDevice(deviceId),
            if (!versionedOtpEnabled && isSignUp) 'is_signup': true,
            if (recoveryOnly) 'recovery_only': true,
            if (!versionedOtpEnabled &&
                phoneNumber != null &&
                phoneNumber.trim().isNotEmpty)
              'phone_number': phoneNumber.trim(),
          }),
        )
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'OTP request failed: ${response.statusCode} ${response.body}',
      );
    }
    return _challenge(response, email, true, recoveryOnly, deviceId);
  }

  /// V2 requires the original challenge, device and email. [phoneNumber]
  /// remains a legacy compatibility field; the server separately verifies
  /// factor ownership before linking contacts to the email-proved identity.
  Future<AuthTokens> verifyEmailOtp(
    String email,
    String code,
    String deviceId, {
    String? phoneNumber,
    bool recoveryOnly = false,
    Map<String, Object?>? deviceInfo,
    OtpChallenge? challenge,
  }) async {
    final trimmedPhone = phoneNumber?.trim();
    final response = await _client
        .post(
          Uri.parse(_otpPath('verify-email-otp')),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': email,
            'code': code,
            'device_id': deviceId,
            ..._challengeFields(
              challenge,
              email,
              code,
              deviceId,
              true,
              recoveryOnly,
            ),
            'device_info': ?deviceInfo,
            if (!versionedOtpEnabled &&
                trimmedPhone != null &&
                trimmedPhone.isNotEmpty)
              'phone_number': trimmedPhone,
            if (recoveryOnly) 'recovery_only': true,
          }),
        )
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'OTP verify failed: ${response.statusCode} ${response.body}',
      );
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
  ProfileApi({
    required this.apiBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>?> fetchProfile() async {
    final response = await _client.get(
      Uri.parse('$apiBaseUrl/profile'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /profile failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['profile'] as Map<String, dynamic>?;
  }

  /// Idempotent — api/'s POST /profile is an upsert (ON CONFLICT DO UPDATE),
  /// so calling this on every login is the correct "ensure my profile row
  /// exists" pattern, not a bug waiting to duplicate anything.
  /// [email]/[phoneNumber] are the values just verified/collected at
  /// sign-in. api/ COALESCEs them, so passing null means "nothing new to
  /// say" rather than "clear it" — a later sign-in that doesn't resend the
  /// phone won't wipe it.
  Future<Map<String, dynamic>> ensureProfile({
    String? displayName,
    String? email,
    String? phoneNumber,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/profile'),
      headers: _headers,
      body: jsonEncode({
        'displayName': displayName,
        'email': email,
        'phoneNumber': phoneNumber,
      }),
    );
    if (response.statusCode != 201) {
      throw ApiException(
        'POST /profile failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['profile'] as Map<String, dynamic>;
  }
}
