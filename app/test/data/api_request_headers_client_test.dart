import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_request_headers_client.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/connectivity/write_fence.dart';

final _api = Uri.parse('https://api.example.test:8443');

ApiRequestHeadersClient _client(
  http.Client inner, {
  String? version = '1.4.0+57',
}) => ApiRequestHeadersClient(
  inner: inner,
  apiBaseUrl: _api,
  appVersion: () async => version,
);

void main() {
  test('adds only X-App-Version and X-Sms-Pipeline to PandaPay API requests', () async {
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
    final expected = {
      ...before,
      'X-App-Version': '1.4.0+57',
      'X-Sms-Pipeline': 'v2',
    };
    expect(seen!.headers, expected);
    expect((seen! as http.Request).body, '{"a":1}');
    expect(seen!.url.path, '/transactions');
    expect(seen!.method, 'POST');
  });

  test('sends X-Sms-Pipeline: v2 with X-App-Version to the API origin', () async {
    http.BaseRequest? seen;
    final client = _client(MockClient((r) async {
      seen = r;
      return http.Response('{}', 200);
    }));
    await client.get(Uri.parse('https://api.example.test:8443/transactions'));
    expect(seen!.headers['X-Sms-Pipeline'], 'v2');
    expect(seen!.headers['X-App-Version'], '1.4.0+57');
  });

  test('requests to other hosts are untouched', () async {
    final seen = <Map<String, String>>[];
    final client = _client(MockClient((r) async {
      seen.add(Map.of(r.headers));
      return http.Response('{}', 200);
    }));
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
      })),
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

  group('marks acknowledged data writes on the write fence', () {
    // The fence is what stops a read that was in flight from replacing what a
    // write just changed (the 18 Nov "added transaction disappears" bug), so
    // it must see every successful write and nothing else.
    late WriteFence fence;
    setUp(() => fence = WriteFence());

    ApiRequestHeadersClient fenced(MockClient inner, {Uri? base}) =>
        ApiRequestHeadersClient(
          inner: inner,
          apiBaseUrl: base ?? _api,
          appVersion: () async => '1.4.0+57',
          writeFence: fence,
        );

    Future<int> acksAfter(
      ApiRequestHeadersClient client,
      String method,
      String url,
    ) async {
      final token = fence.begin();
      await client.send(http.Request(method, Uri.parse(url)));
      return fence.changedSince(token) ? 1 : 0;
    }

    test('a successful POST/PATCH/PUT/DELETE counts', () async {
      final client = fenced(MockClient((r) async => http.Response('{}', 201)));
      for (final method in ['POST', 'PATCH', 'PUT', 'DELETE']) {
        expect(
          await acksAfter(client, method, 'https://api.example.test:8443/transactions'),
          1,
          reason: method,
        );
      }
    });

    test('reads, refused writes and server errors do not', () async {
      Future<int> ack(String method, int status) => acksAfter(
        fenced(MockClient((r) async => http.Response('{}', status))),
        method,
        'https://api.example.test:8443/transactions',
      );
      expect(await ack('GET', 200), 0);
      expect(await ack('POST', 400), 0, reason: 'a refused write changed nothing');
      expect(await ack('POST', 409), 0);
      expect(await ack('POST', 503), 0, reason: 'unknown outcome: the outbox retries');
    });

    test('bookkeeping endpoints do not make every read look out of date', () async {
      final client = fenced(MockClient((r) async => http.Response('{}', 200)));
      for (final path in ['/analytics/events', '/sync/ack', '/sync/register-device']) {
        expect(await acksAfter(client, 'POST', 'https://api.example.test:8443$path'), 0, reason: path);
      }
    });

    test('an API served below a base path is matched on the path under it', () async {
      final client = fenced(
        MockClient((r) async => http.Response('{}', 200)),
        base: Uri.parse('https://api.example.test:8443/v1/'),
      );
      expect(await acksAfter(client, 'POST', 'https://api.example.test:8443/v1/sync/ack'), 0);
      expect(await acksAfter(client, 'POST', 'https://api.example.test:8443/v1/transactions'), 1);
    });

    test('another host is not the API and never marks it', () async {
      final client = fenced(MockClient((r) async => http.Response('{}', 200)));
      expect(await acksAfter(client, 'POST', 'https://maps.example.test/place'), 0);
    });

    test('a transport failure marks nothing', () async {
      final client = fenced(MockClient((r) async => throw http.ClientException('offline')));
      final token = fence.begin();
      await expectLater(
        client.send(http.Request('POST', Uri.parse('https://api.example.test:8443/transactions'))),
        throwsA(isA<http.ClientException>()),
      );
      expect(fence.changedSince(token), isFalse);
    });
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
