import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'connectivity/write_fence.dart';
import 'server_clock.dart';


/// Build-time fallback for the app version, used only when the platform
/// cannot report one (for example a background isolate without plugins).
const String _versionDefine = String.fromEnvironment('PANDAPAY_APP_VERSION');

final RegExp _safeVersion = RegExp(r'^[0-9A-Za-z.+_-]{1,40}$');

String? _cachedVersion;

/// `1.4.0+57` (version plus build number) from the installed package, else
/// the `PANDAPAY_APP_VERSION` define, else null (the header is then omitted).
/// The server's version gate treats an absent header as an old app.
Future<String?> loadApiAppVersion() async {
  final cached = _cachedVersion;
  if (cached != null) return cached;
  String? value;
  try {
    final info = await PackageInfo.fromPlatform();
    final build = info.buildNumber.trim();
    value = build.isEmpty ? info.version.trim() : '${info.version.trim()}+$build';
  } catch (_) {
    value = null;
  }
  if (value == null || !_safeVersion.hasMatch(value)) {
    value = _versionDefine.trim();
  }
  if (!_safeVersion.hasMatch(value)) return null;
  return _cachedVersion = value;
}

/// Adds `X-App-Version` and `X-Sms-Pipeline: v2` to requests for the PandaPay
/// API origin. Requests to any other origin, and every other part of a request, pass through unchanged.
///
/// The server uses `X-App-Version` for the legacy-SMS upgrade gate and
/// `X-Sms-Pipeline: v2` to decide whether a client understands `refund` rows.
class ApiRequestHeadersClient extends http.BaseClient {
  ApiRequestHeadersClient({
    required this.inner,
    required Uri apiBaseUrl,
    Future<String?> Function()? appVersion,
    ServerClock? serverClock,
    WriteFence? writeFence,
  }) : _origin = apiBaseUrl.origin,
       _basePath = apiBaseUrl.path.endsWith('/')
           ? apiBaseUrl.path.substring(0, apiBaseUrl.path.length - 1)
           : apiBaseUrl.path,
       _appVersion = appVersion ?? loadApiAppVersion,
       _serverClock = serverClock ?? ServerClock.instance,
       _writeFence = writeFence ?? WriteFence.process;

  final http.Client inner;
  final String _origin;
  final String _basePath;
  final Future<String?> Function() _appVersion;
  final ServerClock _serverClock;
  final WriteFence _writeFence;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _origin) return inner.send(request);
    final version = await _appVersion();
    if (version != null && _safeVersion.hasMatch(version)) {
      request.headers['X-App-Version'] = version;
    }
    request.headers['X-Sms-Pipeline'] = 'v2';
    final sentAt = DateTime.now();
    final response = await inner.send(request);
    _observeServerClock(response, sentAt);
    _observeWrite(request, response);
    return response;
  }

  /// The one place every acknowledged write to the API passes, so no endpoint
  /// can be forgotten: a read that was in flight when this happens may have
  /// been answered from before it (see [WriteFence]). Only a 2xx counts; a
  /// refused write changed nothing. Never throws.
  void _observeWrite(http.BaseRequest request, http.StreamedResponse response) {
    try {
      final status = response.statusCode;
      if (status < 200 || status >= 300) return;
      var path = request.url.path;
      if (_basePath.isNotEmpty && path.startsWith(_basePath)) {
        path = path.substring(_basePath.length);
      }
      if (WriteFence.countsAsDataWrite(request.method, path)) {
        _writeFence.markAcked();
      }
    } catch (_) {
      // Bookkeeping must never fail an API call.
    }
  }

  /// D9: learn the device-vs-server clock skew from the `Date` header of a
  /// successful response. Best effort and never throws; the response is
  /// returned untouched (its body stream is not read). Cached responses
  /// (`Age` header) say nothing about the current time and are skipped.
  void _observeServerClock(http.StreamedResponse response, DateTime sentAt) {
    try {
      final status = response.statusCode;
      if (status < 200 || status >= 300) return;
      final headers = response.headers;
      if (headers.containsKey('age')) return;
      final receivedAt = DateTime.now();
      // The server stamped the response somewhere inside the round trip; the
      // midpoint is the least biased estimate of the matching device time.
      final midpoint = sentAt.add(receivedAt.difference(sentAt) ~/ 2);
      _serverClock.observeDateHeader(headers['date'], receivedAt: midpoint);
    } catch (_) {
      // A malformed header must never fail an API call.
    }
  }

  @override
  void close() => inner.close();
}
