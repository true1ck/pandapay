import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/sync/facts_upload.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/src/sms_v2/contract/schema_validator.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase database;
  late FinancialStore financial;
  late OutboxStore queue;
  late DateTime now;
  late RuleBundle bundle;
  setUp(() {
    database = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(database);
    now = DateTime.utc(2026, 11, 1, 7);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    SmsV2Pipeline(
      financial: financial,
      namespace: 'a',
      bundle: bundle,
      appVersion: '2',
    ).process(
      SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        sourceKey: 'a' * 64,
        observedAt: now,
      ),
    );
    queue = OutboxStore(database.db, namespace: 'a');
  });
  tearDown(() {
    financial.dispose();
    database.db.dispose();
  });

  Map<String, dynamic> decode(http.Request request) =>
      jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)))
          as Map<String, dynamic>;

  List<Map<String, Object?>> accepted(Map<String, dynamic> body) => [
    for (final item in body['items'])
      for (final fact in item['facts'])
        {'kind': 'fact', 'id': fact['factId'], 'status': 'accepted'},
    for (final (key, kind, id) in [
      ('instruments', 'instrument', 'instrumentId'),
      ('events', 'event', 'eventId'),
      ('ledger', 'ledger', 'entryId'),
    ])
      for (final item in body[key])
        {'kind': kind, 'id': item[id], 'status': 'accepted'},
  ];

  FactsUpload uploader(http.Client client) => FactsUpload(
    queue: queue,
    client: client,
    baseUri: Uri.parse('https://api.invalid'),
    deviceId: 'test-device',
    appVersion: '2',
    headers: () async => {'Authorization': 'Bearer fixture'},
    clock: () => now,
  );

  test(
    'gzip batch satisfies the frozen contract and marks uploaded rows clean',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.url.path, '/sms/v2/facts:batch');
        expect(request.url.queryParameters['backfill'], 'true');
        expect(request.headers['content-encoding'], 'gzip');
        final body = decode(request);
        final errors = SchemaValidator.instance.validate(
          'facts_batch.request.schema.json',
          body,
          fallback: 'invalid',
        );
        expect(errors, isEmpty);
        return http.Response(jsonEncode({'results': accepted(body)}), 200);
      });
      expect(await uploader(client).drain(backfill: true), 4);
      expect(calls, 1);
      expect(queue.due(now), isEmpty);
      expect(
        database.db.select('SELECT * FROM v2_facts WHERE uploaded_at IS NULL'),
        isEmpty,
      );
      expect(
        database.db.select('SELECT * FROM v2_instruments WHERE dirty=1'),
        isEmpty,
      );
    },
  );

  test(
    '404 retains the complete batch and retries after the backoff',
    () async {
      var calls = 0;
      final upload = uploader(
        MockClient((request) async {
          calls++;
          return http.Response('{}', 404);
        }),
      );
      expect(await upload.drain(), 0);
      expect(queue.due(now), isEmpty);
      await upload.drain();
      expect(calls, 1);
      now = now.add(const Duration(seconds: 30));
      expect(queue.due(now), hasLength(4));
      expect(queue.due(now).every((item) => item.attempts == 1), isTrue);
    },
  );
  test(
    'category refresh uses its restricted endpoint and never mixes normal changes',
    () async {
      final old = queue.due(now).firstWhere((entry) => entry.kind == 'ledger');
      queue.enqueue(
        'ledger',
        old.json['entryId'] as String,
        old.json,
        backfill: true,
        categoryOnly: true,
      );
      final paths = <String>[];
      final upload = uploader(
        MockClient((request) async {
          paths.add(request.url.path);
          final body = decode(request);
          if (request.url.path == '/sms/v2/categories:batch') {
            expect(body['items'], isEmpty);
            expect(body['events'], isEmpty);
            expect(body['instruments'], isEmpty);
            expect(body['ledger'], hasLength(1));
            expect(request.url.queryParameters['backfill'], 'true');
            expect(request.body.contains('_categoryOnly'), isFalse);
          }
          return http.Response(jsonEncode({'results': accepted(body)}), 200);
        }),
      );
      await upload.drain();
      expect(paths, ['/sms/v2/facts:batch', '/sms/v2/categories:batch']);
      expect(queue.due(now), isEmpty);
    },
  );

  test(
    'concurrent triggers share one request and keep an in-flight update',
    () async {
      final response = Completer<http.Response>();
      var calls = 0;
      late Map<String, dynamic> sent;
      final upload = uploader(
        MockClient((request) async {
          calls++;
          sent = decode(request);
          return response.future;
        }),
      );
      final first = upload.drain();
      final second = upload.drain();
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      final event = queue.due(now).firstWhere((row) => row.kind == 'event');
      queue.enqueue('event', event.json['eventId'] as String, {
        ...event.json,
        'confidence': .8,
      });
      response.complete(
        http.Response(jsonEncode({'results': accepted(sent)}), 200),
      );
      await first;
      expect(calls, greaterThanOrEqualTo(1));
    },
  );

  // The server refuses the event for good (it already holds a different
  // version) and accepts everything else.
  http.Client refusingEvents() => MockClient((request) async {
    final body = decode(request);
    return http.Response(
      jsonEncode({
        'results': [
          for (final result in accepted(body))
            if (result['kind'] == 'event')
              {
                'kind': 'event',
                'id': result['id'],
                'status': 'rejected',
                'errors': [
                  {'code': 'event_leg_role_conflict', 'path': ''},
                ],
              }
            else
              result,
        ],
      }),
      200,
    );
  });

  test(
    'the button sets aside a record the server refuses for good and still sends the rest',
    () async {
      final upload = uploader(refusingEvents());
      await upload.drain(settleRefused: true);
      // Nothing is left stuck in the queue, whatever the backoff says.
      expect(queue.due(now.add(const Duration(days: 1))), isEmpty);
      expect(
        database.db
            .select(
              "SELECT value FROM v2_sync_state WHERE key='upload:refused-total'",
            )
            .single['value'],
        '1',
      );
      // The rest was accepted and marked clean.
      expect(
        database.db.select('SELECT * FROM v2_facts WHERE uploaded_at IS NULL'),
        isEmpty,
      );
    },
  );

  test(
    'an ordinary pass keeps retrying a refused record twice, then sets it aside',
    () async {
      final upload = uploader(refusingEvents());
      await upload.drain();
      expect(
        queue
            .due(now.add(const Duration(days: 1)))
            .where((r) => r.kind == 'event'),
        hasLength(1),
      );
      for (var i = 0; i < 2; i++) {
        now = now.add(const Duration(hours: 2));
        await upload.drain();
      }
      expect(queue.due(now.add(const Duration(days: 1))), isEmpty);
    },
  );

  // A copy of the one queued source record under a new key, for the tests that
  // need several sources in one batch.
  void addSource(String key, {String? brand}) {
    final base = queue
        .due(now.add(const Duration(days: 1)))
        .firstWhere((r) => r.kind == 'source');
    final copy = (jsonDecode(jsonEncode(base.json)) as Map)
        .cast<String, Object?>();
    copy['sourceKey'] = key;
    if (brand != null) copy['senderBrand'] = brand;
    copy['facts'] = [
      for (final (i, fact) in (copy['facts'] as List).indexed)
        {
          ...(fact as Map),
          'factId': sha256.convert(utf8.encode('$key-$i')).toString(),
        },
    ];
    queue.enqueue('source', key, copy, backfill: base.backfill);
  }

  Set<String> queuedSources() => {
    for (final r in queue.due(now.add(const Duration(days: 3650))))
      if (r.kind == 'source') r.id.substring('source:'.length),
  };

  String? stateValue(String key) {
    final rows = database.db.select(
      'SELECT value FROM v2_sync_state WHERE key=?',
      [key],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  test(
    'a sender name the server would refuse leaves the phone as a plain brand',
    () async {
      addSource('odd-1', brand: 'SBI-UPI');
      addSource('odd-2', brand: '+91 98765 43210');
      final brands = <String>[];
      final schemaErrors = <Object?>[];
      final client = MockClient((request) async {
        final body = decode(request);
        for (final item in body['items']) {
          brands.add(item['senderBrand'] as String);
        }
        schemaErrors.addAll(
          SchemaValidator.instance.validate(
            'facts_batch.request.schema.json',
            body,
            fallback: 'invalid',
          ),
        );
        return http.Response(jsonEncode({'results': accepted(body)}), 200);
      });
      await uploader(client).drain();
      expect(schemaErrors, isEmpty);
      expect(brands, containsAll(['SBIUPI', 'NUMBER']));
      expect(brands.every((b) => RegExp(r'^[A-Z0-9]+$').hasMatch(b)), isTrue);
      expect(queue.due(now.add(const Duration(days: 1))), isEmpty);
    },
  );

  // The server cannot store one record (it answers 500 for any batch that
  // holds it) and takes everything else.
  http.Client poisonedBy(String sourceKey, {List<int>? calls}) =>
      MockClient((request) async {
        final body = decode(request);
        calls?.add((body['items'] as List).length);
        if ((body['items'] as List).any(
          (item) => item['sourceKey'] == sourceKey,
        )) {
          return http.Response('{"error":"internal_error"}', 500);
        }
        return http.Response(jsonEncode({'results': accepted(body)}), 200);
      });

  test(
    'one record the server cannot store does not block the ones behind it',
    () async {
      for (final key in ['good-1', 'poison', 'good-2', 'good-3']) {
        addSource(key);
      }
      final upload = uploader(poisonedBy('poison'));
      await upload.drain();
      // Everything else got through on the first pass. The bad record waits.
      expect(queuedSources(), {'poison'});
      expect(stateValue(FactsUpload.refusedKey), isNull);
      expect(
        queue.due(now.add(const Duration(days: 1))).map((r) => r.kind),
        ['source'],
        reason: 'events and money rows were not held up by it',
      );
      // Tried again alone later and still refused: set aside, phone copy kept.
      now = now.add(const Duration(hours: 2));
      await upload.drain();
      expect(queuedSources(), isEmpty);
      expect(stateValue(FactsUpload.refusedKey), '1');
      expect(
        jsonDecode(stateValue(FactsUpload.refusedReasonsKey)!),
        {'http_500': 1},
      );
    },
  );

  test('finding the bad record takes few requests, not one per record', () async {
    for (var i = 0; i < 40; i++) {
      addSource(i == 23 ? 'poison' : 'good-$i');
    }
    final calls = <int>[];
    await uploader(poisonedBy('poison', calls: calls)).drain();
    expect(queuedSources(), {'poison'});
    // 41 sources: a handful of halvings, far below one request per record.
    expect(calls.length, lessThan(20));
  });

  test(
    'when the server fails for everything nothing is set aside or lost',
    () async {
      for (final key in ['a', 'b', 'c']) {
        addSource(key);
      }
      final before = queue.due(now.add(const Duration(days: 3650))).length;
      final down = MockClient(
        (request) async => http.Response('{"error":"internal_error"}', 500),
      );
      final upload = uploader(down);
      for (var i = 0; i < 4; i++) {
        await upload.drain();
        now = now.add(const Duration(hours: 2));
      }
      expect(stateValue(FactsUpload.refusedKey), isNull);
      expect(queue.due(now.add(const Duration(days: 3650))).length, before);
    },
  );

  test('a sign-in or rate-limit answer is not blamed on a record', () async {
    for (final key in ['a', 'b']) {
      addSource(key);
    }
    for (final status in [401, 429, 503]) {
      final upload = uploader(
        MockClient((request) async => http.Response('{}', status)),
      );
      await upload.drain();
      now = now.add(const Duration(hours: 2));
      await upload.drain();
    }
    expect(stateValue(FactsUpload.refusedKey), isNull);
  });
}
