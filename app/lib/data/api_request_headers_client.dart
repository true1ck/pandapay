import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../features/sms_v2/flag.dart';

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

/// Adds `X-App-Version` (always) and `X-Sms-Pipeline: v2` (only when the v2
/// pipeline is enabled) to requests for the PandaPay API origin. Requests to
/// any other origin, and every other part of a request, pass through unchanged.
///
/// The server uses `X-App-Version` for the legacy-SMS upgrade gate and
/// `X-Sms-Pipeline: v2` to decide whether a client understands `refund` rows.
class ApiRequestHeadersClient extends http.BaseClient {
  ApiRequestHeadersClient({
    required this.inner,
    required Uri apiBaseUrl,
    Future<String?> Function()? appVersion,
    bool Function()? pipelineV2Enabled,
  }) : _origin = apiBaseUrl.origin,
       _appVersion = appVersion ?? loadApiAppVersion,
       _pipelineV2Enabled = pipelineV2Enabled ?? (() => kSmsPipelineV2);

  final http.Client inner;
  final String _origin;
  final Future<String?> Function() _appVersion;
  final bool Function() _pipelineV2Enabled;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin == _origin) {
      final version = await _appVersion();
      if (version != null && _safeVersion.hasMatch(version)) {
        request.headers['X-App-Version'] = version;
      }
      if (_pipelineV2Enabled()) {
        request.headers['X-Sms-Pipeline'] = 'v2';
      }
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}
