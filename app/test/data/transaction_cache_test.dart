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

class _EmptyRepository implements UserCardsRepository {
  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? source,
    String? query,
  }) async => const [];

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

  test(
    'canonical Activity reads its older activity snapshot on auth failure',
    () async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      final cache = ResponseCache(database);
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
        jsonEncode({
          'transactions': [
            TransactionEntry(
              id: 'old-activity-1',
              amount: Money.fromRupees(250),
              occurredAt: DateTime(2026, 10, 16),
              merchantName: 'Previous activity',
              source: 'sms',
              status: 'active',
            ).toJson(),
          ],
        }),
      );

      final rows = await container.read(activityTransactionsProvider.future);
      expect(rows.single.id, 'old-activity-1');
    },
  );

  test(
    'auth failure with no transaction rows is not an empty history',
    () async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      final cache = ResponseCache(database);
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
        '$namespace:transactions:all',
        jsonEncode({'transactions': const []}),
      );

      await expectLater(
        container.read(activityTransactionsProvider.future),
        throwsA(isA<AuthenticationUnavailableException>()),
      );
    },
  );

  test('Activity recovers individual rows already saved by Spending', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith((ref) async => cache),
        userCardsRepositoryProvider.overrideWithValue(_EmptyRepository()),
      ],
    );
    addTearDown(container.dispose);

    final namespace = container.read(cacheNamespaceProvider);
    await cache.put(
      '$namespace:transactions:all',
      jsonEncode({'transactions': const []}),
    );
    await cache.put(
      '$namespace:spend_detail:month:2026-10',
      jsonEncode({
        'transactions': [
          TransactionEntry(
            id: 'spending-row-1',
            amount: Money.fromRupees(499),
            occurredAt: DateTime(2026, 10, 17),
            merchantName: 'Visible in Spending',
            source: 'sms',
            status: 'active',
          ).toJson(),
        ],
      }),
    );

    final rows = await container.read(activityTransactionsProvider.future);
    expect(rows.single.id, 'spending-row-1');
  });

  test('Activity combines older history with newer Spending rows offline', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith((ref) async => cache),
        userCardsRepositoryProvider.overrideWithValue(_AuthFailingRepository()),
      ],
    );
    addTearDown(container.dispose);

    final namespace = container.read(cacheNamespaceProvider);
    TransactionEntry row(String id, int day) => TransactionEntry(
      id: id,
      amount: Money.fromRupees(100),
      occurredAt: DateTime(2026, 10, day),
      source: 'sms',
      status: 'active',
    );
    await cache.put(
      '$namespace:transactions:all',
      jsonEncode({'transactions': [row('old', 16).toJson()]}),
    );
    await cache.put(
      '$namespace:spend_detail:month:2026-10',
      jsonEncode({'transactions': [row('new', 17).toJson()]}),
    );

    final rows = await container.read(activityTransactionsProvider.future);
    expect(rows.map((row) => row.id).toSet(), {'old', 'new'});
  });
}
