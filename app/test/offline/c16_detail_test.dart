import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/transaction_detail_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _HangingRepository implements UserCardsRepository {
  @override
  Future<TransactionEntry> fetchTransaction(String id) =>
      Completer<TransactionEntry>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('detail shows the saved row without waiting for a slow server',
      () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith((ref) async => cache),
        userCardsRepositoryProvider.overrideWithValue(_HangingRepository()),
      ],
    );
    addTearDown(container.dispose);
    final ns = container.read(cacheNamespaceProvider);
    cache.financialStore.saveTransactions(
      ns,
      [
        TransactionEntry(
          id: 'txn-1',
          amount: Money.fromRupees(250),
          occurredAt: DateTime(2026, 10, 1),
          source: 'manual',
          status: 'active',
        ),
      ],
      completeQuery: const TransactionQuery(),
      at: DateTime(2026, 10, 2),
    );

    final row = await container
        .read(transactionDetailProvider('txn-1').future)
        .timeout(const Duration(seconds: 2));

    expect(row?.id, 'txn-1');
  });
}
