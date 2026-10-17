import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _AuthFailingRepository implements UserCardsRepository {
  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? source,
    String? query,
  }) async {
    throw ApiException(
      'GET /transactions failed: 401 {"error":"Missing or invalid access token"}',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'Activity keeps the all-transactions snapshot after a transient auth failure',
    () async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      final cache = ResponseCache(database);
      final transaction = TransactionEntry(
        id: 'cached-1',
        amount: Money.fromRupees(500),
        occurredAt: DateTime(2026, 10, 16),
        merchantName: 'Cached merchant',
        source: 'sms',
        status: 'active',
      );

      final container = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'test-token'),
          responseCacheProvider.overrideWith((ref) async => cache),
          userCardsRepositoryProvider.overrideWithValue(
            _AuthFailingRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final namespace = container.read(cacheNamespaceProvider);
      await cache.put(
        '$namespace:transactions:activity',
        jsonEncode({'transactions': const []}),
      );
      await cache.put(
        '$namespace:transactions:all',
        jsonEncode({
          'transactions': [transaction.toJson()],
        }),
      );

      final result = await container.read(activityTransactionsProvider.future);

      expect(result, hasLength(1));
      expect(result.single.merchantName, 'Cached merchant');
    },
  );
}
