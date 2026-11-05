import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_request_headers_client.dart';
import 'package:pandapay/data/authenticated_http_client.dart';

final _api = Uri.parse('https://api.example.test:8443');

ApiRequestHeadersClient _client(
  http.Client inner, {
  bool v2 = false,
  String? version = '1.4.0+57',
}) => ApiRequestHeadersClient(
  inner: inner,
  apiBaseUrl: _api,
  appVersion: () async => version,
  pipelineV2Enabled: () => v2,
);

void main() {
  test('adds X-App-Version to every PandaPay API request and nothing else', () async {
    http.BaseRequest? seen;
    final client = _client(MockClient((r) async {
      seen = r;
      return http.Response('{}', 200);
    }));
    final request = http.Request('POST', Uri.parse('https://api.example.test:8443/transactions'))
      ..headers['authorization'] = 'Bearer t'
      ..headers['content-type'] = 'application/json'
      ..body = '{"a":1}';
    final before = Map.of(request.headers);
    await client.send(request);
    final expected = {...before, 'X-App-Version': '1.4.0+57'};
    expect(seen!.headers, expected);
    expect((seen! as http.Request).body, '{"a":1}');
    expect(seen!.url.path, '/transactions');
    expect(seen!.method, 'POST');
  });

  test('X-Sms-Pipeline: v2 only when the v2 pipeline is enabled', () async {
    final seen = <Map<String, String>>[];
    Future<void> run(bool v2) async {
      final client = _client(MockClient((r) async {
        seen.add(Map.of(r.headers));
        return http.Response('{}', 200);
      }), v2: v2);
      await client.get(Uri.parse('https://api.example.test:8443/transactions'));
    }

    await run(false);
    await run(true);
    expect(seen[0].containsKey('X-Sms-Pipeline'), isFalse);
    expect(seen[0]['X-App-Version'], '1.4.0+57');
    expect(seen[1]['X-Sms-Pipeline'], 'v2');
    expect(seen[1]['X-App-Version'], '1.4.0+57');
  });

  test('requests to other hosts are untouched', () async {
    final seen = <Map<String, String>>[];
    final client = _client(MockClient((r) async {
      seen.add(Map.of(r.headers));
      return http.Response('{}', 200);
    }), v2: true);
    await client.get(Uri.parse('https://maps.example.test/place'));
    await client.get(Uri.parse('https://api.example.test/transactions')); // other port
    expect(seen, [<String, String>{}, <String, String>{}]);
  });

  test('an unreadable version omits the header instead of sending junk', () async {
    for (final bad in [null, '', 'v1\r\nX-Evil: 1', 'ünï']) {
      Map<String, String>? seen;
      final client = _client(MockClient((r) async {
        seen = Map.of(r.headers);
        return http.Response('{}', 200);
      }), version: bad);
      await client.get(Uri.parse('https://api.example.test:8443/x'));
      expect(seen!.containsKey('X-App-Version'), isFalse, reason: '$bad');
    }
  });

  test('works as the inner client of AuthenticatedHttpClient, including the 401 retry', () async {
    final seen = <Map<String, String>>[];
    var calls = 0;
    final auth = AuthenticatedHttpClient(
      refreshAccessToken: () async => 'new',
      inner: _client(MockClient((r) async {
        seen.add(Map.of(r.headers));
        return http.Response('{}', ++calls == 1 ? 401 : 200);
      }), v2: true),
    );
    final res = await auth.get(
      Uri.parse('https://api.example.test:8443/transactions'),
      headers: {'authorization': 'Bearer old'},
    );
    expect(res.statusCode, 200);
    expect(seen, hasLength(2));
    for (final h in seen) {
      expect(h['X-App-Version'], '1.4.0+57');
      expect(h['X-Sms-Pipeline'], 'v2');
    }
    expect(seen[1]['authorization'] ?? seen[1]['Authorization'], 'Bearer new');
  });

  test('close closes the inner client', () {
    var closed = false;
    final client = _client(_Closing(() => closed = true));
    client.close();
    expect(closed, isTrue);
  });
}

class _Closing extends http.BaseClient {
  _Closing(this.onClose);
  final void Function() onClose;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();
  @override
  void close() => onClose();
}
