import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/foreign_payment.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

ForeignPayment payment(
  String key, {
  String? amount = '20',
  String? currency = 'USD',
}) => ForeignPayment(
  id: 'fx:$key',
  sourceKey: key,
  occurredAt: DateTime.utc(2026, 3, 5),
  originalCurrency: currency,
  originalAmount: amount,
  merchantName: 'Synthetic Subscription',
  valuationStatus: amount == null || currency == null
      ? 'awaiting_amount'
      : 'awaiting_rate',
);

class Service {
  final rows = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];
  String? rejectedKey;
  bool offline = false;
  Future<http.Response> call(http.Request req) async {
    requests.add(req);
    if (offline) throw http.ClientException('offline');
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;
    final path = req.url.path;
    if (path == '/foreign-payments/refresh')
      return http.Response('{"items":[]}', 200);
    if (path == '/foreign-payments' && req.method == 'GET')
      return http.Response(
        jsonEncode({'items': rows.values.toList(), 'next_cursor': null}),
        200,
      );
    if (path == '/foreign-payments' && req.method == 'POST') {
      if (body['source_key'] == rejectedKey)
        return http.Response('{"error":"temporarily_unavailable"}', 503);
      final key = body['source_key'] as String;
      rows.putIfAbsent(
        key,
        () => {
          ...body,
          'id':
              '11111111-1111-4111-8111-${(rows.length + 1).toString().padLeft(12, '0')}',
          'valuation_status':
              body['original_amount'] == null ||
                  body['original_currency'] == null
              ? 'awaiting_amount'
              : 'estimated',
          'estimated_inr': body['original_amount'] == null ? null : '1700.00',
          'rate': '85',
          'rate_date': '2026-03-05',
          'rate_source': 'Fixture',
        },
      );
      return http.Response(jsonEncode({'item': rows[key]}), 200);
    }
    final row = rows.values.firstWhere((r) => path.contains(r['id'] as String));
    row.addAll(body);
    if (path.endsWith('/confirm')) {
      row.addAll({
        'valuation_status': 'confirmed',
        'transaction_id': '22222222-2222-4222-8222-222222222222',
      });
    } else if (body['original_amount'] != null) {
      row['valuation_status'] = 'estimated';
    }
    return http.Response(jsonEncode({'item': row}), 200);
  }
}

