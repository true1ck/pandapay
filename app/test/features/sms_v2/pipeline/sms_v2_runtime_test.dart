import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'foreground drains deferred intake through only the v2 endpoints',
    () async {
      final db = AppDatabase.forTesting(sqlite3.openInMemory());
      final financial = FinancialStore(db);
      addTearDown(() {
        financial.dispose();
        db.db.dispose();
      });
      final encoded = File(
        '../contracts/sms/v2/fixtures/valid/bundle/full.json',
      ).readAsStringSync();
      final bundle = RuleBundle.fromJson(
        (jsonDecode(encoded) as Map).cast<String, Object?>(),
      );
      final now = DateTime.utc(2026, 11, 1, 7);
      final sms = QueuedSms(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        receivedAt: now,
      );
      SmsImportStore(financial).capture('user:test', sms);
      expect(SmsIntakeRepository(db).pending('user:test'), hasLength(1));
      final paths = <String>[];
      final runtime = SmsV2Runtime(
        financial: financial,
        namespace: 'user:test',
        client: MockClient((request) async {
          paths.add(request.url.path);
          switch (request.url.path) {
            case '/sms/v2/rules':
              return http.Response('', 304);
            case '/sms/v2/facts:batch':
              final body =
                  jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)))
                      as Map;
              final results = [
                for (final item in body['items'])
                  for (final fact in item['facts'])
                    {
                      'kind': 'fact',
                      'id': fact['factId'],
                      'status': 'accepted',
                    },
                for (final (key, kind, id) in [
                  ('instruments', 'instrument', 'instrumentId'),
                  ('events', 'event', 'eventId'),
                  ('ledger', 'ledger', 'entryId'),
                ])
                  for (final row in body[key])
                    {'kind': kind, 'id': row[id], 'status': 'accepted'},
              ];
              return http.Response(jsonEncode({'results': results}), 200);
            case '/sms/v2/rule-stats:batch':
              return http.Response('{}', 202);
            case '/sms/v2/sync':
              return http.Response(
                jsonEncode({
                  'cursor': 'one',
                  'instruments': [],
                  'events': [],
                  'ledger': [],
                  'facts': [],
                  'aiResults': [],
                  'corrections': [],
                  'latestBundleVersion': 1,
                }),
                200,
              );
            default:
              fail('Legacy endpoint was called: ${request.url.path}');
          }
        }),
        baseUri: Uri.parse('https://api.invalid'),
        deviceId: 'test-device',
        appVersion: '2',
        headers: () async => {'Authorization': 'Bearer fixture'},
        verify: (raw) async => raw == encoded ? bundle : null,
        loadShippedBundle: () async => encoded,
        accountIsCurrent: () => true,
        clock: () => now,
      );
      await runtime.sync();
      expect(
        financial
            .entities('user:test', 'transactions')
            .single['pipeline_version'],
        2,
      );
      expect(SmsIntakeRepository(db).pending('user:test'), isEmpty);
      expect(paths, [
        '/sms/v2/rules',
        '/sms/v2/facts:batch',
        '/sms/v2/rule-stats:batch',
        '/sms/v2/sync',
      ]);
      await runtime.sync();
      expect(paths.where((path) => path == '/sms/v2/rules'), hasLength(1));
    },
  );
}
