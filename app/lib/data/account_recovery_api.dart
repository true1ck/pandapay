import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'auth_api.dart';

/// "Can't sign in?" Talks to auth/ (`/auth/recovery/*`) with no session, because the
/// person has none. Every step carries the attempt id and this install's device id;
/// the server only honours an attempt from the install that started it.
///
/// The server answers a first step the same way whether or not the details matched,
/// so nothing here can tell the person (or anyone watching) which part was wrong.
class RecoveryStartResult {
  final String attemptId;
  final int codeLength;
  final Duration codeLifetime;

  const RecoveryStartResult({
    required this.attemptId,
    required this.codeLength,
    required this.codeLifetime,
  });
}

/// What the last step returns: either a signed-in session, or a waiting recovery
/// with the token needed to finish it once the hold is over.
class RecoveryOutcome {
  final bool pending;
  final DateTime? holdUntil;
  final String? resumeToken;
  final AuthTokens? tokens;
  final String? newEmailHint;

  const RecoveryOutcome._({
    required this.pending,
    this.holdUntil,
    this.resumeToken,
    this.tokens,
    this.newEmailHint,
  });

  factory RecoveryOutcome.fromJson(Map<String, dynamic> json) {
    if (json['pending'] == true) {
      final until = DateTime.tryParse('${json['hold_until']}');
      final token = json['resume_token'];
      if (until == null || token is! String || token.isEmpty) {
        throw const FormatException('hold reply incomplete');
      }
      return RecoveryOutcome._(
        pending: true,
        holdUntil: until.toLocal(),
        resumeToken: token,
      );
    }
    final access = json['access_token'];
    if (access is! String || access.isEmpty) {
      throw const FormatException('session reply incomplete');
    }
    final refresh = json['refresh_token'];
    return RecoveryOutcome._(
      pending: false,
      tokens: AuthTokens(
        accessToken: access,
        refreshToken: refresh is String ? refresh : null,
      ),
      newEmailHint: json['new_email_hint'] as String?,
    );
  }
}

/// A refusal from the recovery routes, with the server's code so a screen can tell
/// a wrong code (try again) from a closed attempt (start over).
class RecoveryFailure extends ApiException {
  final String code;
  final int status;
  final DateTime? holdUntil;

  RecoveryFailure(
    super.debugMessage, {
    required this.code,
    required this.status,
    super.userMessage,
    this.holdUntil,
  });

  /// The attempt is gone or never matched: the person has to start again.
  bool get startOver => code == 'recovery_failed';

  /// A wrong or expired code: the same step can be tried again.
  bool get retryable => code == 'code_invalid';
}

class AccountRecoveryApi {
  static const _timeout = Duration(seconds: 20);

  final String authBaseUrl;
  final http.Client _client;

  AccountRecoveryApi({required this.authBaseUrl, http.Client? client})
    : _client = client ?? http.Client();

  Future<RecoveryStartResult> start({
    required String lostEmail,
    required String phone,
    required String fact,
    required String deviceId,
  }) async {
    final body = await _post('/start', {
      'lost_email': lostEmail.trim(),
      'phone': phone.trim(),
      'fact': fact.trim(),
      'device_id': deviceId,
    });
    final id = body['attempt_id'];
    final length = body['code_length'];
    final seconds = body['expires_in'];
    if (id is! String ||
        id.isEmpty ||
        length is! int ||
        length < 4 ||
        length > 8 ||
        seconds is! int ||
        seconds < 1 ||
        seconds > 600) {
      throw ApiException(
        'Recovery start reply malformed',
        userMessage: 'Something went wrong. Please try again shortly.',
      );
    }
    return RecoveryStartResult(
      attemptId: id,
      codeLength: length,
      codeLifetime: Duration(seconds: seconds),
    );
  }

  Future<void> verifyCode({
    required String attemptId,
    required String code,
    required String deviceId,
  }) async {
    await _post('/verify-code', {
      'attempt_id': attemptId,
      'code': code,
      'device_id': deviceId,
    });
  }

