import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart';
import 'package:pandapay/data/foreign_money.dart';
import 'package:pandapay/data/foreign_payment.dart';
import 'package:pandapay/data/foreign_payments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/foreign_payments_screen.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

// Foreign amounts stated by SMS reach the Foreign payments records through the
// v2 pipeline, beside the INR ledger and never in it. Synthetic messages only.

const _ns = 'user:test';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;
  var seq = 0;

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: testRuleBundle(),
      appVersion: '2.0.0',
    );
    seq = 0;
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  test('the rule engine and the foreign payment records share one precision table', () {
    final domain = {...smsForeignCurrencyExponents}..remove(smsUnknownCurrency);
    final app = {...currencyMinorUnits}..remove('INR');
    expect(domain, app);
  });

  String key() => (++seq).toRadixString(16).padLeft(64, 'a');

  SmsMessage sms(String body, {DateTime? at, String sender = 'VM-HDFCBK-S'}) =>
      SmsMessage(
        sender: sender,
        body: body,
        sourceKey: key(),
        observedAt: at ?? DateTime.utc(2026, 11, 1, 7),
      );

  Future<List<ForeignPayment>> rows({String ns = _ns}) async {
    ensureForeignPaymentsSchema(db);
    return ForeignPaymentsRepository(
      database: Future.value(db),
      namespace: ns,
      apiBaseUrl: 'https://fixture.test',
      client: MockClient((_) async => http.Response('{}', 500)),
      accessToken: () => null,
    ).fetchAll(refresh: false);
  }

  List<Map<String, dynamic>> outbox() => [
    for (final r in db.db.select(
      'SELECT source_key,kind,payload FROM foreign_payments_outbox ORDER BY seq',
    ))
      {
        'key': r['source_key'],
        'kind': r['kind'],
        ...jsonDecode(r['payload'] as String) as Map<String, dynamic>,
      },
  ];

  int ledgerSpend() => LedgerStore(db.db, namespace: _ns)
      .list()
      .where((e) => e.isSpend)
      .fold(0, (sum, e) => sum + e.amountMinor);

  List<Map<String, dynamic>> transactions() =>
      financial.entities(_ns, 'transactions').toList();

  test('a foreign-only alert is a pending record, never INR spend', () async {
    final m = sms(
      'Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11. Avl Lmt: Rs.100000.00',
    );
    expect(pipeline.process(m), isTrue);
    expect(transactions(), isEmpty, reason: 'no INR transaction is invented');
    expect(ledgerSpend(), 0);
    final created = db.db.select('SELECT * FROM foreign_payments_local');
    expect(created, hasLength(1));
    final p = ForeignPayment.fromJson(
      jsonDecode(created.single['payload'] as String) as Map<String, dynamic>,
    );
    expect(p.sourceKey, m.sourceKey);
    expect(p.originalCurrency, 'USD');
    expect(p.originalAmount, '20');
    expect(p.valuationStatus, 'awaiting_rate');
    expect(p.billedInr, isNull);
    expect(p.estimatedInr, isNull);
    expect(p.direction, 'spend');
    expect(p.cardLast4, '1234');
    expect(p.merchantName, 'SAMPLE AI');
    expect(p.instrument, isNot('upi_bank'));
    final create = outbox().single;
    expect(create['kind'], 'create');
    expect(create.containsKey('billed_inr'), isFalse);
    expect(create['original_currency'], 'USD');
    expect(jsonEncode(create), isNot(contains('Spent USD')),
        reason: 'raw SMS text never leaves the phone');
  });

  test('processing the same message again adds nothing', () async {
    final m = sms('Spent EUR 15.50 on HDFC Bank Credit Card x1234 at SAMPLE STREAMING on 2026-11-01:07:00:11.');
    pipeline.process(m);
    expect(pipeline.process(m), isFalse);
    expect(db.db.select('SELECT * FROM foreign_payments_local'), hasLength(1));
    expect(outbox(), hasLength(1));
  });

  test('INR posted with the original counts once and is confirmed beside it', () async {
    final m = sms('Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE AI (USD 20.00) on 2026-11-01:07:00:11.');
    pipeline.process(m);
    expect(ledgerSpend(), 175000);
    expect(transactions(), hasLength(1));
    final p = db.db.select('SELECT payload FROM foreign_payments_local');
    final row = ForeignPayment.fromJson(jsonDecode(p.single['payload'] as String) as Map<String, dynamic>);
    expect(row.originalCurrency, 'USD');
    expect(row.originalAmount, '20');
    expect(row.billedInr?.paise, 175000);
    expect(row.valuationStatus, 'confirmed');
    expect(row.transactionId, transactions().single['id']);
    final create = outbox().single;
    expect(create['billed_inr'], '1750.00');
    expect(create['confirmation_source'], 'sms');
    expect(create.containsKey('transaction_id'), isFalse,
        reason: 'a local ledger id is not a server id; the server links by source key');
  });

  test('a later alert with the billed INR settles the earlier foreign-only alert', () async {
    final first = sms('Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.');
    final billed = sms(
      'Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE AI (USD 20.00) on 2026-11-03:07:00:11.',
      at: DateTime.utc(2026, 11, 3, 7),
    );
    pipeline.process(first);
    pipeline.process(billed);
    expect(ledgerSpend(), 175000, reason: 'one purchase, counted once');
    expect(transactions(), hasLength(1));
    final all = {for (final p in (await rows())) p.sourceKey: p};
    expect(all[first.sourceKey]!.valuationStatus, 'ignored');
    expect(all[billed.sourceKey]!.valuationStatus, 'confirmed');
    final edits = outbox().where((o) => o['kind'] == 'edit').toList();
    expect(edits.single['key'], first.sourceKey);
    expect(edits.single['valuation_status'], 'ignored');
  });

  test('the billed alert arriving first still settles the foreign-only one', () async {
    final billed = sms(
      'Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE AI (USD 20.00) on 2026-11-03:07:00:11.',
      at: DateTime.utc(2026, 11, 3, 7),
    );
    final late = sms('Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.');
    pipeline.processBatch([billed, late]);
    final all = {for (final p in (await rows())) p.sourceKey: p};
    expect(all[late.sourceKey]!.valuationStatus, 'ignored');
    expect(all[billed.sourceKey]!.valuationStatus, 'confirmed');
    expect(ledgerSpend(), 175000);
  });

  test('a weak match is not settled: another card, another amount, ambiguity', () async {
    final otherCard = sms('Spent USD 20.00 on HDFC Bank Card x9999 at SAMPLE AI on 2026-11-01:07:00:11.');
    final otherAmount = sms('Spent USD 21.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.');
    final billed = sms(
      'Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE AI (USD 20.00) on 2026-11-03:07:00:11.',
      at: DateTime.utc(2026, 11, 3, 7),
    );
    pipeline.processBatch([otherCard, otherAmount, billed]);
    final all = {for (final p in (await rows())) p.sourceKey: p};
    expect(all[otherCard.sourceKey]!.isPending, isTrue);
    expect(all[otherAmount.sourceKey]!.isPending, isTrue);

    final twinA = sms('Spent USD 30.00 on HDFC Bank Card x1234 at SAMPLE SHOP on 2026-11-02:07:00:11.');
    final twinB = sms('Spent USD 30.00 on HDFC Bank Card x1234 at SAMPLE SHOP on 2026-11-02:08:00:11.');
    final billed2 = sms(
      'Spent Rs.2,600.00 on HDFC Bank Card x1234 at SAMPLE SHOP (USD 30.00) on 2026-11-03:07:00:11.',
      at: DateTime.utc(2026, 11, 3, 8),
    );
    pipeline.processBatch([twinA, twinB, billed2]);
    final again = {for (final p in (await rows())) p.sourceKey: p};
    expect(again[twinA.sourceKey]!.isPending, isTrue);
    expect(again[twinB.sourceKey]!.isPending, isTrue,
        reason: 'two candidates for one purchase need review, not a guess');
  });

  test('a bare dollar sign keeps the amount and asks for the currency', () async {
    pipeline.process(sms('Txn of \$20 on Card XX1234 at SAMPLE AI approved'));
    final p = (await rows()).single;
    expect(p.originalCurrency, isNull);
    expect(p.originalAmount, '20');
    expect(p.valuationStatus, 'awaiting_amount');
    expect(p.originalLabel, 'Currency needed 20');
  });

  test('zero-decimal and three-decimal currencies keep their precision', () async {
    pipeline.process(sms('Spent JPY 1,500 on HDFC Bank Debit Card x1234 at SAMPLE SHOP on 2026-11-01:07:00:11.'));
    pipeline.process(sms('Spent KWD 3.250 on HDFC Bank Card x1234 at SAMPLE SHOP on 2026-11-02:07:00:11.'));
    final byCurrency = {for (final p in (await rows())) p.originalCurrency: p};
    expect(byCurrency['JPY']!.originalAmount, '1500');
    expect(byCurrency['JPY']!.instrument, 'debit_card');
    expect(byCurrency['KWD']!.originalAmount, '3.25');
  });

  test('foreign refunds are records, not money in', () async {
    pipeline.process(sms('Refund of USD 20.00 credited to your HDFC Bank Card x1234 from SAMPLE AI on 2026-11-02.'));
    pipeline.process(sms('Refund of INR 1750.00 (USD 25.00) credited to your HDFC Bank Credit Card x1234 from SAMPLE SAAS on 2026-11-02.'));
    final all = (await rows());
    expect(all.every((p) => p.direction == 'refund'), isTrue);
    expect(all.map((p) => p.valuationStatus).toSet(), {'awaiting_rate', 'confirmed'});
    expect(ledgerSpend(), 0);
  });

  test('a zero-value verification and a declined attempt create no record', () async {
    pipeline.process(sms('Spent USD 0.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.'));
    pipeline.process(sms('Txn of \$20 on Card XX1234 at SAMPLE AI declined'));
    expect(await rows(), isEmpty);
  });

  test('records are account scoped', () async {
    pipeline.process(sms('Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.'));
    expect((await rows()), hasLength(1));
    expect((await rows(ns: 'user:other')), isEmpty);
  });

  test('rows from v2 sync through the existing routes, create before the settling edit', () async {
    final first = sms('Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.');
    final billed = sms(
      'Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE AI (USD 20.00) on 2026-11-03:07:00:11.',
      at: DateTime.utc(2026, 11, 3, 7),
    );
    pipeline.process(first);
    pipeline.process(billed);
    final server = <String, Map<String, dynamic>>{};
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.method == 'POST' && req.url.path == '/foreign-payments') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body.keys, isNot(contains('body')));
        expect(body['source_key'], matches(RegExp(r'^[a-f0-9]{64}$')));
        final row = {
          ...body,
          'id': '11111111-1111-4111-8111-${(server.length + 1).toString().padLeft(12, '0')}',
          'valuation_status': body['billed_inr'] != null ? 'confirmed' : 'estimated',
          'estimated_inr': body['billed_inr'] == null ? '1700.00' : null,
        };
        server[body['source_key'] as String] = row;
        return http.Response(jsonEncode({'item': row}), 200);
      }
      if (req.method == 'PATCH') {
        final row = server.values.firstWhere((r) => req.url.path.endsWith(r['id'] as String));
        row.addAll(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'item': row}), 200);
      }
      if (req.method == 'GET') {
        return http.Response(jsonEncode({'items': server.values.toList(), 'next_cursor': null}), 200);
      }
      return http.Response('{"items":[]}', 200);
    });
    ensureForeignPaymentsSchema(db);
    final repository = ForeignPaymentsRepository(
      database: Future.value(db),
      namespace: _ns,
      apiBaseUrl: 'https://fixture.test',
      client: client,
      accessToken: () => 'token',
    );
    await repository.sync();
    expect(db.db.select('SELECT * FROM foreign_payments_outbox'), isEmpty);
    expect(calls.where((c) => c.startsWith('POST /foreign-payments')).length >= 2, isTrue);
    expect(calls.any((c) => c.startsWith('PATCH /foreign-payments/')), isTrue);
    final saved = {for (final p in await repository.fetchAll(refresh: false)) p.sourceKey: p};
    expect(saved[first.sourceKey]!.valuationStatus, 'ignored');
    expect(saved[billed.sourceKey]!.valuationStatus, 'confirmed');
  });

  testWidgets('the Foreign payments screen shows rows that came from v2', (tester) async {
    pipeline.process(sms('Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.'));
    pipeline.process(sms('Spent GBP 9.99 on HDFC Bank Card x1234 at SAMPLE CAFE on 2026-11-02:07:00:11.'));
    pipeline.process(sms('Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE MART (EUR 19.00) on 2026-11-02:09:00:11.'));
    final repository = ForeignPaymentsRepository(
      database: Future.value(db),
      namespace: _ns,
      apiBaseUrl: 'https://fixture.test',
      client: MockClient((_) async => http.Response('{}', 500)),
      accessToken: () => null,
    );
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          foreignPaymentsProvider.overrideWith((ref) => repository.fetchAll(refresh: false)),
          foreignPaymentsRepositoryProvider.overrideWithValue(repository),
          userCardsProvider.overrideWith((ref) async => <UserCard>[]),
          categoriesProvider.overrideWith((ref) async => const <SpendCategory>[]),
        ],
        child: const MaterialApp(home: ForeignPaymentsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SAMPLE AI'), findsOneWidget);
    expect(find.text('SAMPLE CAFE'), findsOneWidget);
    expect(find.textContaining('USD 20'), findsWidgets);
    expect(find.textContaining('GBP 9.99'), findsWidgets);
    // The confirmed EUR record is not pending; it lives under Confirmed.
    expect(find.text('SAMPLE MART'), findsNothing);
    await tester.tap(find.text('Confirmed'));
    await tester.pumpAndSettle();
    expect(find.text('SAMPLE MART'), findsOneWidget);
    expect(find.text('SAMPLE AI'), findsNothing);
  });
}

