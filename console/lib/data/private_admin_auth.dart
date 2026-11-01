import 'dart:convert';
import 'package:http/http.dart' as http;
import 'admin_api.dart';
import 'admin_passkey.dart';

typedef AdminPasskey =
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> options, {
      required bool register,
    });

/// Privileged browser flow. No bearer token is returned to Dart or persisted.
class PrivateAdminAuthApi extends AuthApi {
  final http.Client _http;
  final AdminPasskey _passkey;
  String? _loginId, _csrfToken, _email;
  bool enrollmentRequired = false;
  bool approvedBrowserEnrollment = false;
  Set<String> _enrolledFactorSlots = {};
  bool get primaryKeyRegistered => _enrolledFactorSlots.contains('primary');
  bool get backupKeyRegistered => _enrolledFactorSlots.contains('backup');
  bool get awaitingActivation => primaryKeyRegistered && backupKeyRegistered;
  Set<String> _factorSlots(Object? value) => value is List
      ? value
            .whereType<String>()
            .where((slot) => slot == 'primary' || slot == 'backup')
            .toSet()
      : {};
  Map<String, dynamic>? administrator;
  PrivateAdminAuthApi({http.Client? client, AdminPasskey? passkey})
    : _http = client ?? http.Client(),
      _passkey = passkey ?? useAdminPasskey,
      super(authBaseUrl: '', browserSessions: true);
  @override
  int get otpCodeLength => 6;
  @override
  String? get browserCsrf => _csrfToken;

  Map<String, String> get _privateHeaders => {
    'Content-Type': 'application/json',
    'X-Console-Request': '1',
    'X-Admin-Protocol': '1',
    'X-CSRF-Token': ?_csrfToken,
  };

  /// The provisioning CLI issues 32 random bytes encoded as unpadded base64url.
  static String? validateEnrollmentGrant(String? value) {
    final grant = value?.trim() ?? '';
    if (grant.isEmpty) {
      return 'Enter the enrollment grant provided for your account.';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(grant)) {
      return 'Paste the full 43-character enrollment grant, not your email code.';
    }
    return null;
  }

  String _failureMessage(String path, http.Response response) {
    // Use only known protocol codes; never display server bodies or credentials.
    String? code;
    try {
      final data = jsonDecode(response.body);
      if (data is Map && data['version'] == 1 && data['error'] is String) {
        code = data['error'] as String;
      }
    } on FormatException {
      // A proxy can return HTML instead of a gateway error envelope.
    }
    if (response.statusCode == 429) {
      return 'Too many attempts. Please wait and retry.';
    }
    if (code == 'preauth_required') {
      return 'This sign-in attempt is no longer valid. Start again to request a new email code.';
    }
    if (path == 'enrollment/options' && code == 'enrollment_denied') {
      return 'Enrollment was not authorized. Your grant or email verification may have expired. Start again with a fresh grant and email code.';
    }
    if (code == 'enrollment_not_approved') {
      return 'Passkey setup is not approved for this sign-in, or your email verification expired. Request a new email code. If it continues, contact your administrator.';
    }
    if (path == 'enrollment/verify' &&
        (response.statusCode == 401 || response.statusCode == 403)) {
      return 'Security-key registration could not be verified. Start again with a fresh grant and email code.';
    }
    if (path == 'login/verify-email' && code == 'invalid_credentials') {
      return 'The email code is incorrect or has expired. Start again to request a new code.';
    }
    if (response.statusCode == 503) {
      return 'The admin service is temporarily unavailable. Please retry.';
    }
    return response.statusCode == 401
        ? 'Your admin session expired. Sign in again.'
        : 'Admin request could not be completed.';
  }