  /// "I don't have a recovery email." Moves to the slower path.
  Future<void> noRecoveryEmail({
    required String attemptId,
    required String deviceId,
  }) async {
    await _post('/no-recovery-email', {
      'attempt_id': attemptId,
      'device_id': deviceId,
    });
  }

  /// Chooses the new sign-in email. Returns whether a code was sent to it (false
  /// when the recovery email itself becomes the sign-in email).
  Future<({bool needsCode, String? hint})> setNewEmail({
    required String attemptId,
    required String deviceId,
    String? newEmail,
    bool useRecoveryEmail = false,
  }) async {
    final body = await _post('/new-email', {
      'attempt_id': attemptId,
      'device_id': deviceId,
      'new_email': ?newEmail?.trim(),
      if (useRecoveryEmail) 'use_recovery_email': true,
    });
    return (
      needsCode: body['needs_code'] == true,
      hint: body['new_email_hint'] as String?,
    );
  }

  Future<RecoveryOutcome> complete({
    required String attemptId,
    required String deviceId,
    String? code,
  }) async {
    final body = await _post('/complete', {
      'attempt_id': attemptId,
      'device_id': deviceId,
      'code': ?code,
    });
    return _outcome(body);
  }

  /// After the 24-hour hold. Fails with `hold_not_over` (and its end time) if early.
  Future<RecoveryOutcome> finish({
    required String attemptId,
    required String deviceId,
    required String resumeToken,
  }) async {
    final body = await _post('/finish', {
      'attempt_id': attemptId,
      'device_id': deviceId,
      'resume_token': resumeToken,
    });
    return _outcome(body);
  }

  RecoveryOutcome _outcome(Map<String, dynamic> body) {
    try {
      return RecoveryOutcome.fromJson(body);
    } on FormatException {
      throw ApiException(
        'Recovery reply malformed',
        userMessage: 'Something went wrong. Please try again shortly.',
      );
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> payload,
  ) async {
    final response = await _client
        .post(
          Uri.parse('$authBaseUrl/auth/recovery$path'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(_timeout);
    Map<String, dynamic> decoded = const {};
    try {
      final value = jsonDecode(response.body);
      if (value is Map<String, dynamic>) decoded = value;
    } catch (_) {
      // Not JSON: the generic wording below.
    }
    if (response.statusCode != 200) {
      final message = decoded['message'];
      final until = DateTime.tryParse('${decoded['hold_until']}');
      throw RecoveryFailure(
        'POST /auth/recovery$path failed: ${response.statusCode}',
        code: decoded['error'] is String
            ? decoded['error'] as String
            : 'unknown',
        status: response.statusCode,
        userMessage: message is String && message.trim().isNotEmpty
            ? message.trim()
            : null,
        holdUntil: until?.toLocal(),
      );
    }
    return decoded;
  }
}

/// From a signed-in device: is a recovery waiting on this account, and cancel it.
class RecoveryPending {
  final bool pending;
  final DateTime? holdUntil;
  const RecoveryPending({required this.pending, this.holdUntil});
}

class RecoveryPendingApi {
  static const _timeout = Duration(seconds: 20);

  final String authBaseUrl;
  final String accessToken;
  final http.Client _client;

  RecoveryPendingApi({
    required this.authBaseUrl,
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $accessToken',
    'Content-Type': 'application/json',
  };

  Future<RecoveryPending> status() async {
    final response = await _client
        .get(
          Uri.parse('$authBaseUrl/users/me/recovery-pending'),
          headers: _headers,
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw ApiException(
        'GET /users/me/recovery-pending failed: ${response.statusCode}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return RecoveryPending(
      pending: body['pending'] == true,
      holdUntil: DateTime.tryParse('${body['hold_until']}')?.toLocal(),
    );
  }

  Future<void> cancel() async {
    final response = await _client
        .post(
          Uri.parse('$authBaseUrl/users/me/recovery-pending/cancel'),
          headers: _headers,
          body: '{}',
        )
        .timeout(_timeout);
    // 404 means there was nothing left to cancel, which is the state the person wanted.
    if (response.statusCode != 200 && response.statusCode != 404) {
      throw ApiException(
        'POST /users/me/recovery-pending/cancel failed: ${response.statusCode}',
      );
    }
  }
}
