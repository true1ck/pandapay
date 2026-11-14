import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/import_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/import/data_export_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

const _ns = 'user:export-offline';

void main() {
  setUpAll(() => BambooFonts.useSystemFontsForTests = true);
  tearDownAll(() => BambooFonts.useSystemFontsForTests = false);

  testWidgets('export works with the network down and includes unsynced rows', (
    tester,
  ) async {
    final db = openInMemoryForTesting();
    final cache = ResponseCache(db);
    addTearDown(() {
      cache.financialStore.dispose();
      db.close();
    });
    cache.financialStore.saveProvisional(
      _ns,
      TransactionEntry(
        id: 'local-sms:k1',
        sourceKey: 'k1',
        amount: Money.fromPaise(5000),
        occurredAt: DateTime.utc(2026, 10, 15),
        merchantName: 'Offline Synthetic Shop',
        source: 'sms',
        status: 'active',
      ),
    );
    var requests = 0;
    final repo = ImportRepository(
      apiBaseUrl: 'https://example.test',
      accessToken: 't',
      client: MockClient((_) async {
        requests++;
        throw const SocketException('offline');
      }),
    );
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          responseCacheProvider.overrideWith((ref) async => cache),
          cacheNamespaceProvider.overrideWithValue(_ns),
          importRepositoryProvider.overrideWithValue(repo),
          userCardsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: DataExportScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate export'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline Synthetic Shop'), findsOneWidget);
    expect(requests, 0);
  });
}
