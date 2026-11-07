import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111',
    group = '22222222-2222-4222-8222-222222222222';

Map<String, Object?> rec(
  String entity,
  String id, {
  Object? payload = const {'n': 'x'},
}) => {
  'entity': entity,
  'id': id,
  'contextId': group,
  'revision': 1,
  'payload': payload,
  'deleted': false,
};

String _jwt() {
  String b(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b({'alg': 'none'})}.${b({'sub': account})}.sig';
}

void main() {
  late AppDatabase db;
  late AuthenticatedHttpClient client;
  late SharedExpensesRuntime runtime;
  var records = <Object?>[];
  var refusal = 'member_name_taken';
  String? existing;
  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((request) async {
        if (request.url.path.contains('/operations/')) {
          return http.Response(
            jsonEncode({'error': 'operation_not_found'}),
            404,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/commands')) {
          return http.Response(
            jsonEncode({'error': refusal, 'existingContextId': ?existing}),
            409,
            headers: {'content-type': 'application/json'},
          );
        }
        final body = request.url.path.endsWith('/capabilities')
            ? {
                'schemaVersion': 1,
                'available': true,
                'reads': true,
                'proposals': true,
                'acceptedWrites': true,
                'settlements': true,
                'sourceFunding': false,
              }
            : {
                'records': records,
                'nextCursor': 'c1',
                'hasMore': false,
                'revokedContextIds': <String>[],
              };
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    runtime = SharedExpensesRuntime(
      store: SharedExpensesStore(db, namespace: 'user:$account'),
      remote: SharedExpensesHttpTransport(
        apiBaseUrl: 'http://127.0.0.1:4001',
        namespace: 'user:$account',
        client: client,
        accessToken: _jwt,
        isCurrent: () => true,
      ),
      cache: ResponseCache(db),
      isCurrent: () => true,
    );
  });
  tearDown(() {
    runtime.dispose();
    client.close();
    db.close();
  });

  test('a page that repeats records no longer leaves sync lag on', () async {
    records = [
      rec('contexts', group),
      rec('members', 'm1'),
      rec('contexts', group),
      rec('members', 'm1'),
    ];
    await runtime.refresh();
    expect(runtime.lastError, isNull);
    expect(runtime.store.cursor, 'c1');
    expect(runtime.syncLag, isFalse);
  });

  test('a genuinely conflicting page still reports lag and an error', () async {
    records = [
      rec('members', 'm1'),
      rec('members', 'm1', payload: {'n': 'other'}),
    ];
    await runtime.refresh();
    expect(runtime.lastError, isA<SharedLocalException>());
    expect(runtime.syncLag, isTrue);
    expect(runtime.store.cursor, isNull);
  });

  const member = '44444444-4444-4444-8444-444444444444';

  test('a refused rename rolls back and explains why', () async {
    refusal = 'member_name_taken';
    await runtime.refresh();
    await expectLater(
      runtime.renameMember(contextId: group, memberId: member, name: 'Asha'),
      throwsA(
        isA<SharedNameException>().having(
          (e) => e.code,
          'code',
          'member_name_taken',
        ),
      ),
    );
  });

  test('a refused friend carries the chat that already exists', () async {
    refusal = 'friend_name_taken';
    existing = group;
    await runtime.refresh();
    await expectLater(
      runtime.addFriend(name: 'Rahul'),
      throwsA(
        isA<SharedNameException>()
            .having((e) => e.code, 'code', 'friend_name_taken')
            .having((e) => e.existingContextId, 'existing', group),
      ),
    );
  });
}
