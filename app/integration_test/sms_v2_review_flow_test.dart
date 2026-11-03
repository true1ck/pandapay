// Uses only an in-memory synthetic account and a rejecting HTTP client.
// Run with --flavor dev --dart-define=SMS_PIPELINE_V2=true and the defines
// produced by tool/build_sms_v2_smoke.dart. Never launches production main().
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/flag.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/providers/data_providers.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/instrument_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/ui/found_instruments_screen.dart';
import 'package:pandapay/features/sms_v2/ui/review_inbox_screen.dart';
import 'package:pandapay_domain/sms_v2.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The emulator's accessibility service can enable semantics during startup.
  // Establish it before the test records its baseline handle count.
  binding.platformDispatcher.semanticsEnabledTestValue = true;
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);
  testWidgets(
    'synthetic import confirms accounts and resolves a grouped format',
    (tester) async {
      const encoded = String.fromEnvironment('SMS_SMOKE_BUNDLE');
      expect(
        encoded,
        isNotEmpty,
        reason: 'Run tool/build_sms_v2_smoke.dart first',
      );
      final bundle = RuleBundle.fromJson(
        (jsonDecode(encoded) as Map).cast<String, Object?>(),
      );
      const namespace = 'user:synthetic-native-sms';
      final database = AppDatabase.forTesting(sqlite3.openInMemory());
      final cache = ResponseCache(database);
      final runtime = SmsV2Runtime(
        financial: cache.financialStore,
        namespace: namespace,
        client: MockClient(
          (_) async => throw StateError('Synthetic smoke is offline'),
        ),
        baseUri: Uri.parse('https://api.invalid'),
        deviceId: 'synthetic-native',
        appVersion: '2.0.0',
        headers: () async => {},
        verify: (raw) async => raw == encoded ? bundle : null,
        loadShippedBundle: () async => encoded,
        accountIsCurrent: () => true,
        clock: () => DateTime.utc(2026, 11, 20),
      );
      final container = ProviderContainer(
        overrides: [
          smsPipelineV2EnabledProvider.overrideWithValue(true),
          app.cacheNamespaceProvider.overrideWithValue(namespace),
          app.responseCacheProvider.overrideWith((_) async => cache),
          smsV2RuntimeProvider.overrideWith((_) async => runtime),
          app.smsSharedLearningConsentProvider.overrideWith((_) async => null),
          app.catalogueProvider.overrideWith((_) async => const []),
        ],
      );
      addTearDown(() {
        container.dispose();
        cache.financialStore.dispose();
        database.db.dispose();
      });
      const body =
          'Sent Rs.250.00\nFrom HDFC Bank A/C *1797\nTo VPA 9876543210@ybl\nOn 11/05/25\nRef 412345678901 Avl Bal Rs.12,345.67';
      await runtime.capture([
        QueuedSms(
          sender: 'VM-HDFCBK-S',
          body: body,
          receivedAt: DateTime.utc(2026, 11, 1, 7),
        ),
        QueuedSms(
          sender: 'VM-HDFCBK-S',
          body: body
              .replaceFirst('250.00', '350.00')
              .replaceFirst('412345678901', '412345678902'),
          receivedAt: DateTime.utc(2026, 11, 1, 8),
        ),
      ], backfill: true);
      expect(
        InstrumentStore(database.db, namespace: namespace).list(),
        isNotEmpty,
        reason: 'Synthetic capture must detect its bank account',
      );
      expect(
        await container.read(instrumentsProvider.future),
        isNotEmpty,
        reason: 'The provider must read the captured account',
      );
      Widget screen(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: child),
      );
      await tester.pumpWidget(screen(const FoundInstrumentsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Bank accounts'), findsOneWidget);
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('sms-v2-found-accounts');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(
        InstrumentStore(database.db, namespace: namespace).list().single.status,
        InstrumentStatus.confirmed,
      );
      await tester.pumpWidget(screen(const ReviewInboxScreen()));
      await tester.pumpAndSettle();
      expect(find.text('2 messages'), findsOneWidget);
      await binding.takeScreenshot('sms-v2-review-format');
      await tester.tap(find.text('Correct'));
      await tester.pumpAndSettle();
      expect(await container.read(reviewItemsProvider.future), isEmpty);
      expect(
        LedgerStore(
          database.db,
          namespace: namespace,
        ).list().fold<int>(0, (sum, e) => sum + e.amountMinor),
        60000,
      );
      await binding.takeScreenshot('sms-v2-review-resolved');
    },
  );
}
