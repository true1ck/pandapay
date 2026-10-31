import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/user_cards_repository.dart';

void main() {
  test('identical transaction queries share a request and retry after failure', () async {
    final firstResponse = Completer<http.Response>();
    var calls = 0;
    final repository = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'account-a',
      client: MockClient((request) {
        calls++;
        expect(request.headers['authorization'], 'Bearer account-a');
        if (calls == 1) return firstResponse.future;
        return Future.value(http.Response('{"transactions":[]}', 200));
      }),
    );

    final first = repository.fetchTransactions();
    final duplicate = repository.fetchTransactions();
    expect(identical(first, duplicate), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    firstResponse.complete(http.Response('unavailable', 503));
    await expectLater(first, throwsException);
    await expectLater(duplicate, throwsException);
    expect(await repository.fetchTransactions(), isEmpty);
    expect(calls, 2);
  });

  test('different filters and repositories never share transaction requests', () async {
    var calls = 0;
    final pending = <Completer<http.Response>>[];
    MockClient client() => MockClient((_) {
      calls++;
      final response = Completer<http.Response>();
      pending.add(response);
      return response.future;
    });
    final firstRepository = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'account-a',
      client: client(),
    );
    final secondRepository = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'account-b',
      client: client(),
    );
    final first = firstRepository.fetchTransactions();
    final filtered = firstRepository.fetchTransactions(cardId: 'card-1');
    final otherAccount = secondRepository.fetchTransactions();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 3);
    for (final response in pending) {
      response.complete(http.Response('{"transactions":[]}', 200));
    }
    await Future.wait([first, filtered, otherAccount]);
  });
}
