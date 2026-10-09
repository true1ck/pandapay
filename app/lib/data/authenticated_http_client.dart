import 'dart:async';

import 'package:http/http.dart' as http;

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

  /// Optional token-aware refresh hook.  A keep-alive refresh can finish
  /// between the original 401 and this callback; in that case the caller
  /// should reuse the newer access token instead of rotating the one-time
  /// refresh token a second time.
  final Future<String?> Function(String rejectedAccessToken)?
  refreshAccessTokenForToken;
  Future<String?>? _refreshInProgress;

  AuthenticatedHttpClient({
    required this.refreshAccessToken,
    this.currentAccessToken,
    this.refreshAccessTokenForToken,
    http.Client? inner,
  }) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final liveToken = currentAccessToken?.call();
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
    final response = await _inner.send(request);
    if (response.statusCode != 401 || request is! http.Request) {
      return response;
    }

    // Buffer the first response before refreshing so the original failure is
    // still returned intact if the refresh cannot recover the session.
    final body = await response.stream.toBytes();
    final authorization =
        request.headers['authorization'] ?? request.headers['Authorization'];
    final rejectedAccessToken =
        authorization != null && authorization.startsWith('Bearer ')
        ? authorization.substring('Bearer '.length)
        : '';
    final newToken = await _refreshOnce(rejectedAccessToken);
    if (newToken == null || newToken.isEmpty) {
      return _replayResponse(response, body);
    }

    final retry = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..headers['Authorization'] = 'Bearer $newToken';
    return _inner.send(retry);
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
  void close() => _inner.close();
}
