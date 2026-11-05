import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
}
