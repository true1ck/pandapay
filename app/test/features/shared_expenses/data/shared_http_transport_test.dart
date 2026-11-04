import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/data/shared_transport.dart';

import '../storage/shared_store_test.dart' as fixtures;

String tokenFor(String account) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': account}))).replaceAll('=', '')}.signature';
const headers = {
  'content-type': 'application/json',
  'cache-control': 'private, no-store',
};

void main() {
  late AuthenticatedHttpClient client;
  late SharedExpensesHttpTransport remote;
  late Future<http.Response> Function(http.Request) handler;
  var current = true;
  late String? token;
  setUp(() {
    current = true;
    token = tokenFor(fixtures.accountA.substring(5));
    handler = (_) async => http.Response('{}', 500, headers: headers);
    client = AuthenticatedHttpClient(
      inner: MockClient((request) => handler(request)),
      refreshAccessToken: () async => null,
      currentAccessToken: () => token,
    );
    remote = SharedExpensesHttpTransport(
      apiBaseUrl: 'https://api.example.test',
      namespace: fixtures.accountA,
      client: client,
      accessToken: () => token,
      isCurrent: () => current,
    );
  });
  tearDown(() => client.close());
  test(
    'overview and totals preserve exact money and reject mismatched context',
    () async {
      handler = (request) async => http.Response(
        jsonEncode(
          request.url.path.endsWith('/overview')
              ? {
                  'currency': 'INR',
                  'owedMinor': '100',
                  'owingMinor': '100',
                  'netMinor': '0',
                  'contextCount': '2',
                  'expenseCount': '3',
                }
              : {
                  'contextId': fixtures.contextId,
                  'currency': 'INR',
                  'sharedTotalMinor': '120000',
                  'yourPaidMinor': '0',
                  'yourShareMinor': '40000',
                  'expenseCount': '1',
                  'memberId': fixtures.contextId,
                },
        ),
        200,
        headers: headers,
      );
      expect((await remote.fetchOverview())['owedMinor'], '100');
      expect(
        (await remote.fetchTotals(fixtures.contextId))['yourShareMinor'],
        '40000',
      );
    },
  );
  test(
    'authorized context detail is scoped and a permission denial fences cached scope',
    () async {
      String? fenced;
      remote = SharedExpensesHttpTransport(
        apiBaseUrl: 'https://api.example.test',
        namespace: fixtures.accountA,
        client: client,
        accessToken: () => token,
        isCurrent: () => current,
        onContextRevoked: (id) async {
          fenced = id;
        },
      );
      handler = (_) async => http.Response(
        jsonEncode({
          'contextId': fixtures.contextId,
          'kind': 'group',
          'name': 'Home',
          'currency': 'INR',
          'state': 'active',
          'membershipState': 'active',
          'committedSequence': '2',
          'createdAt': '2026-11-04T00:00:00Z',
        }),
        200,
        headers: headers,
      );
      expect((await remote.fetchContext(fixtures.contextId))['name'], 'Home');
      handler = (_) async => http.Response(
        '{"error":"context_not_authorized"}',
        403,
        headers: headers,
      );
      await expectLater(
        () => remote.fetchMembers(fixtures.contextId),
        throwsA(isA<SharedTransportException>()),
      );
      expect(fenced, fixtures.contextId);
      fenced = null;
      handler = (_) async =>
          http.Response('{"error":"context_not_found"}', 404, headers: headers);
      await expectLater(
        () => remote.fetchMembers(fixtures.contextId),
        throwsA(isA<SharedTransportException>()),
      );
      expect(fenced, fixtures.contextId);
      fenced = null;
      handler = (_) async =>
          http.Response('{"error":"expense_not_found"}', 404, headers: headers);
      await expectLater(
        () => remote.fetchExpense(fixtures.contextId, fixtures.op1),
        throwsA(isA<SharedTransportException>()),
      );
      expect(fenced, isNull);
    },
  );
  test(
    'capabilities and list reads stay allowlisted, bounded and account fenced',
    () async {
      handler = (request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'available': true,
              'reads': true,
              'proposals': true,
              'acceptedWrites': false,
              'settlements': false,
              'sourceFunding': false,
            }),
            200,
            headers: headers,
          );
        }
        expect(
          request.url.path,
          '/shared-expenses/contexts/${fixtures.contextId}/members',
        );
        expect(request.url.queryParameters, {'limit': '20', 'after': 'opaque'});
        return http.Response(
          jsonEncode({
            'items': [
              {'contextId': fixtures.contextId, 'memberId': fixtures.op1},
            ],
            'nextCursor': null,
            'hasMore': false,
          }),
          200,
          headers: headers,
        );
      };
      expect((await remote.fetchCapabilities())['acceptedWrites'], isFalse);
      expect(
        (await remote.fetchMembers(
          fixtures.contextId,
          limit: 20,
          after: 'opaque',
        ))['items'],
        hasLength(1),
      );
      handler = (_) async => http.Response(
        jsonEncode({
          'items': List.filled(101, {}),
          'nextCursor': null,
          'hasMore': false,
        }),
        200,
        headers: headers,
      );
      await expectLater(
        () => remote.fetchContexts(),
        throwsA(isA<SharedTransportException>()),
      );
    },
  );
  test(
    'execute preserves immutable wire, authorization and disables redirects',
    () async {
      final command = fixtures.command();
      handler = (request) async {
        expect(request.url.path, '/shared-expenses/commands');
        expect(request.headers['authorization'], 'Bearer $token');
        expect(request.headers['content-type'], contains('application/json'));
        expect(request.followRedirects, isFalse);
        expect(request.body, command.canonicalJson);
        return http.Response(
          jsonEncode({
            'receipt': fixtures.receipt(command).toJson(),
            'records': [],
          }),
          200,
          headers: headers,
        );
      };
      expect(
        (await remote.execute(command)).receipt.requestHash,
        command.requestHash,
      );
    },
  );

  test(
    'authenticated refresh retry preserves no-redirect and immutable bytes',
    () async {
      client.close();
      var attempts = 0;
      final original = token!;
      client = AuthenticatedHttpClient(
        inner: MockClient((request) async {
          attempts++;
          expect(request.followRedirects, isFalse);
          expect(request.body, fixtures.command().canonicalJson);
          if (attempts == 1) return http.Response('{}', 401, headers: headers);
          expect(request.headers['authorization'], isNot('Bearer $original'));
          return http.Response(
            jsonEncode({
              'receipt': fixtures.receipt(fixtures.command()).toJson(),
              'records': [],
            }),
            200,
            headers: headers,
          );
        }),
        currentAccessToken: () => token,
        refreshAccessToken: () async {
          token = '${tokenFor(fixtures.accountA.substring(5))}rotated';
          return token;
        },
      );
      remote = SharedExpensesHttpTransport(
        apiBaseUrl: 'https://api.example.test',
        namespace: fixtures.accountA,
        client: client,
        accessToken: () => token,
        isCurrent: () => current,
      );
      await remote.execute(fixtures.command());
      expect(attempts, 2);
    },
  );
  test(
    'operation lookup 404 is unknown only for explicit operation_not_found',
    () async {
      handler = (_) async => http.Response(
        '{"error":"operation_not_found"}',
        404,
        headers: headers,
      );
      expect(await remote.lookupOperation(fixtures.op1), isNull);
      handler = (_) async =>
          http.Response('{"error":"context_not_found"}', 404, headers: headers);
      await expectLater(
        () => remote.lookupOperation(fixtures.op1),
        throwsA(
          isA<SharedTransportException>().having(
            (e) => e.statusCode,
            'status',
            404,
          ),
        ),
      );
    },
  );
  test(
    'different receipt hash and operation cannot acknowledge a command',
    () async {
      handler = (_) async => http.Response(
        jsonEncode({
          'receipt': fixtures.receipt(fixtures.command(fixtures.op2)).toJson(),
          'records': [],
        }),
        200,
        headers: headers,
      );
      await expectLater(
        () => remote.execute(fixtures.command()),
        throwsA(isA<SharedTransportException>()),
      );
    },
  );
  test(
    'pull requires bounded materialized projections and access markers',
    () async {
      handler = (request) async {
        expect(request.url.queryParameters, {
          'limit': '100',
          'after': 'opaque:cursor',
        });
        return http.Response(
          jsonEncode({
            'records': [
              {
                'entity': 'contexts',
                'id': fixtures.contextId,
                'contextId': fixtures.contextId,
                'revision': 2,
                'payload': {'title': 'Home'},
                'deleted': false,
              },
            ],
            'nextCursor': 'next',
            'hasMore': false,
            'revokedContextIds': [],
            'grantedContextIds': [fixtures.contextId],
          }),
          200,
          headers: headers,
        );
      };
      final result = await remote.pull(cursor: 'opaque:cursor');
      expect(result.records.single.revision, 2);
      expect(result.grantedContextIds, [fixtures.contextId]);
      handler = (_) async => http.Response(
        '{"events":[],"nextCursor":"unsafe","hasMore":false}',
        200,
        headers: headers,
      );
      await expectLater(
        () => remote.pull(),
        throwsA(isA<SharedTransportException>()),
      );
    },
  );
  test(
    'no credential leaves after account change, token owner mismatch or sign out',
    () async {
      var calls = 0;
      handler = (_) async {
        calls++;
        return http.Response('{}', 500, headers: headers);
      };
      current = false;
      await expectLater(
        () => remote.execute(fixtures.command()),
        throwsA(isA<SharedTransportException>()),
      );
      current = true;
      token = tokenFor(fixtures.accountB.substring(5));
      await expectLater(
        () => remote.pull(),
        throwsA(isA<SharedTransportException>()),
      );
      token = null;
      await expectLater(
        () => remote.pull(),
        throwsA(isA<SharedTransportException>()),
      );
      expect(calls, 0);
    },
  );
  test(
    'account switch while reading response cannot publish stale receipt',
    () async {
      final delayed = Completer<void>();
      handler = (_) async {
        await delayed.future;
        return http.Response(
          jsonEncode({
            'receipt': fixtures.receipt(fixtures.command()).toJson(),
            'records': [],
          }),
          200,
          headers: headers,
        );
      };
      final pending = remote.execute(fixtures.command());
      await Future<void>.delayed(Duration.zero);
      current = false;
      delayed.complete();
      await expectLater(
        () => pending,
        throwsA(isA<SharedTransportException>()),
      );
    },
  );
  test(
    'redirects, wrong content-type and oversized bodies fail without exposing raw data',
    () async {
      for (final response in [
        http.Response(
          'private payload',
          302,
          headers: {...headers, 'location': 'https://external.invalid'},
        ),
        http.Response(
          '<html>private</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
        http.Response('x' * 2100000, 200, headers: headers),
      ]) {
        handler = (_) async => response;
        try {
          await remote.execute(fixtures.command());
          fail('Expected invalid response');
        } on SharedTransportException catch (error) {
          expect(error.toString(), isNot(contains('private')));
          expect(error.toString(), isNot(contains(token!)));
        }
      }
    },
  );
  test(
    'constructor refuses credential-bearing or insecure external API URL',
    () {
      for (final url in [
        'https://user:secret@api.example.test',
        'http://external.invalid',
        'https://api.example.test/?token=secret',
      ]) {
        expect(
          () => SharedExpensesHttpTransport(
            apiBaseUrl: url,
            namespace: fixtures.accountA,
            client: client,
            accessToken: () => token,
            isCurrent: () => current,
          ),
          throwsArgumentError,
        );
      }
    },
  );
}
