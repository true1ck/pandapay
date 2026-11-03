import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';
import 'dart:convert';

void main() {
  test(
    '20,000 stored messages process within the import budget',
    () async {
      final database = AppDatabase.forTesting(sqlite3.openInMemory());
      final financial = FinancialStore(database);
      addTearDown(() {
        financial.dispose();
        database.db.dispose();
      });
      final bundle = testRuleBundle();
      final encoded = jsonEncode(bundle.toJson());
      final runtime = SmsV2Runtime(
        financial: financial,
        namespace: 'user:benchmark',
        client: MockClient(
          (request) async => throw StateError('Offline benchmark'),
        ),
        baseUri: Uri.parse('https://api.invalid'),
        deviceId: 'benchmark-device',
        appVersion: '2',
        headers: () async => {},
        verify: (value) async => value == encoded ? bundle : null,
        loadShippedBundle: () async => encoded,
        accountIsCurrent: () => true,
        clock: () => DateTime.utc(2026, 11, 30),
      );
      final messages = [
        for (var index = 0; index < 20000; index++)
          QueuedSms(
            sender: 'VM-HDFCBK-S',
            body:
                'Rs.${index + 1}.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-01:12:30:11. Avl Lmt: Rs.45,000.00',
            receivedAt: DateTime.utc(
              2026,
              11,
              1,
              7,
            ).add(Duration(minutes: index)),
          ),
      ];
      final watch = Stopwatch()..start();
      await runtime.capture(messages, backfill: true);
      watch.stop();
      final count = database.db
          .select('SELECT COUNT(*) AS n FROM v2_facts')
          .single['n'];
      expect(count, greaterThanOrEqualTo(20000));
      expect(
        financial.entities('user:benchmark', 'transactions'),
        hasLength(20000),
      );
      print(
        'SMS v2 desktop history benchmark: ${watch.elapsedMilliseconds} ms for 20,000 messages',
      );
      expect(watch.elapsed, lessThan(const Duration(minutes: 2)));
    },
    skip: !const bool.fromEnvironment('SMS_V2_BENCHMARK'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
