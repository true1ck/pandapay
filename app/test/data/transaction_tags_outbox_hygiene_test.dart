import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/transaction_tags_repository.dart';

http.Response _snapshot() =>
    http.Response(jsonEncode({'tags': [], 'assignments': []}), 200);

void main() {
  late AppDatabase db;
  late DateTime clock;
  late List<String> posted;
  late http.Response Function(http.Request) respond;
  late TransactionTagsRepository repo;

  Map<String, Object?> row(String operation) => Map.of(
    db.db
        .select('SELECT * FROM transaction_tag_outbox')
        .firstWhere(
          (r) =>
              (jsonDecode(r['payload_json'] as String) as Map)['operation'] ==
              operation,
        ),
  );

  setUp(() {
    db = openInMemoryForTesting();
    clock = DateTime(2026, 11, 13, 10);
    posted = [];
    respond = (request) =>
        request.method == 'POST' ? http.Response('{"ok":true}', 200) : _snapshot();
    repo = TransactionTagsRepository(
      database: db,
      namespace: 'user:one',
      apiBaseUrl: 'http://localhost',
      accessToken: 't',
      client: MockClient((request) async {
        if (request.method == 'POST') {
          posted.add((jsonDecode(request.body) as Map)['operation'] as String);
        }
        return respond(request);
      }),
      now: () => clock,
    );
  });
  tearDown(() {
    repo.dispose();
    db.close();
  });

  /// Queues a tag and an assignment while offline, then resets the bookkeeping
  /// the offline attempts left, so each test starts from two fresh rows.
  Future<void> queueTwo() async {
    final online = respond;
    respond = (_) => throw http.ClientException('offline');
    final tag = await repo.create('Office');
    await repo.assign(['txn'], [tag.id]);
    await repo.sync();
    respond = online;
    posted.clear();
    db.db.execute(
      'UPDATE transaction_tag_outbox SET attempts=0, next_attempt_at=0, parked=0, last_error=NULL',
    );
  }

  test('a network failure is not an attempt and ends the pass', () async {
    await queueTwo();
    respond = (_) => throw http.ClientException('offline');
    await repo.sync();
    expect(posted, hasLength(1), reason: 'not one timeout per queued row');
    final rows = db.db.select(
      'SELECT attempts, next_attempt_at, parked FROM transaction_tag_outbox',
    );
    expect(rows.map((r) => r['attempts']), [0, 0]);
    expect(rows.map((r) => r['next_attempt_at']), [0, 0]);
    expect(rows.map((r) => r['parked']), [0, 0]);
    expect(repo.lastError, isNotNull);
  });

  test('a server error counts an attempt and backs off 30 s', () async {
    await queueTwo();
    respond = (request) => request.method == 'POST'
        ? http.Response('{"error":"boom"}', 503)
        : _snapshot();
    await repo.sync();
    expect(posted, hasLength(2), reason: 'rows are independent');
    expect(row('upsert_tag')['attempts'], 1);
    expect(
      row('upsert_tag')['next_attempt_at'] as int,
      inInclusiveRange(
        clock.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
        clock.add(const Duration(seconds: 36)).millisecondsSinceEpoch,
      ),
      reason: '30 s plus up to 20 % jitter',
    );
    // Not due: a second sync sends nothing.
    posted.clear();
    await repo.sync();
    expect(posted, isEmpty);
    // Due again after the backoff.
    clock = clock.add(const Duration(seconds: 37));
    await repo.sync();
    expect(posted, hasLength(2));
    expect(row('upsert_tag')['attempts'], 2);
  });

  test('a permanent 4xx parks the row; the other row still goes', () async {
    await queueTwo();
    respond = (request) {
      if (request.method != 'POST') return _snapshot();
      final operation = (jsonDecode(request.body) as Map)['operation'];
      return operation == 'upsert_tag'
          ? http.Response('{"error":"invalid"}', 422)
          : http.Response('{"ok":true}', 200);
    };
    await repo.sync();
    expect(row('upsert_tag')['parked'], 1);
    expect(row('upsert_tag')['last_error'], contains('422'));
    expect(db.db.select('SELECT * FROM transaction_tag_outbox'), hasLength(1));
    posted.clear();
    await repo.sync();
    expect(posted, isEmpty, reason: 'a parked row is never retried by itself');
    expect(repo.pendingCount, 1, reason: 'parked rows are still unsent work');
    expect(repo.parkedCount, 1);
  });

  test('409 means try again, so it backs off instead of parking', () async {
    await queueTwo();
    respond = (request) => request.method == 'POST'
        ? http.Response('{"error":"try again"}', 409)
        : _snapshot();
    await repo.sync();
    expect(repo.parkedCount, 0);
    expect(row('upsert_tag')['attempts'], 1);
  });

  test('resetBackoff makes backed-off rows due, retryParked frees parked',
      () async {
    await queueTwo();
    respond = (request) => request.method == 'POST'
        ? http.Response('{"error":"boom"}', 500)
        : _snapshot();
    await repo.sync();
    // Make the second row a parked one.
    db.db.execute(
      'UPDATE transaction_tag_outbox SET parked=1 '
      'WHERE seq = (SELECT MAX(seq) FROM transaction_tag_outbox)',
    );
    respond = (request) =>
        request.method == 'POST' ? http.Response('{"ok":true}', 200) : _snapshot();
    posted.clear();
    await repo.sync();
    expect(posted, isEmpty, reason: 'one in backoff, one parked');

    repo.resetBackoff();
    await repo.sync();
    expect(posted, hasLength(1), reason: 'the unparked row went');

    repo.retryParked();
    expect(repo.parkedCount, 0);
    await repo.sync();
    expect(posted, hasLength(2));
    expect(repo.pendingCount, 0);
  });

  test('a parked change stays visible locally over a server snapshot', () async {
    await queueTwo();
    respond = (request) => request.method == 'POST'
        ? http.Response('{"error":"invalid"}', 400)
        : _snapshot();
    await repo.sync();
    expect(repo.parkedCount, greaterThan(0));
    expect(repo.tagsForTransaction('txn').map((t) => t.name), ['Office']);
  });

  test('the migration adds the columns to an existing tag outbox', () {
    final names = db.db
        .select('PRAGMA table_info(transaction_tag_outbox)')
        .map((r) => r['name'])
        .toSet();
    expect(names, containsAll(['attempts', 'next_attempt_at', 'parked']));
  });
}
