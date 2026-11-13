import 'dart:async';
import 'dart:convert';
import 'api_exception.dart';
import 'portable_backup/account_recovery_operation_gate.dart';

import 'package:http/http.dart' as http;

/// Deadlines applied by [AuthenticatedHttpClient] to one request.
///
/// [header] bounds waiting for response headers. [body] is an inactivity
/// timeout: each received body chunk starts a new window. [overall] is the
/// caller-facing wall-clock deadline, including refresh and retry.
class AuthenticatedHttpTimeoutPolicy {
  final Duration header;
  final Duration body;
  final Duration overall;
  final Duration refresh;

  const AuthenticatedHttpTimeoutPolicy({
    required this.header,
    required this.body,
    required this.overall,
    required this.refresh,
  });

  static const standard = AuthenticatedHttpTimeoutPolicy(
    header: Duration(seconds: 15),
    body: Duration(seconds: 15),
    overall: Duration(seconds: 30),
    refresh: Duration(seconds: 8),
  );

  static const longOperation = AuthenticatedHttpTimeoutPolicy(
    header: Duration(seconds: 20),
    body: Duration(seconds: 30),
    overall: Duration(seconds: 90),
    refresh: Duration(seconds: 8),
  );
}

/// An HTTP client for authenticated API repositories.
///
/// Repository instances still keep the token they were created with for
/// backwards compatibility, but a 401 must not permanently poison an open
/// screen. The client refreshes the session once, retries the same request,
/// and shares that refresh with concurrent requests. This is especially
/// important after Android resumes an app whose access token expired while it
/// was backgrounded.
class AuthenticatedHttpClient extends http.BaseClient {
  final http.Client _inner;
  final Future<String?> Function() refreshAccessToken;
  final String? Function()? currentAccessToken;
  final void Function(http.BaseRequest)? onSuccessfulMutation;

  /// Called when the server answers 403 `phone_required`: its phone lock is on and
  /// this account has no phone yet. The caller opens the Add phone screen.
  final void Function()? onPhoneRequired;
  final AccountRecoveryOperationGate recoveryGate;
  final AuthenticatedHttpTimeoutPolicy Function(http.BaseRequest) timeoutFor;

  /// Optional token-aware refresh hook.  A keep-alive refresh can finish
  /// between the original 401 and this callback; in that case the caller
  /// should reuse the newer access token instead of rotating the one-time
  /// refresh token a second time.
  final Future<String?> Function(String rejectedAccessToken)?
  refreshAccessTokenForToken;
  Future<String?>? _refreshInProgress;
  final Set<AccountRecoveryOperationAdmission> _admissions = {};
  final Set<AccountRecoveryOperationAdmission> _pendingTransportAdmissions = {};

  AuthenticatedHttpClient({
    required this.refreshAccessToken,
    this.currentAccessToken,
    this.onSuccessfulMutation,
    this.onPhoneRequired,
    this.refreshAccessTokenForToken,
    AccountRecoveryOperationGate? recoveryGate,
    AuthenticatedHttpTimeoutPolicy Function(http.BaseRequest)? timeoutFor,
    http.Client? inner,
  }) : _inner = inner ?? http.Client(),
       recoveryGate = recoveryGate ?? AccountRecoveryOperationGate.process,
       timeoutFor = timeoutFor ?? _defaultTimeoutFor;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final admission = recoveryGate.admit();
    _admissions.add(admission);
    final policy = timeoutFor(request);
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _send(request, policy, stopwatch, admission);
      // Header arrival does not mean an outbox operation finished. Retain
      // admission through response consumption, cancellation or stream error.
      return http.StreamedResponse(
        _trackedBody(response.stream, admission, policy, stopwatch),
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (_) {
      if (!_pendingTransportAdmissions.remove(admission)) {
        _finishAdmission(admission);
      }
      rethrow;
    }
  }

  Stream<List<int>> _trackedBody(
    Stream<List<int>> source,
    AccountRecoveryOperationAdmission admission,
    AuthenticatedHttpTimeoutPolicy policy,
    Stopwatch stopwatch,
  ) async* {
    try {
      yield* _timedBody(source, policy, stopwatch);
    } finally {
      _finishAdmission(admission);
    }
  }

