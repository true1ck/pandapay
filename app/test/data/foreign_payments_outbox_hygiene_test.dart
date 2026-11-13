import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/foreign_payment.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';

ForeignPayment payment(String key, {String? amount = '20'}) => ForeignPayment(
  id: 'fx:$key',
  sourceKey: key,
  occurredAt: DateTime.utc(2026, 3, 5),
  originalCurrency: amount == null ? null : 'USD',
  originalAmount: amount,
  merchantName: 'Synthetic Subscription',
  valuationStatus: amount == null ? 'awaiting_amount' : 'awaiting_rate',
);

/// A tiny fake of the foreign-payments service: creates succeed unless the
/// source key has a forced status; everything else is accepted.
class _Service {
  final rows = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];
  final statusByKey = <String, int>{};
  bool offline = false;

  Future<http.Response> call(http.Request req) async {
    requests.add(req);
    if (offline) throw http.ClientException('offline');
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;
    final path = req.url.path;
    if (path == '/foreign-payments/refresh') {
      return http.Response('{"items":[]}', 200);
    }
    if (path == '/foreign-payments' && req.method == 'GET') {
      return http.Response(
        jsonEncode({'items': rows.values.toList(), 'next_cursor': null}),
        200,
      );
    }
    if (path == '/foreign-payments' && req.method == 'POST') {
      final forced = statusByKey[body['source_key']];
      if (forced != null) return http.Response('{"error":"forced"}', forced);
      final key = body['source_key'] as String;
      rows.putIfAbsent(
        key,
        () => {
          ...body,
          'id':
              '11111111-1111-4111-8111-${(rows.length + 1).toString().padLeft(12, '0')}',
          'valuation_status': 'estimated',
          'estimated_inr': '1700.00',
          'rate': '85',
          'rate_date': '2026-03-05',
          'rate_source': 'Fixture',
        },
      );
      return http.Response(jsonEncode({'item': rows[key]}), 200);
    }
    final row = rows.values.firstWhere((r) => path.contains(r['id'] as String));
    row.addAll(body);
    return http.Response(jsonEncode({'item': row}), 200);
  }

  int get posts => requests
      .where((r) => r.method == 'POST' && r.url.path == '/foreign-payments')
      .length;
}

