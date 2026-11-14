import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _OfflineRepository implements UserCardsRepository {
  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? userCategoryId,
    String? source,
    String? query,
  }) async => throw const SocketException('offline');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<List<TransactionEntry>> load(ResponseCache cache, String? cardId) {
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith((ref) async => cache),
      ],
    );
    addTearDown(container.dispose);
    final loader = FutureProvider<List<TransactionEntry>>(
      (ref) => loadTransactionsWithOfflineCache(
        ref,
        repo: _OfflineRepository(),
        cacheKey: 'transactions:filtered',
        cardId: cardId,
        useReportSnapshots: false,
      ),
    );
    return container.read(loader.future);
  }

  test('offline filter with zero local matches shows empty, not an error',
      () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final probe = ProviderContainer(
      overrides: [accessTokenProvider.overrideWith((ref) => 'test-token')],
    );
    addTearDown(probe.dispose);
    final ns = probe.read(cacheNamespaceProvider);
    cache.financialStore.saveTransactions(
      ns,
      [
        TransactionEntry(
          id: 't1',
          amount: Money.fromRupees(100),
          occurredAt: DateTime(2026, 10, 1),
          source: 'manual',
          status: 'active',
          userCardId: 'card-a',
        ),
      ],
      completeQuery: const TransactionQuery(cardId: 'card-a'),
      at: DateTime(2026, 10, 2),
    );

    expect(await load(cache, 'card-b'), isEmpty);
  });

  test('a never-synced offline store still errors', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    await expectLater(
      load(ResponseCache(database), null),
      throwsA(isA<SocketException>()),
    );
  });
}
