import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';

const account = 'user:11111111-1111-4111-8111-111111111111';
String uid(int i) =>
    '33333333-3333-4333-8333-${i.toRadixString(16).padLeft(12, '0')}';

void main() {
  test('a large change page is parsed off the UI isolate and still strict', () async {
    final token =
        'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': account.substring(5)}))).replaceAll('=', '')}.sig';
    var bad = false;
    final client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((request) async {
        final records = [
          for (var i = 0; i < 40; i++)
            {
              'entity': 'contexts',
              'id': uid(i),
              'contextId': uid(i),
              'revision': bad && i == 39 ? -1 : i + 1,
              'payload': {'title': 'Split $i'},
              'deleted': false,
            },
        ];
        return http.Response(
          jsonEncode({
            'records': records,
            'nextCursor': null,
            'hasMore': false,
            'revokedContextIds': [],
            'grantedContextIds': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);
    final remote = SharedExpensesHttpTransport(
      apiBaseUrl: 'https://api.example.test',
      namespace: account,
      client: client,
      accessToken: () => token,
      isCurrent: () => true,
    );
    final page = await remote.pull();
    expect(page.records, hasLength(40));
    expect(page.records.first.payload['title'], 'Split 0');
    bad = true;
    await expectLater(
      remote.pull(),
      throwsA(
        isA<Object>().having(
          (e) => e.toString(),
          'message',
          contains('Shared request unavailable'),
        ),
      ),
    );
  });
}
