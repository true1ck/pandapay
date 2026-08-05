import 'dart:convert';
import 'package:http/http.dart' as http;

/// Talks to auth/ (OTP + JWT) and api/'s /admin/* surface. AD-0.3.1: no
/// signup path — this only ever calls the OTP login flow, same as the user
/// app; whether the resulting account is actually an operator is entirely
/// determined server-side by api/'s requireAdmin (pandapay.is_admin()), not
/// by anything client-side.
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
      throw AdminApiException('OTP request failed: ${response.statusCode} ${response.body}');
    }
  }

  /// Returns both tokens — AD-0.3's session needs the refresh token too, to
  /// survive a page reload without asking for OTP again (Chunk 10).
  Future<AuthTokens> verifyOtp(String phoneNumber, String code, String deviceId) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/verify-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber, 'code': code, 'device_id': deviceId}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('OTP verify failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String?,
    );
  }

  /// Exchanges a stored refresh token for a fresh access token on startup —
  /// the real auth/'s POST /auth/refresh, not a stub. A 401 here means the
  /// refresh token is invalid/expired/reused; callers should treat that as
  /// signed-out, not retry.
  Future<AuthTokens> refresh(String refreshToken) async {
    final response = await _client.post(
      Uri.parse('$authBaseUrl/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('Refresh failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AuthTokens(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String? ?? refreshToken,
    );
  }
}

class AuthTokens {
  final String accessToken;
  final String? refreshToken;
  const AuthTokens({required this.accessToken, this.refreshToken});
}

class AdminApi {
  final String apiBaseUrl;
  final String accessToken;
  final http.Client _client;

  AdminApi({required this.apiBaseUrl, required this.accessToken, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  Future<bool> isAdmin() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/me'), headers: _headers);
    if (response.statusCode != 200) return false;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['isAdmin'] as bool? ?? false;
  }

  Future<List<Map<String, dynamic>>> fetchAdminCards() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/cards'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/cards failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['cards'] as List).cast<Map<String, dynamic>>();
  }

  /// AD-1.1.3 typed writer, client side: only ever sends `rate` (+ optional
  /// audit reason), never a raw JSON blob of the whole rule.
  Future<void> updateRewardRuleRate(String ruleId, double rate, {String? reason}) async {
    final response = await _client.put(
      Uri.parse('$apiBaseUrl/admin/reward-rules/$ruleId'),
      headers: _headers,
      body: jsonEncode({'rate': rate, 'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('PUT /admin/reward-rules/$ruleId failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-2.1: card requests grouped by issuer+product with counts.
  Future<List<Map<String, dynamic>>> fetchCardRequestGroups() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/card-requests'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/card-requests failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['requestGroups'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> startScrapingSource({
    required String issuerName,
    String? productName,
    required String baseUrl,
  }) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/card-requests/start-scraping'),
      headers: _headers,
      body: jsonEncode({'issuerName': issuerName, 'productName': ?productName, 'baseUrl': baseUrl}),
    );
    if (response.statusCode != 201) {
      throw AdminApiException('POST start-scraping failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-2.2: data error reports, shown vs claimed against the live value.
  Future<List<Map<String, dynamic>>> fetchErrorReports() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/error-reports'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/error-reports failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['errorReports'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> approveErrorReport(String reportId) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/error-reports/$reportId/approve'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw AdminApiException('approve failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<void> rejectErrorReport(String reportId, {String? reason}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/error-reports/$reportId/reject'),
      headers: _headers,
      body: jsonEncode({'reason': ?reason}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('reject failed: ${response.statusCode} ${response.body}');
    }
  }

  /// AD-4.2/AD-5: the unified policy-change alert queue.
  Future<List<Map<String, dynamic>>> fetchAlerts() async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/alerts'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/alerts failed: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['alerts'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> fetchAlertDetail(String alertId) async {
    final response = await _client.get(Uri.parse('$apiBaseUrl/admin/alerts/$alertId'), headers: _headers);
    if (response.statusCode != 200) {
      throw AdminApiException('GET /admin/alerts/$alertId failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> decideAlert(String alertId, String decision, {String? note}) async {
    final response = await _client.post(
      Uri.parse('$apiBaseUrl/admin/alerts/$alertId/decide'),
      headers: _headers,
      body: jsonEncode({'decision': decision, 'note': ?note}),
    );
    if (response.statusCode != 200) {
      throw AdminApiException('decide failed: ${response.statusCode} ${response.body}');
    }
  }
}

class AdminApiException implements Exception {
  final String message;
  AdminApiException(this.message);
  @override
  String toString() => message;
}
