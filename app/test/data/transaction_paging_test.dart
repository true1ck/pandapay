import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/user_cards_repository.dart';

String pageBody({bool hasMore = false, String? nextCursor}) => jsonEncode({
  'transactions': [
    {'id': 'one', 'amount_inr': '12.50', 'occurred_at': '2026-11-01T12:00:00Z'},
  ],
  'pageInfo': {'hasMore': hasMore, 'nextCursor': nextCursor},
});

void main() {
  test(
    'first page retains filters and reports partial query coverage',
    () async {
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'account-a',
        client: MockClient((request) async {
          expect(request.url.queryParameters, {
            'pageSize': '50',
            'from': '2026-10-01',
            'to': '2026-11-01',
            'cardId': 'card-a',
            'userCategoryId': 'food',
            'source': 'sms',
            'q': 'coffee',
          });
          return http.Response(
            pageBody(hasMore: true, nextCursor: 'opaque'),
            200,
          );
        }),
      );
      final page = await repository.fetchTransactionPage(
        pageSize: 50,
        from: DateTime(2026, 10, 1),
        to: DateTime(2026, 11, 1),
        cardId: 'card-a',
        categoryId: 'custom:food',
        source: 'sms',
        query: ' coffee ',
      );
      expect(page.rows.single.id, 'one');
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'opaque');
      expect(page.coversQuery, isFalse);
    },
  );

  test('last continuation page never claims whole-query coverage', () async {
    final repository = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'account-a',
      client: MockClient((request) async {
        expect(request.url.queryParameters['cursor'], 'opaque+/=');
        return http.Response(pageBody(), 200);
      }),
    );
    final page = await repository.fetchTransactionPage(cursor: 'opaque+/=');
    expect(page.hasMore, isFalse);
    expect(page.coversQuery, isFalse);
    expect(() => page.rows.clear(), throwsUnsupportedError);
  });

  test(
    'single first page and known empty first page cover their query',
    () async {
      for (final body in [
        pageBody(),
        '{"transactions":[],"pageInfo":{"hasMore":false,"nextCursor":null}}',
      ]) {
        final repository = UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'account-a',
          client: MockClient((_) async => http.Response(body, 200)),
        );
        final page = await repository.fetchTransactionPage();
        expect(page.coversQuery, isTrue);
      }
    },
  );

  test('missing or inconsistent paging metadata fails closed', () async {
    for (final body in [
      '{"transactions":[]}',
      '{"transactions":[],"pageInfo":{"hasMore":true,"nextCursor":null}}',
      '{"transactions":[],"pageInfo":{"hasMore":false,"nextCursor":"unexpected"}}',
    ]) {
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'account-a',
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        repository.fetchTransactionPage(),
        throwsFormatException,
      );
    }
  });

  test(
    'page requests coalesce separately from legacy requests and retry',
    () async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'account-a',
        client: MockClient((request) async {
          calls++;
          if (request.url.queryParameters['pageSize'] == null) {
            expect(request.url.queryParameters, isEmpty);
            return http.Response('{"transactions":[]}', 200);
          }
          if (calls == 1) return pending.future;
          return http.Response(pageBody(), 200);
        }),
      );
      final first = repository.fetchTransactionPage();
      expect(identical(first, repository.fetchTransactionPage()), isTrue);
      expect(await repository.fetchTransactions(), isEmpty);
      pending.complete(http.Response('unavailable', 503));
      await expectLater(first, throwsException);
      expect((await repository.fetchTransactionPage()).coversQuery, isTrue);
      expect(calls, 3);
    },
  );

  test('invalid page bounds do not start a transport request', () async {
    var calls = 0;
    final repository = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'account-a',
      client: MockClient((_) async {
        calls++;
        return http.Response(pageBody(), 200);
      }),
    );
    for (final size in [0, 501]) {
      expect(
        () => repository.fetchTransactionPage(pageSize: size),
        throwsArgumentError,
      );
    }
    expect(
      () => repository.fetchTransactionPage(cursor: ''),
      throwsArgumentError,
    );
    expect(calls, 0);
  });
}
