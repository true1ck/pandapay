import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/settings/data_storage_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

const _ns = 'user:storage-count';

void main() {
  setUpAll(() => BambooFonts.useSystemFontsForTests = true);
  tearDownAll(() => BambooFonts.useSystemFontsForTests = false);

  testWidgets('record count comes from the local store with no repository', (
    tester,
  ) async {
    final db = openInMemoryForTesting();
    final cache = ResponseCache(db);
    addTearDown(() {
      cache.financialStore.dispose();
      db.close();
    });
    cache.financialStore.saveTransactions(_ns, [
      for (var i = 0; i < 3; i++)
        TransactionEntry(
          id: 't$i',
          amount: Money.fromPaise(100),
          occurredAt: DateTime.utc(2026, 10, 1 + i),
          source: 'sms',
          status: 'active',
        ),
    ]);
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          responseCacheProvider.overrideWith((ref) async => cache),
          cacheNamespaceProvider.overrideWithValue(_ns),
          accessTokenProvider.overrideWith((ref) => 'synthetic-token'),
          // Signed out of the server path entirely: a fetch would return 0.
          userCardsRepositoryProvider.overrideWithValue(null),
          userCardsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: DataStorageScreen()),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('3 transactions'), findsOneWidget);
  });
}
