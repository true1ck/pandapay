import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pandapay/app/env.dart';
import 'package:pandapay/app/providers.dart' as app;
import 'package:pandapay/features/sms_import/ios_shortcut_sms.dart';
import 'package:pandapay/features/sms_v2/providers/runtime_provider.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/sync/bundle_verifier.dart';
import 'package:pandapay/features/sms_v2/ui/found_instruments_screen.dart';
import 'package:pandapay/features/sms_v2/ui/ledger_screens.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('SMS_V2_LOCAL_ACCEPTANCE_TEST');

  testWidgets(
    'signed-in phone verifies rules, replays history and renders reports',
    (tester) async {
      expect(Env.isDev, isTrue);
      final package = await PackageInfo.fromPlatform();
      expect(package.packageName, 'app.pandapay.pandapay.smsv2rig');
      const encoded = String.fromEnvironment('SMS_V2_LOCAL_SYNTHETIC_HISTORY');
      expect(encoded, isNotEmpty);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Testing local SMS setup'))),
        ),
      );
      await tester.pumpAndSettle();
      const native = MethodChannel('pandapay/ios_sms_intake');
      var foreground = false;
      for (var attempt = 0; attempt < 100 && !foreground; attempt++) {
        foreground = await native.invokeMethod<bool>('isForeground') ?? false;
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(foreground, isTrue, reason: 'Bring the Debug app to the foreground');
      await tester.pump(const Duration(seconds: 2));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(app.sessionInitProvider.future);
      final token = container.read(app.accessTokenProvider);
      expect(token, isNotNull, reason: 'Sign in to the local rig first');
      final profile = await container
          .read(app.profileApiProvider)!
          .fetchProfile();
      expect(profile?['email'], 'test@example.com');
      await container.read(app.sessionRefreshCoordinatorProvider).refresh();
      await Future.wait([
        container.read(app.catalogueProvider.future),
        container.read(app.categoriesProvider.future),
      ]);

      final runtime = await container.read(smsV2RuntimeProvider.future);
      expect(runtime, isNotNull);
      await runtime!.sync();
      expect((await runtime.activeBundle()).bundleVersion, greaterThan(0));
      final client = container.read(app.authenticatedHttpClientProvider);
      final response = await client.get(
        Uri.parse(Env.apiBaseUrl).resolve('/sms/v2/rules?since=0'),
        headers: {
          'Authorization': 'Bearer ${container.read(app.accessTokenProvider)}',
        },
      );
      expect(response.statusCode, 200);
      final altered = jsonDecode(response.body) as Map<String, dynamic>;
      altered['bundleVersion'] = (altered['bundleVersion'] as int) + 1;
      const publicKey = String.fromEnvironment('SMS_V2_LOCAL_RULE_PUBLIC_KEY');
      final verifier = BundleVerifier(trustedKeys: {'local-rig': publicKey});
      expect(await verifier.verify(jsonEncode(altered)), isNull);

      final rows = (jsonDecode(encoded) as List)
          .map((row) => (row as Map).cast<Object?, Object?>())
          .toList();
      final batch = IosShortcutSmsBatch.fromRows(rows);
      expect(batch.messages.length, rows.length);
      await runtime.capture(batch.messages, backfill: true);
      await runtime.sync();
      final cache = await container.read(app.responseCacheProvider.future);
      final ledger = LedgerStore(
        cache.financialStore.database.db,
        namespace: container.read(app.cacheNamespaceProvider),
      );
      final before = ledger.list().map((row) => row.entryId).toSet();
      await runtime.capture(batch.messages, backfill: true);
      await runtime.sync();
      expect(ledger.list().map((row) => row.entryId).toSet(), before);
      expect(ledger.list().any((row) => row.amountMinor == 49900), isTrue);

      for (final (screen, label, evidence) in [
        (SmsLedgerScreen.investments, 'investments', 'Net invested'),
        (SmsLedgerScreen.ipos, 'ipos', 'Blocked'),
        (SmsLedgerScreen.moneyIn, 'money-in', 'salary'),
        (SmsLedgerScreen.subscriptions, 'subscriptions', 'NETFLIX'),
      ]) {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: SmsLedgerScreenView(screen: screen)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(evidence, findRichText: true), findsWidgets);
        await binding.takeScreenshot('local-rig-$label');
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: FoundInstrumentsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bank accounts'), findsOneWidget);
      await binding.takeScreenshot('local-rig-accounts');
    },
    skip: !enabled,
  );
}