void main() {
  late AppDatabase db;
  late _Service service;
  var clock = DateTime(2026, 11, 13, 10);

  ForeignPaymentsRepository repo() => ForeignPaymentsRepository(
    database: Future.value(db),
    namespace: 'user:a',
    apiBaseUrl: 'https://fixture.test',
    client: MockClient(service.call),
    accessToken: () => 'token',
    now: () => clock,
  );

  Map<String, Object?> row(String key) => Map.of(
    db.db
        .select(
          'SELECT * FROM foreign_payments_outbox WHERE source_key=? ORDER BY seq',
          [key],
        )
        .first,
  );

  Future<void> syncQuietly(ForeignPaymentsRepository r) =>
      r.sync().catchError((Object _) {});

  setUp(() {
    db = openInMemoryForTesting();
    service = _Service();
    clock = DateTime(2026, 11, 13, 10);
  });
  tearDown(() => db.close());

  test('a network failure is not an attempt and ends the pass', () async {
    for (final k in ['a', 'b', 'c']) {
      captureLocalForeignPayment(db, 'user:a', payment(k * 64));
    }
    service.offline = true;
    await syncQuietly(repo());
    final posts = service.requests
        .where((r) => r.method == 'POST' && r.url.path == '/foreign-payments')
        .length;
    expect(posts, 1, reason: 'one request, not one timeout per row');
    final rows = db.db.select(
      'SELECT attempts, next_attempt_at, parked FROM foreign_payments_outbox',
    );
    expect(rows, hasLength(3));
    expect(
      rows.every(
        (r) =>
            r['attempts'] == 0 && r['next_attempt_at'] == 0 && r['parked'] == 0,
      ),
      isTrue,
    );
  });

  test('a server error counts an attempt and backs off 30 s', () async {
    captureLocalForeignPayment(db, 'user:a', payment('a' * 64));
    service.statusByKey['a' * 64] = 503;
    await syncQuietly(repo());
    expect(row('a' * 64)['attempts'], 1);
    expect(
      row('a' * 64)['next_attempt_at'],
      clock.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
    );
    final before = service.posts;
    await syncQuietly(repo());
    expect(service.posts, before, reason: 'not due yet');
    clock = clock.add(const Duration(seconds: 31));
    await syncQuietly(repo());
    expect(service.posts, before + 1);
    expect(row('a' * 64)['attempts'], 2);
  });

  test('a permanent 4xx parks the change, never retried by itself', () async {
    captureLocalForeignPayment(db, 'user:a', payment('a' * 64));
    captureLocalForeignPayment(db, 'user:a', payment('b' * 64));
    service.statusByKey['a' * 64] = 422;
    await syncQuietly(repo());
    expect(row('a' * 64)['parked'], 1);
    expect(
      service.rows.containsKey('b' * 64),
      isTrue,
      reason: 'the independent payment still goes',
    );
    final before = service.posts;
    clock = clock.add(const Duration(days: 1));
    await syncQuietly(repo());
    expect(service.posts, before);
    expect(await repo().parkedCount(), 1);
    // The payment still shows its local state with a sync note.
    expect((await repo().find('a' * 64))!.syncError, isNotNull);

    service.statusByKey.clear();
    await repo().retryParked();
    await repo().sync();
    expect(db.db.select('SELECT * FROM foreign_payments_outbox'), isEmpty);
  });

  test('409 needs review: it backs off instead of parking', () async {
    captureLocalForeignPayment(db, 'user:a', payment('a' * 64));
    service.statusByKey['a' * 64] = 409;
    await syncQuietly(repo());
    expect(row('a' * 64)['parked'], 0);
    expect(row('a' * 64)['attempts'], 1);
  });

  test('a later edit waits behind an earlier parked change of the same payment',
      () async {
    captureLocalForeignPayment(db, 'user:a', payment('a' * 64, amount: null));
    final r = repo();
    service.statusByKey['a' * 64] = 422;
    // The edit syncs straight away: the create is refused and parked, and the
    // edit stays queued behind it.
    await r
        .editOriginal('a' * 64, currency: 'USD', amount: '21.50')
        .catchError((Object _) => payment('a' * 64));
    expect(row('a' * 64)['parked'], 1);
    expect(db.db.select('SELECT * FROM foreign_payments_outbox'), hasLength(2));
    final before = service.requests.length;
    service.statusByKey.clear();
    await syncQuietly(r);
    expect(
      service.requests
          .skip(before)
          .where(
            (q) =>
                q.method == 'PATCH' && q.url.path.startsWith('/foreign-payments/'),
          ),
      isEmpty,
      reason: 'the edit must not overtake the parked create',
    );
  });

  test('hasDueChanges is false for empty, parked and backed-off outboxes', () async {
    expect(await repo().hasDueChanges(), isFalse);
    captureLocalForeignPayment(db, 'user:a', payment('a' * 64));
    expect(await repo().hasDueChanges(), isTrue);
    service.statusByKey['a' * 64] = 503;
    await syncQuietly(repo());
    expect(await repo().hasDueChanges(), isFalse, reason: 'backing off');
    clock = clock.add(const Duration(minutes: 1));
    expect(await repo().hasDueChanges(), isTrue);
    service.statusByKey['a' * 64] = 422;
    await syncQuietly(repo());
    expect(await repo().hasDueChanges(), isFalse, reason: 'parked');
  });

  test('resetBackoff makes backed-off changes due again', () async {
    captureLocalForeignPayment(db, 'user:a', payment('a' * 64));
    service.statusByKey['a' * 64] = 503;
    await syncQuietly(repo());
    service.statusByKey.clear();
    await syncQuietly(repo());
    expect(db.db.select('SELECT * FROM foreign_payments_outbox'), hasLength(1));
    await repo().resetBackoff();
    await repo().sync();
    expect(db.db.select('SELECT * FROM foreign_payments_outbox'), isEmpty);
  });

  test('a table created before the retry columns is upgraded', () async {
    final legacy = openInMemoryForTesting();
    addTearDown(legacy.close);
    legacy.db.execute('''
      CREATE TABLE foreign_payments_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, namespace TEXT NOT NULL,
        source_key TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL,
        last_error TEXT)''');
    legacy.db.execute(
      "INSERT INTO foreign_payments_outbox(namespace,source_key,kind,payload) VALUES('user:a','k','create','{}')",
    );
    ensureForeignPaymentsSchema(legacy);
    final columns = legacy.db
        .select('PRAGMA table_info(foreign_payments_outbox)')
        .map((r) => r['name'])
        .toSet();
    expect(columns, containsAll(['attempts', 'next_attempt_at', 'parked']));
    final kept = legacy.db
        .select('SELECT * FROM foreign_payments_outbox')
        .single;
    expect([kept['attempts'], kept['next_attempt_at'], kept['parked']], [
      0,
      0,
      0,
    ]);
  });
}
