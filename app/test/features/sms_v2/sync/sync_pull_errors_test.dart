// A pull the server does not answer with 200 used to end with no trace: nothing for the phone details to show and no
// wait after a 429. Every name and number here is invented; the clock is fixed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

void main() {
  late AppDatabase database;
  late SyncStateStore state;
  var now = DateTime.utc(2026, 11, 20, 10);
  var requests = 0;
  late http.Response Function() answer;

  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    state = SyncStateStore(database.db, namespace: 'n');
    now = DateTime.utc(2026, 11, 20, 10);
    requests = 0;
  });
  tearDown(() => database.db.dispose());

  SyncPull puller() => SyncPull(
    financial: FinancialStore(database),
    namespace: 'n',
    client: MockClient((request) async {
      requests++;
      return answer();
    }),
    baseUri: Uri.parse('https://api.invalid'),
    headers: () async => {},
    bundle: testRuleBundle(),
    clock: () => now,
  );

  Map<String, Object?> problem() => (jsonDecode(state.get('pull:error')!) as Map).cast<String, Object?>();

  test('a 503 with the server\'s error code is recorded for the phone details', () async {
    answer = () => http.Response('{"error":"sync_unavailable"}', 503);
    expect(await puller().pull(), 0, reason: 'the callers still see a quiet no-pages');
    expect(problem()['type'], 'SyncHttpStatus');
    expect(problem()['message'], allOf(contains('503'), contains('sync_unavailable')));
    expect(problem()['at'], now.toIso8601String());
    expect(state.get('pull:wait'), isNull, reason: 'only a 429 holds the next pull');
  });

  test('a body that is not JSON still records the status', () async {
    answer = () => http.Response('<html>bad gateway</html>', 502);
    await puller().pull();
    expect(problem()['message'], allOf(contains('502'), isNot(contains('html'))));
  });

  test('a 429 holds the next pull for the Retry-After, clamped to 30 s to 1 h', () async {
    final up = puller();
    for (final (header, seconds) in [('5', 30), ('300', 300), ('86400', 3600), (null, 60)]) {
      database.db.execute("DELETE FROM v2_sync_state WHERE key='pull:wait'");
      answer = () => http.Response('{"error":"rate_limited"}', 429, headers: {'retry-after': ?header});
      await up.pull();
      expect(DateTime.parse(state.get('pull:wait')!), now.add(Duration(seconds: seconds)), reason: 'Retry-After $header');
    }
    expect(problem()['message'], contains('429'));
  });

  test('while the hold lasts no request is sent; afterwards a good pull clears the hold and the problem', () async {
    answer = () => http.Response('', 429, headers: {'retry-after': '120'});
    final up = puller();
    await up.pull();
    expect(requests, 1);
    now = now.add(const Duration(seconds: 119));
    await up.pull();
    expect(requests, 1, reason: 'still held');
    now = now.add(const Duration(seconds: 2));
    answer = () => http.Response(
      jsonEncode({
        'cursor': 'c1',
        'facts': <Object?>[],
        'instruments': <Object?>[],
        'events': <Object?>[],
        'ledger': <Object?>[],
        'aiResults': <Object?>[],
        'corrections': <Object?>[],
        'latestBundleVersion': 1,
        'updatedAt': {'events': {}, 'instruments': {}, 'ledger': {}},
      }),
      200,
    );
    expect(await up.pull(), 1);
    expect(requests, 2);
    expect(state.get('pull:wait'), isNull);
    expect(state.get('pull:error'), isNull);
  });

  test('a 401 is left to the shared client: no record, no hold', () async {
    answer = () => http.Response('{"error":"unauthorized"}', 401);
    await puller().pull();
    expect(state.get('pull:error'), isNull);
    expect(state.get('pull:wait'), isNull);
  });
}
