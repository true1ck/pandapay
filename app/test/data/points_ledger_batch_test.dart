import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/user_cards_repository.dart';

// The app opened with one GET /user-cards/:id/points-ledger per card (about 10 at once on every app open, 3.6-5 s
// each on the 1 GB server, 21 Nov 2026). Calls that arrive together now go out as one GET /points-ledgers. Each card
// still gets exactly its own list, and the same errors the per-card call gave, so the providers, the cache and the
// screens behave as before.

const a = '11111111-1111-4111-8111-111111111111';
const b = '22222222-2222-4222-8222-222222222222';
const c = '33333333-3333-4333-8333-333333333333';

Map<String, dynamic> entry(String id, int points) => {
  'id': id,
  'delta_points': points,
  'reason': 'manual',
  'state': 'confirmed',
  'expires_on': null,
  'occurred_at': '2026-11-20T00:00:00.000Z',
};

UserCardsRepository repo(List<http.Request> seen, Future<http.Response> Function(http.Request) handler) =>
    UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((request) async {
        seen.add(request);
        return handler(request);
      }),
    );

void main() {
  test('cards asked for together share one request, and each gets its own list', () async {
    final seen = <http.Request>[];
    final r = repo(seen, (request) async => http.Response(
      jsonEncode({
        'pointsLedgers': {
          a: [entry('a2', 50), entry('a1', 10)],
          b: [entry('b1', -5)],
          c: <Object>[],
        },
      }),
      200,
    ));
    final results = await Future.wait([r.fetchPointsLedger(a), r.fetchPointsLedger(b), r.fetchPointsLedger(c), r.fetchPointsLedger(a)]);
    expect(seen, hasLength(1));
    expect(seen.single.url.path, '/points-ledgers');
    expect(seen.single.url.queryParameters['userCardIds']!.split(','), unorderedEquals([a, b, c]));
    expect(results[0].map((e) => e.id), ['a2', 'a1']);
    expect(results[1].single.deltaPoints, -5);
    expect(results[2], isEmpty);
    expect(results[3].map((e) => e.id), ['a2', 'a1'], reason: 'the same card twice is asked for once');
  });

  test('a card the server leaves out fails like the per-card 404; the others are unaffected', () async {
    final seen = <http.Request>[];
    final r = repo(seen, (request) async => http.Response(jsonEncode({'pointsLedgers': {a: [entry('a1', 1)]}}), 200));
    final ok = r.fetchPointsLedger(a);
    final missing = r.fetchPointsLedger(b);
    expect((await ok).single.id, 'a1');
    await expectLater(missing, throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)));
  });

  test('a server without the batched route is asked per card, as before, from then on', () async {
    final seen = <http.Request>[];
    final r = repo(seen, (request) async {
      if (request.url.path == '/points-ledgers') return http.Response('Cannot GET /points-ledgers', 404);
      final id = request.url.pathSegments[1];
      return http.Response(jsonEncode({'pointsLedger': [entry('$id-1', 3)]}), 200);
    });
    final first = await Future.wait([r.fetchPointsLedger(a), r.fetchPointsLedger(b)]);
    expect(first[0].single.id, '$a-1');
    expect(first[1].single.id, '$b-1');
    expect(seen.map((q) => q.url.path), ['/points-ledgers', '/user-cards/$a/points-ledger', '/user-cards/$b/points-ledger']);
    seen.clear();
    await r.fetchPointsLedger(c);
    expect(seen.map((q) => q.url.path), ['/user-cards/$c/points-ledger'], reason: 'the batch is not retried');
  });

  test('a rejected session reaches every card as an authentication failure, as the per-card call did', () async {
    final r = repo([], (request) async => http.Response(jsonEncode({'error': 'Missing or invalid access token'}), 401));
    final calls = [r.fetchPointsLedger(a), r.fetchPointsLedger(b)];
    for (final call in calls) {
      await expectLater(call, throwsA(predicate((Object e) => isAuthenticationFailure(e))));
    }
  });

  test('a server failure reaches every card with its status, so the cached list can still be shown', () async {
    final r = repo([], (request) async => http.Response(jsonEncode({'error': 'internal_error'}), 500));
    final calls = [r.fetchPointsLedger(a), r.fetchPointsLedger(b)];
    for (final call in calls) {
      await expectLater(call, throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 500)));
    }
  });

  test('a later read is a new request (nothing is kept between reads)', () async {
    final seen = <http.Request>[];
    var version = 1;
    final r = repo(seen, (request) async => http.Response(jsonEncode({'pointsLedgers': {a: [entry('v$version', version)]}}), 200));
    expect((await r.fetchPointsLedger(a)).single.id, 'v1');
    version = 2;
    expect((await r.fetchPointsLedger(a)).single.id, 'v2');
    expect(seen, hasLength(2));
  });
}
