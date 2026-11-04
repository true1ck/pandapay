import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/ledger/providers.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/ui/found_instruments_screen.dart';
import 'package:pandapay/features/sms_v2/ui/ledger_screens.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

void main() {
  testWidgets('history replay populates all five SMS v2 screens', (
    tester,
  ) async {
    final database = AppDatabase.forTesting(sqlite3.openInMemory());
    final financial = FinancialStore(database);
    addTearDown(() {
      financial.dispose();
      database.db.dispose();
    });
    const namespace = 'user:synthetic-history';
    final bundle = testRuleBundle();
    final encoded = jsonEncode(bundle.toJson());
    final runtime = SmsV2Runtime(
      financial: financial,
      namespace: namespace,
      client: MockClient((_) async => throw StateError('Offline fixture')),
      baseUri: Uri.parse('https://api.invalid'),
      deviceId: 'history-screen-fixture',
      appVersion: '2.0.0',
      headers: () async => {},
      verify: (raw) async => raw == encoded ? bundle : null,
      loadShippedBundle: () async => encoded,
      accountIsCurrent: () => true,
    );
    final messages = <QueuedSms>[];
    for (final scenario in [
      'ipo_block_then_allotment',
      'salary_credit',
      'mandate_then_charge',
    ]) {
      final document =
          jsonDecode(
                File(
                  '../tools/sms_golden/scenarios/$scenario.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final row in document['messages'] as List) {
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
    await tester.runAsync(() => runtime.capture(messages, backfill: true));

    final db = database.db;
    final ledger = LedgerStore(db, namespace: namespace);
    final instruments = InstrumentStore(db, namespace: namespace).list();
    final model = LedgerReadModel(
      ledger: LedgerSnapshot(
        events: EventStore(
          db,
          namespace: namespace,
        ).listSince(DateTime.utc(1900)),
        entries: ledger.list(),
        categoryByEvent: ledger.categoryDecisions(),
      ),
      facts: FactStore(db, namespace: namespace).since(DateTime.utc(1900)),
      instruments: instruments,
    );

    Future<void> show(Widget screen) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            smsV2LedgerReadModelProvider.overrideWith((_) async => model),
            instrumentsProvider.overrideWith((_) async => instruments),
          ],
          child: MaterialApp(home: screen),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final (screen, evidence) in [
      (SmsLedgerScreen.investments, 'Net invested'),
      (SmsLedgerScreen.ipos, 'Blocked'),
      (SmsLedgerScreen.moneyIn, 'salary'),
      (SmsLedgerScreen.subscriptions, 'NETFLIX'),
    ]) {
      await show(SmsLedgerScreenView(screen: screen));
      expect(find.textContaining(evidence, findRichText: true), findsWidgets);
    }
    await show(const FoundInstrumentsScreen());
    expect(find.text('Bank accounts'), findsOneWidget);
    expect(find.text('Confirm'), findsWidgets);
  });
}
