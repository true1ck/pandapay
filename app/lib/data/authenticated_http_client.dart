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
  Future<String?>? _refreshInProgress;

  AuthenticatedHttpClient({
    required this.refreshAccessToken,
    http.Client? inner,
  }) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode != 401 || request is! http.Request) {
      return response;
    }

    // Buffer the first response before refreshing so the original failure is
    // still returned intact if the refresh cannot recover the session.
    final body = await response.stream.toBytes();
    final newToken = await _refreshOnce();
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

  Future<String?> _refreshOnce() {
    final active = _refreshInProgress;
    if (active != null) return active;
    final future = refreshAccessToken();
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
