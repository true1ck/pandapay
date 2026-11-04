import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late String encoded;
  late RuleBundle bundle;
  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    encoded = File(
      '../contracts/sms/v2/fixtures/valid/bundle/full.json',
    ).readAsStringSync();
    bundle = RuleBundle.fromJson(
      (jsonDecode(encoded) as Map).cast<String, Object?>(),
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  // A server whose rules and sync endpoints are failing; metrics uploads are recorded.
  SmsV2Runtime runtime({
    required bool consent,
    required DateTime Function() clock,
    required List<Map<String, Object?>> uploads,
  }) => SmsV2Runtime(
    financial: financial,
    namespace: 'user:test',
    client: MockClient((request) async {
      switch (request.url.path) {
        case '/sms/v2/rules':
          return http.Response('{}', 500);
        case '/sms/v2/sync':
          throw const SocketException('offline');
        case '/sms/v2/client-metrics':
          uploads.add((jsonDecode(request.body) as Map).cast<String, Object?>());
          return http.Response('{"status":"recorded"}', 202);
        default:
          return http.Response('{}', 202);
      }
    }),
    baseUri: Uri.parse('https://api.invalid'),
    deviceId: 'test-device',
    appVersion: '2.1.0+3',
    headers: () async => {'Authorization': 'Bearer fixture'},
    verify: (raw) async => raw == encoded ? bundle : null,
    loadShippedBundle: () async => encoded,
    accountIsCurrent: () => true,
    hasSharingConsent: () async => consent,
    clock: clock,
  );

  Future<void> syncQuietly(SmsV2Runtime r) async {
    try {
      await r.sync();
    } catch (_) {}
  }

  int metricRows() => db.db
      .select("SELECT 1 FROM v2_sync_state WHERE key LIKE 'metrics:%'")
      .length;

  test('with consent, failing syncs and bundle downloads are reported the next day', () async {
    var now = DateTime.utc(2026, 11, 4, 9);
    final uploads = <Map<String, Object?>>[];
    final r = runtime(consent: true, clock: () => now, uploads: uploads);
    await syncQuietly(r);
    expect(uploads, isEmpty, reason: 'the current day is not sent');
    now = DateTime.utc(2026, 11, 5, 9);
    await syncQuietly(r);
    expect(uploads, hasLength(1));
    final sent = uploads.single;
    expect(sent['day'], '2026-11-04');
    expect(sent['appVersion'], '2.1.0+3');
    expect(sent['counters'], {
      'sync_attempts': 1,
      'sync_errors_network': 1,
      'bundle_download_failures': 1,
    });
    expect(sent.keys.toSet(), {'day', 'appVersion', 'counters'});
  });

  test('without consent nothing is stored or sent', () async {
    var now = DateTime.utc(2026, 11, 4, 9);
    final uploads = <Map<String, Object?>>[];
    final r = runtime(consent: false, clock: () => now, uploads: uploads);
    await syncQuietly(r);
    now = DateTime.utc(2026, 11, 5, 9);
    await syncQuietly(r);
    expect(uploads, isEmpty);
    expect(metricRows(), 0);
  });
}
