import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/spend_by_category_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _Offline extends SpendByCategoryRepository {
  _Offline() : super(apiBaseUrl: 'https://api.test', accessToken: 't');

  @override
  Future<List<CategorySpend>> fetchSpendByCategory({int months = 12}) async =>
      throw const SocketException('offline');
}

void main() {
  test('category spend falls back to saved transactions when offline', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith((ref) async => cache),
        spendByCategoryRepositoryProvider.overrideWithValue(_Offline()),
      ],
    );
    addTearDown(container.dispose);
    final ns = container.read(cacheNamespaceProvider);
    final now = DateTime.now();
    TransactionEntry row(String id, int rupees) => TransactionEntry(
      id: id,
      amount: Money.fromRupees(rupees),
      occurredAt: now.subtract(const Duration(days: 3)),
      source: 'manual',
      status: 'active',
      categoryId: 'cat-food',
      categoryName: 'Dining',
    );
    cache.financialStore.saveTransactions(
      ns,
      [row('a', 100), row('b', 50)],
      completeQuery: const TransactionQuery(),
      at: now,
    );

    final spend = await container.read(categorySpendProvider.future);

    expect(spend, hasLength(1));
    expect(spend.single.totalSpend, Money.fromRupees(150));
    expect(spend.single.txnCount, 2);
  });
}
