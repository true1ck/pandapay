import 'dart:async';
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

/// C-04 and the offline order of a sync: reading new messages never waits on
/// the network, and a phone that knows it is offline makes no network call.
void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late RuleBundle bundle;
  late String encoded;
  final now = DateTime.utc(2026, 11, 1, 7);
  const namespace = 'user:test';

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    encoded = File(
      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
    ).readAsStringSync();
    bundle = RuleBundle.fromJson(
      (jsonDecode(encoded) as Map).cast<String, Object?>(),
    );
    SmsImportStore(financial).capture(
      namespace,
      QueuedSms(
        sender: 'VM-HDFCBK-S',
        body: bundle.rules.first.examples.first.body,
        receivedAt: now,
      ),
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  int pending() => SmsIntakeRepository(db).pending(namespace).length;

  SmsV2Runtime runtime({
    required Future<Map<String, String>> Function() headers,
    required http.Client client,
    bool Function()? isOffline,
    Duration headersTimeout = const Duration(milliseconds: 50),
  }) => SmsV2Runtime(
    financial: financial,
    namespace: namespace,
    client: client,
    baseUri: Uri.parse('https://api.invalid'),
    deviceId: 'test-device',
    appVersion: '2',
    headers: headers,
    verify: (raw) async => raw == encoded ? bundle : null,
    loadShippedBundle: () async => encoded,
    accountIsCurrent: () => true,
    clock: () => now,
    isOffline: isOffline ?? () => false,
    headersTimeout: headersTimeout,
  );

  test('messages are read before the first request header is asked for, and a '
      'hanging attestation cannot hold the sync', () async {
    var pendingWhenHeadersFirstAsked = -1;
    final calls = <String>[];
    final r = runtime(
      headers: () {
        if (pendingWhenHeadersFirstAsked < 0) {
          pendingWhenHeadersFirstAsked = pending();
        }
        return Completer<Map<String, String>>().future; // never answers
      },
      client: MockClient((request) async {
        calls.add(request.url.path);
        return http.Response('', 304);
      }),
    );
    // The sync reports the failed network steps; reading must have finished.
    await expectLater(
      r.sync().timeout(const Duration(seconds: 20)),
      throwsA(anything),
    );
    expect(
      pendingWhenHeadersFirstAsked,
      0,
      reason: 'capture finished before any network step began',
    );
    expect(pending(), 0);
    expect(financial.entities(namespace, 'transactions'), hasLength(1));
    expect(calls, isEmpty, reason: 'no request was sent without headers');
  });

  test(
    'a phone that knows it is offline reads messages and calls nothing',
    () async {
      var headerCalls = 0;
      final calls = <String>[];
      final r = runtime(
        headers: () async {
          headerCalls++;
          return {'Authorization': 'Bearer fixture'};
        },
        client: MockClient((request) async {
          calls.add(request.url.path);
          return http.Response('{}', 200);
        }),
        isOffline: () => true,
      );
      await r.sync();
      expect(financial.entities(namespace, 'transactions'), hasLength(1));
      expect(pending(), 0);
      expect(calls, isEmpty);
      expect(headerCalls, 0);
    },
  );

  test('back online the waiting records are sent on the next sync', () async {
    var offline = true;
    final paths = <String>[];
    final r = runtime(
      headers: () async => {'Authorization': 'Bearer fixture'},
      isOffline: () => offline,
      client: MockClient((request) async {
        paths.add(request.url.path);
        switch (request.url.path) {
          case '/sms/v2/rules':
            return http.Response('', 304);
          case '/sms/v2/facts:batch':
            final body =
                jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))) as Map;
            return http.Response(
              jsonEncode({
                'results': [
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
                ],
              }),
              200,
            );
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
            return http.Response('{}', 202);
        }
      }),
    );
    await r.sync();
    expect(paths, isEmpty);
    offline = false;
    r.resetUploadBackoff();
    await r.sync();
    expect(paths, contains('/sms/v2/facts:batch'));
    expect(
      db.db.select('SELECT 1 FROM v2_outbox WHERE kind=?', ['source']),
      isEmpty,
    );
  });
}