  void _finishAdmission(AccountRecoveryOperationAdmission admission) {
    _admissions.remove(admission);
    admission.finish();
  }

  Future<http.StreamedResponse> _send(
    http.BaseRequest request,
    AuthenticatedHttpTimeoutPolicy policy,
    Stopwatch stopwatch,
    AccountRecoveryOperationAdmission admission,
  ) async {
    final liveToken = currentAccessToken?.call();
    final originalHeader =
        request.headers['authorization'] ?? request.headers['Authorization'];
    final originalSubject = _subject(
      originalHeader?.replaceFirst('Bearer ', ''),
    );
    final currentSubject = _subject(liveToken);
    if (currentAccessToken != null &&
        originalSubject != null &&
        (liveToken == null || currentSubject != originalSubject)) {
      throw ApiException(
        accountChangedDebugMessage,
        userMessage:
            'Your account changed. Please retry from the current account.',
      );
    }
    if (currentAccessToken != null) {
      if (liveToken != null && liveToken.isNotEmpty) {
        // Repository objects may outlive an access-token rotation. Update the
        // header here so normal requests use the live token and do not create
        // a predictable 401/refresh/retry cycle every five minutes.
        request.headers['authorization'] = 'Bearer $liveToken';
      } else {
        // Do not let an old repository instance send a signed-out account's
        // credential after the account namespace has changed.
        request.headers.remove('authorization');
        request.headers.remove('Authorization');
      }
    }
    final response = await _sendHeaders(request, policy, stopwatch, admission);
    _didRespond(request, response);
    if (response.statusCode == 403 &&
        onPhoneRequired != null &&
        request is http.Request) {
      // Read the reply so a 403 that means "add your phone" can be told apart from
      // any other 403, then hand the unchanged reply back to the caller.
      final body = await _readBody(response.stream, policy, stopwatch);
      if (_isPhoneRequired(body)) {
        try {
          onPhoneRequired!.call();
        } catch (_) {
          // Opening the screen is best effort; the caller still sees the 403.
        }
      }
      return _replayResponse(response, body);
    }
    if (response.statusCode != 401 || request is! http.Request) {
      return response;
    }

    // Buffer the first response before refreshing so the original failure is
    // still returned intact if the refresh cannot recover the session.
    final body = await _readBody(response.stream, policy, stopwatch);
    final authorization =
        request.headers['authorization'] ?? request.headers['Authorization'];
    final rejectedAccessToken =
        authorization != null && authorization.startsWith('Bearer ')
        ? authorization.substring('Bearer '.length)
        : '';
    // Do not start a refresh after the caller's overall budget is exhausted;
    // otherwise a timed-out request could leave an untracked refresh running.
    final refreshTimeout = _remaining(policy.refresh, policy, stopwatch);
    final newToken = await _refreshOnce(
      rejectedAccessToken,
    ).timeout(refreshTimeout);
    if (newToken == null || newToken.isEmpty) {
      return _replayResponse(response, body);
    }
    if (originalSubject != null && _subject(newToken) != originalSubject) {
      throw ApiException(
        'Account changed during refresh',
        userMessage:
            'Your account changed. Please retry from the current account.',
      );
    }

    final retry = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..headers['Authorization'] = 'Bearer $newToken';
    final retried = await _sendHeaders(retry, policy, stopwatch, admission);
    _didRespond(retry, retried);
    return retried;
  }

  Future<http.StreamedResponse> _sendHeaders(
    http.BaseRequest request,
    AuthenticatedHttpTimeoutPolicy policy,
    Stopwatch stopwatch,
    AccountRecoveryOperationAdmission admission,
  ) async {
    // Compute the deadline before starting the transport. If the overall
    // request budget is already exhausted, do not start an operation that
    // cannot be tracked or drained by the timeout handoff below.
    final headerTimeout = _remaining(policy.header, policy, stopwatch);
    final pending = _inner.send(request);
    try {
      return await pending.timeout(headerTimeout);
    } on TimeoutException {
      // Future.timeout only bounds this caller; it does not cancel the
      // underlying http operation. Keep the recovery gate held while the
      // transport settles so an unknown mutation cannot overlap recovery.
      _pendingTransportAdmissions.add(admission);
      unawaited(_settlePendingTransport(pending, admission));
      rethrow;
    }
  }

