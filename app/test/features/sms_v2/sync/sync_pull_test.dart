import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
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
import '../support/rules.dart';

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
    'a category-only sync does not replace an existing custom display category',
    () async {
      final client = MockClient((_) async => response());
      await puller(client: client).pull();
      final row = financial.entities('target', 'transactions').single;
      database.db.execute(
        "UPDATE financial_entities SET payload=? WHERE namespace='target' AND entity='transactions' AND id=?",
        [
          jsonEncode({
            ...row,
            'category_id': null,
            'user_category_id': '10000000-0000-4000-8000-000000000001',
            'category_name': 'My category',
          }),
          row['id'],
        ],
      );
      body['facts'] = [];
      body['events'] = [];
      body['instruments'] = [];
      final entry = (body['ledger'] as List).single as Map;
      entry['category'] = 'groceries';
      entry['categorySource'] = 'shared';
      body['updatedAt'] = {
        'events': {},
        'instruments': {},
        'ledger': {entry['entryId']: '2026-11-02T00:00:00Z'},
      };
      body['cursor'] = 'category-update';
      await puller(client: client).pull();
      final after = financial.entities('target', 'transactions').single;
      expect(after['user_category_id'], '10000000-0000-4000-8000-000000000001');
      expect(after['category_id'], isNull);
      expect(after['category_name'], 'My category');
    },
  );

  test(
    'a category pulled on a purchase refreshes linked refund context',
    () async {
      bundle = testRuleBundle();
      final pipeline = SmsV2Pipeline(
        financial: financial,
        namespace: 'refund-source',
        bundle: bundle,
        appVersion: '2',
      );
      final scenario =
          jsonDecode(
                File(
                  '../tools/sms_golden/scenarios/refund_after_purchase.json',
                ).readAsStringSync(),
              )
              as Map;
      pipeline.processBatch([
        for (final (index, raw) in (scenario['messages'] as List).indexed)
          SmsMessage(
            sourceKey: '${index + 10}'.padLeft(64, '0'),
            sender: raw['sender'] as String,
            body: raw['body'] as String,
            observedAt: DateTime.parse(raw['observedAt'] as String),
          ),
      ], backfill: true);
      final queued = OutboxStore(
        database.db,
        namespace: 'refund-source',
      ).due(DateTime.utc(2027));
      List<Map<String, Object?>> kind(String name) => [
        for (final record in queued)
          if (record.kind == name) record.json,
      ];
      body['facts'] = [
        for (final source in kind('source')) ...source['facts'] as List,
      ];
      body['events'] = kind('event');
      body['instruments'] = kind('instrument');
      body['ledger'] = kind('ledger');
      body['updatedAt'] = {
        for (final name in ['events', 'instruments', 'ledger'])
          name: {
            for (final row in body[name] as List)
              row[name == 'events'
                      ? 'eventId'
                      : name == 'instruments'
                      ? 'instrumentId'
                      : 'entryId']:
                  '2026-11-04T00:00:00Z',
          },
      };
      final sentFeatures = <String?>[];
      final client = MockClient((request) async {
        sentFeatures.add(request.headers['X-Sms-Contract-Features']);
        return response();
      });
      await puller(client: client).pull();
      expect(sentFeatures, everyElement('refund-category'));
      final ledger = LedgerStore(database.db, namespace: 'target');
      final refund = EventStore(database.db, namespace: 'target')
          .listSince(DateTime.utc(2026))
          .singleWhere((event) => event.type == EventType.refund);
      expect(ledger.categoryDecisions()[refund.eventId]!.slug, 'dining');
      // CCR-003: the pulled refund row itself carries the category.
      expect(ledger.forEvent(refund.eventId).single.category, 'dining');
      final purchase = (body['ledger'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((row) => row['isSpend'] == true);
      body['ledger'] = [
        {...purchase, 'category': 'groceries', 'categorySource': 'shared'},
      ];
      body['facts'] = [];
      body['instruments'] = [];
      body['events'] = [];
      body['cursor'] = 'category-page';
      body['updatedAt'] = {
        'events': {},
        'instruments': {},
        'ledger': {purchase['entryId']: '2026-11-05T00:00:00Z'},
      };
      await puller(client: client).pull();
      expect(ledger.categoryDecisions()[refund.eventId]!.slug, 'groceries');
      expect(ledger.forEvent(refund.eventId).single.category, 'groceries');
      // An inherited user decision is still derived context. The next user
      // correction of the purchase must reach the refund too.
      for (final (day, category) in [(6, 'fuel'), (7, 'groceries')]) {
        body['ledger'] = [
          {...purchase, 'category': category, 'categorySource': 'user'},
        ];
        body['cursor'] = 'user-category-$day';
        body['updatedAt'] = {
          'events': {},
          'instruments': {},
          'ledger': {
            purchase['entryId']: DateTime.utc(2026, 11, day).toIso8601String(),
          },
        };
        await puller(client: client).pull();
        expect(ledger.categoryDecisions()[refund.eventId]!.slug, category);
      }
    },
  );

  test(
    'a second device reconstructs display once and resumes its persisted cursor',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (calls++ == 1) {
          expect(request.url.queryParameters['cursor'], 'page-1');
        }
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
    'an instrument-only rejection clears old money without ledger tombstones',
    () async {
      final client = MockClient((_) async => response());
      await puller(client: client).pull();
      final incoming = (body['instruments'] as List).single as Map;
      incoming['status'] = 'rejected';
      body['events'] = [];
      body['ledger'] = [];
      body['facts'] = [];
      body['cursor'] = 'page-rejected';
      (body['updatedAt'] as Map)['instruments'] = {
        incoming['instrumentId']: '2026-11-01T08:00:00Z',
      };
      await puller(client: client).pull();
      expect(LedgerStore(database.db, namespace: 'target').list(), isEmpty);
      expect(
        financial
            .entities('target', 'transactions')
            .every((r) => r['status'] != 'active'),
        isTrue,
      );
      // An older page replay carries ledger rows, but cannot resurrect the row.
      body['ledger'] = OutboxStore(database.db, namespace: 'source')
          .due(DateTime.utc(2026, 12))
          .where((r) => r.kind == 'ledger')
          .map((r) => r.json)
          .toList();
      await puller(client: client).pull();
      expect(LedgerStore(database.db, namespace: 'target').list(), isEmpty);
    },
  );

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
      (body['updatedAt'] as Map)['events'] = {
        event.eventId: '2026-11-01T08:00:00Z',
      };
      await puller(client: client).pull();
      expect(store.get(event.eventId)!.status, EventStatus.userConfirmed);
      expect(store.get(event.eventId)!.confidence, .8);
      (body['updatedAt'] as Map)['events'] = {
        event.eventId: '2026-11-01T07:00:00Z',
      };
      (body['events'] as List).single['confidence'] = .5;
      await puller(client: client).pull();
      expect(store.get(event.eventId)!.confidence, .8);
    },
  );
  test(
    'instrument conflict adoption rewrites child parents and personal bindings',
    () async {
      final incoming = Instrument.fromJson(
        ((body['instruments'] as List).single as Map).cast<String, Object?>(),
      );
      final oldId = generateUuidV4();
      final local = Instrument.fromJson({
        ...incoming.toJson(),
        'instrumentId': oldId,
      });
      final child = Instrument(
        instrumentId: generateUuidV4(),
        kind: InstrumentKind.debitCard,
        issuerSlug: local.issuerSlug,
        maskDigits: '9911',
        displayName: 'Synthetic child',
        status: InstrumentStatus.confirmed,
        parentInstrumentId: oldId,
        firstSeenAt: local.firstSeenAt,
        lastSeenAt: local.lastSeenAt,
        evidenceCount: 1,
      );
      final instruments = InstrumentStore(database.db, namespace: 'target');
      instruments.upsert(local);
      instruments.upsert(child);
      final queue = OutboxStore(database.db, namespace: 'target');
      queue.enqueue('instrument', oldId, local.toJson());
      queue.enqueue('instrument', child.instrumentId, child.toJson());
      SyncStateStore(database.db, namespace: 'target').put(
        'personal:rules',
        jsonEncode([
          {'instrumentId': oldId},
        ]),
      );
      await puller(client: MockClient((_) async => response())).pull();
      expect(instruments.get(oldId), isNull);
      expect(
        instruments.get(child.instrumentId)!.parentInstrumentId,
        incoming.instrumentId,
      );
      expect(
        queue
            .due(DateTime.utc(2026, 12))
            .singleWhere((r) => r.id == 'instrument:${child.instrumentId}')
            .json['parentInstrumentId'],
        incoming.instrumentId,
      );
      expect(
        (jsonDecode(
                  SyncStateStore(
                    database.db,
                    namespace: 'target',
                  ).get('personal:rules')!,
                )
                as List)
            .single['instrumentId'],
        incoming.instrumentId,
      );
    },
  );
}
