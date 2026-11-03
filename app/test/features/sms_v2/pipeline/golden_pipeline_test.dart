import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

void main() {
  final bundle = testRuleBundle();
  for (final file in Directory(
    '../tools/sms_golden/scenarios',
  ).listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    final scenario = jsonDecode(file.readAsStringSync()) as Map;
    for (final batched in [false, true]) {
      test('stored phone pipeline ${scenario['id']} batch=$batched', () {
        final db = AppDatabase.forTesting(sqlite3.openInMemory());
        final financial = FinancialStore(db);
        addTearDown(() {
          financial.dispose();
          db.db.dispose();
        });
        SmsV2Pipeline pipeline() => SmsV2Pipeline(
          financial: financial,
          namespace: 'user:golden',
          appVersion: '2.0.0',
          bundle: bundle,
        );
        pipeline();
        final seeded = resolveInstrumentsForGolden(
          facts: [],
          knownInstruments: [
            for (final known in scenario['knownInstruments'] as List? ?? [])
              (known as Map).cast<String, dynamic>(),
          ],
          bundle: bundle,
        );
        final instrumentStore = InstrumentStore(
          db.db,
          namespace: 'user:golden',
        );
        for (final known in seeded.instruments) {
          instrumentStore.upsert(Instrument.fromJson(known));
        }
        var index = 0;
        final messages = <SmsMessage>[];
        for (final json in scenario['messages'] as List) {
          final raw = json['sender'] as String;
          final message = SmsMessage(
            sender: raw,
            iosFilter: normalizeSenderBrand(raw).iosFilter,
            body: json['body'] as String,
            observedAt: DateTime.parse(json['observedAt'] as String),
            sourceKey: 'scenario:${scenario['id']}:${index++}',
          );
          messages.add(message);
        }
        if (batched) {
          expect(pipeline().processBatch(messages), messages.length);
          expect(pipeline().processBatch(messages), 0);
        } else {
          for (final message in messages) {
            // Recreate the orchestrator to verify joins use persisted context.
            expect(pipeline().process(message), isTrue);
            expect(pipeline().process(message), isFalse);
          }
        }
        final ledger = LedgerStore(db.db, namespace: 'user:golden');
        final snapshot = LedgerSnapshot(
          entries: ledger.list(),
          events: EventStore(
            db.db,
            namespace: 'user:golden',
          ).listSince(DateTime.utc(1900)),
          categoryByEvent: ledger.categoryDecisions(),
        );
        final expected = scenario['expect']['totals'] as Map;
        final totals = snapshot.totals(
          DateTime.parse(expected['from'] as String),
          DateTime.parse(expected['to'] as String),
        );
        expect(
          [
            totals.spendMinor,
            totals.incomeMinor,
            totals.investmentMinor,
            totals.transactionCount,
          ],
          [
            expected['spendMinor'],
            expected['incomeMinor'],
            expected['investmentMinor'],
            expected['transactionCount'],
          ],
        );
      });
    }
  }
}
