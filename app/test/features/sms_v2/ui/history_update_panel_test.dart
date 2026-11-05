import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/ui/history_update_panel.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

void main() {
  testWidgets(
    'opening and previewing history require a separate apply confirmation',
    (tester) async {
      final database = AppDatabase.forTesting(sqlite3.openInMemory());
      final financial = FinancialStore(database);
      addTearDown(() {
        financial.dispose();
        database.db.dispose();
      });
      const namespace = 'user:history-panel';
      final original = testRuleBundle();
      SmsV2Pipeline(
        financial: financial,
        namespace: namespace,
        bundle: original,
        appVersion: '2.0.0',
      ).process(
        SmsMessage(
          sourceKey: 'a' * 64,
          sender: 'VM-HDFCBK-S',
          body:
              'Sent Rs.499.00 From HDFC Bank A/C **1797 to SWIGGY UPI on 10-10-26. Avl Bal Rs.12,345.67',
          observedAt: DateTime.utc(2026, 10, 10),
        ),
        backfill: true,
      );
      final json = original.toJson();
      json['categoryRules'] = [
        {
          'merchantKey': 'SWIGGY',
          'match': 'token',
          'senders': ['*'],
          'context': [],
          'source': 'shared',
          'priority': 9999,
          'category': 'groceries',
        },
      ];
      final revised = RuleBundle.fromJson(json);
      final client = MockClient(
        (_) async => throw StateError('This action is local'),
      );
      addTearDown(client.close);
      final runtime = SmsV2Runtime(
        financial: financial,
        namespace: namespace,
        client: client,
        baseUri: Uri.parse('https://local.invalid'),
        deviceId: 'history-panel-device',
        appVersion: '2.0.0',
        headers: () async => {},
        verify: (_) async => revised,
        loadShippedBundle: () async => jsonEncode(revised.toJson()),
        accountIsCurrent: () => true,
      );
      var applied = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            app.cacheNamespaceProvider.overrideWithValue(namespace),
            smsV2RuntimeProvider.overrideWith((_) async => runtime),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HistoryUpdatePanel(onApplied: () => applied = true),
              ),
            ),
          ),
        ),
      );
      final ledger = LedgerStore(database.db, namespace: namespace);
      database.db.execute('DELETE FROM v2_outbox');
      final before = ledger.list().single.category;
      expect(applied, isFalse);
      await tester.tap(find.text('Preview history check'));
      await tester.pumpAndSettle();
      expect(find.text('1 automatic categories change'), findsOneWidget);
      expect(ledger.list().single.category, before);
      await tester.ensureVisible(find.text('Apply history check'));
      await tester.tap(find.text('Apply history check'));
      await tester.pumpAndSettle();
      expect(find.text('Apply this history check?'), findsOneWidget);
      expect(ledger.list().single.category, before);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(applied, isTrue);
      expect(ledger.list().single.category, 'groceries');
    },
  );
}
