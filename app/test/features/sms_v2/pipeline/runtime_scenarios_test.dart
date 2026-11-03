import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import '../support/rules.dart';

void main() {
  final bundle = testRuleBundle();
  final encoded = jsonEncode(bundle.toJson());
  for (final file in Directory(
    '../tools/sms_golden/scenarios',
  ).listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
    final scenario = jsonDecode(file.readAsStringSync()) as Map;
    test('real runtime intake preserves scenario ${scenario['id']}', () async {
      final database = AppDatabase.forTesting(sqlite3.openInMemory());
      final financial = FinancialStore(database);
      const ns = 'user:runtime-golden';
      addTearDown(() {
        financial.dispose();
        database.db.dispose();
      });
      final runtime = SmsV2Runtime(
        financial: financial,
        namespace: ns,
        client: MockClient((_) async => throw StateError('offline')),
        baseUri: Uri.parse('https://api.invalid'),
        deviceId: 'synthetic',
        appVersion: '2.0.0',
        headers: () async => {},
        verify: (raw) async => raw == encoded ? bundle : null,
        loadShippedBundle: () async => encoded,
        accountIsCurrent: () => true,
      );
      for (final raw in scenario['knownInstruments'] as List? ?? []) {
        InstrumentStore(database.db, namespace: ns).upsert(
          Instrument(
            instrumentId: generateUuidV4(),
            kind: InstrumentKind.fromWire(raw['kind'] as String),
            issuerSlug: raw['issuerSlug'] as String,
            maskDigits: raw['maskDigits'] as String?,
            displayName: 'Synthetic account',
            status: InstrumentStatus.confirmed,
            firstSeenAt: DateTime.utc(2026),
            lastSeenAt: DateTime.utc(2026),
            evidenceCount: 1,
          ),
        );
      }
      await runtime.capture([
        for (final raw in scenario['messages'] as List)
          QueuedSms(
            sender: raw['sender'] as String,
            body: raw['body'] as String,
            receivedAt: DateTime.parse(raw['observedAt'] as String),
          ),
      ], backfill: true);
      final snapshot = LedgerSnapshot(
        events: EventStore(
          database.db,
          namespace: ns,
        ).listSince(DateTime.utc(1900)),
        entries: LedgerStore(database.db, namespace: ns).list(),
        categoryByEvent: LedgerStore(
          database.db,
          namespace: ns,
        ).categoryDecisions(),
      );
      final expected = (scenario['expect'] as Map)['totals'] as Map;
      final totals = snapshot.totals(
        DateTime.parse(expected['from'] as String),
        DateTime.parse(expected['to'] as String),
      );
      expect(totals.spendMinor, expected['spendMinor']);
      expect(totals.incomeMinor, expected['incomeMinor']);
      expect(totals.investmentMinor, expected['investmentMinor']);
      expect(totals.transactionCount, expected['transactionCount']);
    });
  }
}