  Future<Map<String, dynamic>> _call(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse('/browser/$path');
    final response =
        await (body == null
                ? _http.get(uri, headers: _privateHeaders)
                : _http.post(
                    uri,
                    headers: _privateHeaders,
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AdminApiException(
        _failureMessage(path, response),
        statusCode: response.statusCode,
      );
    }
    final data = (jsonDecode(response.body) as Map).cast<String, dynamic>();
    if (!path.startsWith('api/') && data['version'] != 1) {
      throw AdminApiException('Install the matching admin console version.');
    }
    return data;
  }

  AuthTokens _acceptSession(Map<String, dynamic> data) {
    if (data['authenticated'] != true ||
        data['csrfToken'] is! String ||
        data['admin'] is! Map) {
      throw AdminApiException('Admin authentication is incomplete.');
    }
    _csrfToken = data['csrfToken'] as String;
    administrator = (data['admin'] as Map).cast<String, dynamic>();
    _loginId = null;
    enrollmentRequired = false;
    return const AuthTokens(accessToken: 'console-browser-session');
  }

  @override
  Future<ConsoleOtpChallenge?> requestEmailOtp(
    String email, {
    String? deviceId,
  }) async {
    _loginId = null;
    enrollmentRequired = false;
    _enrolledFactorSlots = {};
    approvedBrowserEnrollment = false;
    _email = email.trim().toLowerCase();
    final data = await _call('login/start', {'email': _email});
    if (data['loginId'] is! String) {
      throw AdminApiException('Unable to start admin sign-in.');
    }
    _loginId = data['loginId'] as String;
    return null;
  }

  @override
  Future<ConsoleOtpChallenge?> requestOtp(
    String phoneNumber, {
    String? deviceId,
  }) async => throw AdminApiException(
    'The private console uses a verified admin email.',
  );
  @override
  Future<AuthTokens> verifyEmailOtp(
    String email,
    String code,
    String deviceId, {
    ConsoleOtpChallenge? challenge,
  }) async {
    if (_loginId == null ||
        email.trim().toLowerCase() != _email ||
        !RegExp(r'^\d{6}$').hasMatch(code)) {
      throw AdminApiException('Request a new six-digit admin sign-in code.');
    }
    final data = await _call('login/verify-email', {
      'loginId': _loginId,
      'code': code,
    });
    if (data['next'] == 'enrollment') {
      approvedBrowserEnrollment = data['enrollmentMode'] == 'approved';
      _enrolledFactorSlots = _factorSlots(data['enrolledSlots']);
      enrollmentRequired = true;
      throw AdminApiException(
        'A one-use enrollment grant is required to register your security key.',
      );
    }
    if (data['next'] != 'webauthn' || data['options'] is! Map) {
      throw AdminApiException('Passkey verification unavailable.');
    }
    final credential = await _passkey(
      (data['options'] as Map).cast<String, dynamic>(),
      register: false,
    );
    return _acceptSession(
      await _call('login/verify-passkey', {
        'loginId': _loginId,
        'credential': credential,
      }),
    );
  }

  Future<void> enroll([String grant = '']) async {
    if (!enrollmentRequired || _loginId == null) {
      throw AdminApiException('Verify your admin email first.');
    }
    if (awaitingActivation) {
      throw AdminApiException(
        'Both security keys are registered. Activate your account through the setup helper before signing in.',
      );
    }
    final registeringSlot = primaryKeyRegistered ? 'backup' : 'primary';
    final validationError = approvedBrowserEnrollment
        ? null
        : validateEnrollmentGrant(grant);
    if (validationError != null) throw AdminApiException(validationError);
    final data = await _call('enrollment/options', {
      'loginId': _loginId,
      if (approvedBrowserEnrollment)
        'mode': 'approved'
      else
        'grant': grant.trim(),
    });
    if (data['options'] is! Map) {
      throw AdminApiException(
        'Security-key registration is unavailable. Please retry.',
      );
    }
    final Map<String, dynamic> credential;
    try {
      credential = await _passkey(
        (data['options'] as Map).cast<String, dynamic>(),
        register: true,
      );
    } catch (_) {
      throw AdminApiException(
        'Passkey registration was cancelled or unavailable. Retry in Chrome and complete its security prompt.',
      );
    }
    final result = await _call('enrollment/verify', {
      'loginId': _loginId,
      'credential': credential,
    });
    if (result['enrolled'] != true) {
      throw AdminApiException(
        'Security-key registration was not confirmed. Please retry.',
      );
    }
    _enrolledFactorSlots = result['enrolledSlots'] is List
        ? _factorSlots(result['enrolledSlots'])
        : {..._enrolledFactorSlots, registeringSlot};
    _loginId = null;
    enrollmentRequired = false;
  }

  Future<void> stepUp() async {
    final data = await _call('step-up/options', {});
    final credential = await _passkey(
      (data['options'] as Map).cast<String, dynamic>(),
      register: false,
    );
    await _call('step-up/verify', {'credential': credential});
  }

  @override
  Future<AuthTokens> refresh(String refreshToken) async =>
      _acceptSession(await _call('session'));
  @override
  Future<void> logout() async {
    try {
      await _call('logout', {});
    } on AdminApiException catch (e) {
      if (e.statusCode != 401) rethrow;
    }
    _csrfToken = null;
    administrator = null;
  }

  @override
  Future<List<Map<String, dynamic>>> categories() async {
    final data = await _call('api/admin/reference/categories');
    return (data['categories'] as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }
}
