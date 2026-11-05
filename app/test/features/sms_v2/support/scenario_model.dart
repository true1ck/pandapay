import 'dart:convert';
import 'dart:io';

import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart' show TransactionEntry;
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import 'rules.dart';

/// Replays golden scenarios (messages merged in time order) through the real
/// [SmsV2Runtime] and returns the read model the product screens consume.
/// Call inside `tester.runAsync` in widget tests.
Future<LedgerReadModel> replayScenarios(
  List<String> names, {
  List<QueuedSms> extra = const [],
}) async {
  final database = AppDatabase.forTesting(sqlite3.openInMemory());
  final financial = FinancialStore(database);
  const ns = 'user:lane-v';
  final bundle = testRuleBundle();
  final encoded = jsonEncode(bundle.toJson());
  final runtime = SmsV2Runtime(
    financial: financial,
    namespace: ns,
    client: MockClient((_) async => throw StateError('offline')),
    baseUri: Uri.parse('https://api.invalid'),
    deviceId: 'lane-v',
    appVersion: '2.0.0',
    headers: () async => {},
    verify: (raw) async => raw == encoded ? bundle : null,
    loadShippedBundle: () async => encoded,
    accountIsCurrent: () => true,
  );
  final messages = <QueuedSms>[...extra];
  final known = <String, Map>{};
  for (final name in names) {
    final doc =
        jsonDecode(
              File(
                '../tools/sms_golden/scenarios/$name.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final raw in (doc['knownInstruments'] as List? ?? []).cast<Map>()) {
      known['${raw['kind']}|${raw['issuerSlug']}|${raw['maskDigits']}'] = raw;
    }
    for (final row in (doc['messages'] as List).cast<Map>()) {
      messages.add(
        QueuedSms(
          sender: row['sender'] as String,
          body: row['body'] as String,
          receivedAt: DateTime.parse(row['observedAt'] as String),
        ),
      );
    }
  }
  messages.sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
  for (final raw in known.values) {
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
  await runtime.capture(messages, backfill: true);
  final ledger = LedgerStore(database.db, namespace: ns);
  final model = LedgerReadModel(
    ledger: LedgerSnapshot(
      events: EventStore(
        database.db,
        namespace: ns,
      ).listSince(DateTime.utc(1900)),
      entries: ledger.list(),
      categoryByEvent: ledger.categoryDecisions(),
    ),
    facts: FactStore(database.db, namespace: ns).since(DateTime.utc(1900)),
    instruments: InstrumentStore(database.db, namespace: ns).list(),
    transactions: financial
        .entities(ns, 'transactions')
        .map(TransactionEntry.fromJson)
        .toList(),
  );
  financial.dispose();
  database.db.dispose();
  return model;
}