void main() {
  late AppDatabase db;
  late Service service;
  bool current = true;
  String? token;
  ForeignPaymentsRepository repo() => ForeignPaymentsRepository(
    database: Future.value(db),
    namespace: 'user:a',
    apiBaseUrl: 'https://fixture.test',
    client: MockClient(service.call),
    accessToken: () => token,
    accountIsCurrent: () => current,
  );
  setUp(() {
    db = openInMemoryForTesting();
    service = Service();
    current = true;
    token = null;
  });
  tearDown(() => db.close());

  test(
    'offline capture is idempotent, account-scoped and never projects an INR transaction',
    () async {
      final row = payment('a' * 64);
      expect(captureLocalForeignPayment(db, 'user:a', row), isTrue);
      expect(captureLocalForeignPayment(db, 'user:a', row), isFalse);
      captureLocalForeignPayment(db, 'user:b', payment('b' * 64));
      expect(await repo().fetchAll(refresh: false), hasLength(1));
      expect(
        db.db.select(
          "SELECT name FROM sqlite_master WHERE name='financial_entities'",
        ),
        isEmpty,
      );
      expect(
        db.db.select('SELECT * FROM foreign_payments_outbox'),
        hasLength(2),
      );
    },
  );
  test(
    'durable edits and confirmation replay after restart, preserving original currency',
    () async {
      captureLocalForeignPayment(db, 'user:a', payment('a' * 64, amount: null));
      final first = repo();
      await first.editOriginal('a' * 64, currency: 'USD', amount: '21.50');
      await first.confirmBilled('a' * 64, billedInr: Money.fromRupees(1850));
      expect((await first.find('a' * 64))!.isConfirmed, isFalse);
      token = 'fixture-token';
      await repo().sync();
      final saved = (await repo().find('a' * 64))!;
      expect(saved.originalAmount, '21.50');
      expect(saved.billedInr, Money.fromRupees(1850));
      expect(saved.isConfirmed, isTrue);
      expect(db.db.select('SELECT * FROM foreign_payments_outbox'), isEmpty);
      expect(
        service.requests
            .where((r) => r.url.path.endsWith('/confirm'))
            .single
            .body,
        contains('1850.00'),
      );
      expect(service.requests.any((r) => r.body.contains('raw_sms')), isFalse);
    },
  );
  test('a rejected payment cannot block independent queued payments', () async {
    captureLocalForeignPayment(db, 'user:a', payment('a' * 64));
    captureLocalForeignPayment(db, 'user:a', payment('b' * 64));
    service.rejectedKey = 'a' * 64;
    token = 'token';
    await expectLater(repo().sync(), throwsA(anything));
    expect(service.rows.containsKey('b' * 64), isTrue);
    expect((await repo().find('a' * 64))!.syncError, isNotNull);
    expect(db.db.select('SELECT * FROM foreign_payments_outbox'), hasLength(1));
    service.rejectedKey = null;
    await repo().sync();
    expect(db.db.select('SELECT * FROM foreign_payments_outbox'), isEmpty);
  });
  test('account changes stop reads and outbound mutations', () async {
    captureLocalForeignPayment(db, 'user:a', payment('a' * 64));
    token = 'token';
    current = false;
    await repo().sync();
    expect(service.requests, isEmpty);
    expect(await repo().fetchAll(), isEmpty);
    expect(await repo().find('a' * 64), isNull);
  });
  test(
    'currency edits enforce ISO minor units before queueing a mutation',
    () async {
      captureLocalForeignPayment(db, 'user:a', payment('a' * 64));
      await expectLater(
        repo().editOriginal('a' * 64, currency: 'JPY', amount: '20.1'),
        throwsStateError,
      );
      await expectLater(
        repo().editOriginal('a' * 64, currency: 'XYZ', amount: '20'),
        throwsStateError,
      );
      await repo().editOriginal('a' * 64, currency: 'IQD', amount: '20.123');
      expect((await repo().find('a' * 64))!.originalAmount, '20.123');
    },
  );
  test(
    'historical backfill retains malformed USD price and never substitutes the available limit',
    () async {
      final intake = SmsIntakeRepository(db);
      intake.capture(
        'user:a',
        QueuedSms(
          sender: 'ICICIT-S',
          body:
              'USD .00 spent using ICICI Bank Card XX1234 on SYNTHETIC. Avl Limit: INR 286388.46.',
          receivedAt: DateTime.utc(2025, 12, 2),
        ),
      );
      expect(await repo().backfillCapturedMessages(), 1);
      final item = (await repo().fetchAll(refresh: false)).single;
      expect(item.originalCurrency, 'USD');
      expect(item.originalAmount, isNull);
      expect(item.estimatedInr, isNull);
      expect(item.billedInr, isNull);
      expect(await repo().backfillCapturedMessages(), 0);
      final wire =
          jsonDecode(
                db.db
                        .select('SELECT payload FROM foreign_payments_outbox')
                        .single['payload']
                    as String,
              )
              as Map;
      expect(wire.keys, isNot(contains('body')));
      expect(jsonEncode(wire), isNot(contains('286388.46')));
    },
  );
  test(
    'server audit advances and persists cursors instead of checking the first page forever',
    () async {
      token = 'token';
      final cursors = <String?>[];
      final client = MockClient((req) async {
        cursors.add(req.url.queryParameters['cursor']);
        return http.Response(
          jsonEncode({
            'items': [],
            'summary': {},
            'next_cursor': cursors.length == 1
                ? '11111111-1111-4111-8111-111111111111'
                : null,
          }),
          200,
        );
      });
      final r = ForeignPaymentsRepository(
        database: Future.value(db),
        namespace: 'user:a',
        apiBaseUrl: 'https://fixture.test',
        client: client,
        accessToken: () => token,
      );
      expect(await r.repairServerAmountRoles(), 0);
      expect(cursors, [null, '11111111-1111-4111-8111-111111111111']);
      await r.repairServerAmountRoles();
      expect(cursors, hasLength(2));
    },
  );
}
