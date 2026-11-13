import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/catalogue_repository.dart' show SpendCategory;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/edit_transaction_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// WP-C5: the optional bulk-review / future-rule offers never hold the edit
/// screen, and are skipped when the phone is offline.
class _Repo implements UserCardsRepository {
  _Repo(this.entry);
  final TransactionEntry entry;
  int previewCalls = 0;
  final hang = Completer<RelatedCategoryPreview>();

  @override
  Future<TransactionEntry> fetchTransaction(String id) async => entry;

  @override
  Future<RelatedCategoryPreview> fetchCategoryRelatedPreview(
    String transactionId, {
    String? categoryId,
    String? userCategoryId,
    String? targetCategoryId,
    String? targetUserCategoryId,
  }) {
    previewCalls++;
    return hang.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_Repo> _saveCategoryChange(
  WidgetTester tester, {
  required bool online,
}) async {
  tester.view.physicalSize = const Size(2400, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _Repo(
    TransactionEntry(
      id: 't1',
      amount: Money.fromRupees(100),
      occurredAt: DateTime(2026, 3, 1),
      merchantName: 'Synthetic Shop',
      source: 'manual',
      status: 'active',
    ),
  );
  final db = openInMemoryForTesting();
  addTearDown(db.close);
  final router = GoRouter(
    initialLocation: '/edit',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: Text('below')),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (context, state) => EditTransactionScreen(
              transactionId: 't1',
              initialEntry: repo.entry,
            ),
          ),
        ],
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cacheNamespaceProvider.overrideWithValue('user:test'),
        responseCacheProvider.overrideWith((ref) async => ResponseCache(db)),
        userCardsRepositoryProvider.overrideWithValue(repo),
        userCardsProvider.overrideWith((ref) async => const []),
        categoriesProvider.overrideWith(
          (ref) async => const [
            SpendCategory(id: 'cat-food', slug: 'food', name: 'Food'),
            SpendCategory(id: 'cat-fun', slug: 'fun', name: 'Fun'),
          ],
        ),
        isOnlineProvider.overrideWith((ref) => Stream.value(online)),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          ref.watch(isOnlineProvider);
          return MaterialApp.router(routerConfig: router);
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byType(DropdownButtonFormField<String>).last);
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButtonFormField<String>).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Fun').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return repo;
}

void main() {
  testWidgets('online: the screen closes at once while the offer waits on the server', (
    tester,
  ) async {
    final repo = await _saveCategoryChange(tester, online: true);
    expect(find.byType(EditTransactionScreen), findsNothing);
    expect(find.text('below'), findsOneWidget);
    expect(repo.previewCalls, 1);
    // The offer gives up after its own short limit and says so; nothing throws.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline: the offers are skipped and the screen closes', (
    tester,
  ) async {
    final repo = await _saveCategoryChange(tester, online: false);
    expect(find.byType(EditTransactionScreen), findsNothing);
    expect(repo.previewCalls, 0);
  });
}