  Future<void> _settlePendingTransport(
    Future<http.StreamedResponse> pending,
    AccountRecoveryOperationAdmission admission,
  ) async {
    try {
      final response = await pending;
      // The timed-out caller has no consumer, so drain the response to settle
      // the stream. This is deliberately not bounded: releasing the recovery
      // fence before an unknown write settles is less safe than waiting.
      await response.stream.drain<void>();
    } catch (_) {
      // A failed or cancelled transport is settled for the purpose of the
      // local recovery fence; the original caller already received timeout.
    } finally {
      _pendingTransportAdmissions.remove(admission);
      admission.finish();
    }
  }

  Future<List<int>> _readBody(
    Stream<List<int>> source,
    AuthenticatedHttpTimeoutPolicy policy,
    Stopwatch stopwatch,
  ) async {
    final bytes = <int>[];
    await for (final chunk in _timedBody(source, policy, stopwatch)) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Stream<List<int>> _timedBody(
    Stream<List<int>> source,
    AuthenticatedHttpTimeoutPolicy policy,
    Stopwatch stopwatch,
  ) async* {
    final inactivity = _remaining(policy.body, policy, stopwatch);
    await for (final chunk in source.timeout(
      inactivity,
      onTimeout: (sink) => sink.addError(
        TimeoutException('Authenticated response body timed out'),
      ),
    )) {
      if (stopwatch.elapsed >= policy.overall) {
        throw TimeoutException('Authenticated request timed out');
      }
      yield chunk;
    }
  }

  Duration _remaining(
    Duration requested,
    AuthenticatedHttpTimeoutPolicy policy,
    Stopwatch stopwatch,
  ) {
    final remainingOverall = policy.overall - stopwatch.elapsed;
    if (remainingOverall <= Duration.zero) {
      throw TimeoutException('Authenticated request timed out');
    }
    return requested < remainingOverall ? requested : remainingOverall;
  }

  static AuthenticatedHttpTimeoutPolicy _defaultTimeoutFor(
    http.BaseRequest request,
  ) {
    final path = request.url.path.toLowerCase();
    final longOperation =
        path.contains('/import') ||
        path.contains('/backup') ||
        path.contains('/recovery') ||
        path.contains('/export');
    return longOperation
        ? AuthenticatedHttpTimeoutPolicy.longOperation
        : AuthenticatedHttpTimeoutPolicy.standard;
  }

  void _didRespond(http.BaseRequest request, http.StreamedResponse response) {
    if (!['GET', 'HEAD', 'OPTIONS'].contains(request.method) &&
        response.statusCode >= 200 &&
        response.statusCode < 300) {
      try {
        onSuccessfulMutation?.call(request);
      } catch (_) {
        // Refresh metadata is best-effort. A server-accepted write must not
        // look failed and invite the user to submit another transaction.
      }
    }
  }

  static bool _isPhoneRequired(List<int> body) {
    try {
      final decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
      return decoded is Map && decoded['error'] == 'phone_required';
    } catch (_) {
      return false;
    }
  }

  static String? _subject(String? token) {
    try {
      final parts = token?.split('.');
      if (parts == null || parts.length != 3) return null;
      return (jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map)['sub']
          as String?;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _refreshOnce(String rejectedAccessToken) {
    final active = _refreshInProgress;
    if (active != null) return active;
    final future = refreshAccessTokenForToken != null
        ? refreshAccessTokenForToken!(rejectedAccessToken)
        : refreshAccessToken();
    _refreshInProgress = future;
    return future.whenComplete(() {
      if (identical(_refreshInProgress, future)) {
        _refreshInProgress = null;
      }
    });
  }

  http.StreamedResponse _replayResponse(
    http.StreamedResponse response,
    List<int> body,
  ) {
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      response.statusCode,
      contentLength: body.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    _inner.close();
    for (final admission in _admissions.toList()) {
      if (!_pendingTransportAdmissions.contains(admission)) {
        _finishAdmission(admission);
      }
    }
  }
}
