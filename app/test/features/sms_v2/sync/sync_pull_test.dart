import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/sync_state_store.dart';
import 'package:pandapay/features/sms_v2/sync/sync_pull.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late RuleBundle bundle;
  late Map<String, Object?> body;
  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    final pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: 'source',
      bundle: bundle,
      appVersion: '2',
    );
    pipeline.process(
      SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        sourceKey: 'a' * 64,
        observedAt: DateTime.utc(2026, 11, 1, 7),
      ),
    );
    final queue = OutboxStore(database.db, namespace: 'source');
    final rows = queue.due(DateTime.utc(2026, 12));
    List<Map<String, Object?>> kind(String kind) => [
      for (final row in rows)
        if (row.kind == kind) row.json,
    ];
    body = {
      'cursor': 'page-1',
      'facts': [for (final item in kind('source')) ...item['facts'] as List],
      'instruments': kind('instrument'),
      'events': kind('event'),
      'ledger': kind('ledger'),
      'aiResults': <Object?>[],
      'corrections': <Object?>[],
      'latestBundleVersion': 1,
      'updatedAt': {
        'events': {
          for (final event in kind('event'))
            event['eventId']: '2026-11-01T07:01:00Z',
        },
        'instruments': {
          for (final instrument in kind('instrument'))
            instrument['instrumentId']: '2026-11-01T07:01:00Z',
        },
        'ledger': {
          for (final entry in kind('ledger'))
            entry['entryId']: '2026-11-01T07:01:00Z',
        },
      },
    };
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  SyncPull puller({required http.Client client, String namespace = 'target'}) =>
      SyncPull(
        financial: financial,
        namespace: namespace,
        client: client,
        baseUri: Uri.parse('https://api.invalid'),
        headers: () async => {},
        bundle: bundle,
      );
  http.Response response() => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  test(
    'a second device reconstructs display once and resumes its persisted cursor',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (calls++ == 1)
          expect(request.url.queryParameters['cursor'], 'page-1');
        return response();
      });
      await puller(client: client).pull();
      expect(financial.entities('target', 'transactions'), hasLength(1));
      expect(
        LedgerStore(database.db, namespace: 'target').list().single.amountMinor,
        49900,
      );
      await puller(client: client).pull();
      expect(financial.entities('target', 'transactions'), hasLength(1));
      expect(
        SyncStateStore(database.db, namespace: 'target').get('pull:cursor'),
        'page-1',
      );
      expect(financial.entities('another', 'transactions'), isEmpty);
      expect(
        OutboxStore(
          database.db,
          namespace: 'target',
        ).due(DateTime.utc(2026, 12)),
        isEmpty,
      );
    },
  );

  test('failed display projection rolls back entities and cursor', () async {
    database.db.execute(
      "CREATE TRIGGER reject_sync_projection BEFORE INSERT ON financial_entities WHEN NEW.namespace='target' AND NEW.entity='transactions' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    );
    await expectLater(
      puller(client: MockClient((_) async => response())).pull(),
      throwsA(isA<SqliteException>()),
    );
    expect(
      SyncStateStore(database.db, namespace: 'target').get('pull:cursor'),
      isNull,
    );
    expect(
      database.db.select("SELECT * FROM v2_facts WHERE namespace='target'"),
      isEmpty,
    );
  });

  test(
    'pending local edits survive ordinary pulls while server user confirmation wins',
    () async {
      final client = MockClient((_) async => response());
      await puller(client: client).pull();
      final store = EventStore(database.db, namespace: 'target');
      final event = store.listSince(DateTime.utc(1900)).single;
      store.upsert(event.copyWith(confidence: .7));
      (body['events'] as List).single['confidence'] = .8;
      await puller(client: client).pull();
      expect(store.get(event.eventId)!.confidence, .7);
      (body['events'] as List).single['status'] = 'user_confirmed';
      await puller(client: client).pull();
      expect(store.get(event.eventId)!.status, EventStatus.userConfirmed);
      expect(store.get(event.eventId)!.confidence, .8);
    },
  );
}
