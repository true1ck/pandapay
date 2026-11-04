import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'env.dart';
import 'local_sms_rig_build.dart';

http.Client? localSmsRigHttpClient() {
  if (!LocalSmsRigBuild.enabled) {
    return null;
  }
  return LocalSmsRigHttpClient(
    apiUri: Uri.parse(Env.apiBaseUrl),
    authUri: Uri.parse(Env.authBaseUrl),
    caPem: base64Decode(LocalSmsRigBuild.encodedCa),
  );
}

/// Trusts a single scratch CA for the rig's two HTTPS origins.
final class LocalSmsRigHttpClient extends http.BaseClient {
  LocalSmsRigHttpClient({
    required Uri apiUri,
    required Uri authUri,
    required List<int> caPem,
  }) : _origins = {_localOrigin(apiUri), _localOrigin(authUri)} {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(caPem);
    _inner = IOClient(HttpClient(context: context));
  }

  final Set<String> _origins;
  late final IOClient _inner;

  static String _localOrigin(Uri uri) {
    final ip = InternetAddress.tryParse(uri.host);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        ip == null ||
        ip.type != InternetAddressType.IPv4) {
      throw ArgumentError('The SMS rig requires a private IPv4 HTTPS origin');
    }
    final [first, second, _, _] = ip.rawAddress.toList(growable: false);
    if (!ip.isLoopback &&
        first != 10 &&
        !(first == 172 && second >= 16 && second <= 31) &&
        !(first == 192 && second == 168)) {
      throw ArgumentError('The SMS rig requires a private IPv4 HTTPS origin');
    }
    return uri.origin;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !_origins.contains(uri.origin)) {
      throw http.ClientException('Request is outside the local SMS rig', uri);
    }
    request.followRedirects = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
