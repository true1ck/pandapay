import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/spend_reports_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test(
    'builds Spending and Subscriptions from transactions after report 401',
    () async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      final cache = ResponseCache(database);
      final now = DateTime.now();
      final rows = [
        for (final date in [
          DateTime(now.year, now.month - 2, 5),
          DateTime(now.year, now.month - 1, 5),
          DateTime(now.year, now.month, 5),
        ])
          TransactionEntry(
            id: date.toIso8601String(),
            amount: Money.fromRupees(649),
            occurredAt: date,
            merchantName: 'Streaming Service',
            categoryName: 'Entertainment',
            source: 'sms',
            status: 'active',
          ),
        for (final date in [
          DateTime(now.year, now.month, 2),
          DateTime(now.year, now.month, 10),
          DateTime(now.year, now.month, 18),
        ])
          TransactionEntry(
            id: 'person-${date.toIso8601String()}',
            amount: Money.fromRupees(73),
            occurredAt: date,
            merchantName: 'Rohit ramdas naik',
            categoryName: 'Other',
            source: 'sms',
            status: 'active',
          ),
      ];
      final failingClient = MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'Missing or invalid access token'}),
          401,
        ),
      );
      final reportRepository = SpendReportsRepository(
        apiBaseUrl: 'http://api.test',
        accessToken: 'expired-access',
        client: failingClient,
      );
      final container = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'expired-access'),
          responseCacheProvider.overrideWith((ref) async => cache),
          spendReportsRepositoryProvider.overrideWithValue(reportRepository),
        ],
      );
      addTearDown(container.dispose);

      final namespace = container.read(cacheNamespaceProvider);
      await cache.put(
        '$namespace:transactions:all',
        jsonEncode({'transactions': rows.map((row) => row.toJson()).toList()}),
      );
      await cache.put(
        '$namespace:insights_transactions:thisYear:cached-range',
        jsonEncode({'transactions': rows.map((row) => row.toJson()).toList()}),
      );

      final report = await container.read(
        spendReportProvider(
          const SpendReportQuery.preset(SpendPeriod.month),
        ).future,
      );
      final recurring = await container.read(recurringReportProvider.future);

      expect(report?.spend.txnCount, 4);
      expect(report?.spend.total, Money.fromRupees(868));
      expect(recurring?.series, hasLength(1));
      expect(recurring?.series.single.displayName, 'Streaming Service');
      expect(recurring?.series.single.occurrenceCount, 3);
    },
  );

  test(
    'builds Rewards from the Insights cache when monthly API is rejected',
    () async {
      final database = openInMemoryForTesting();
      addTearDown(database.close);
      final cache = ResponseCache(database);
      final now = DateTime.now();
      final transaction = TransactionEntry(
        id: 'monthly-cached',
        amount: Money.fromRupees(1200),
        occurredAt: now,
        merchantName: 'Local merchant',
        rewardValue: Money.fromRupees(24),
        source: 'sms',
        status: 'active',
      );
      final failingClient = MockClient((_) async {
        throw http.ClientException('refresh transport failed');
      });
      final userCardsRepository = UserCardsRepository(
        apiBaseUrl: 'http://api.test',
        accessToken: 'expired-access',
        client: failingClient,
      );
      final container = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'expired-access'),
          responseCacheProvider.overrideWith((ref) async => cache),
          userCardsRepositoryProvider.overrideWithValue(userCardsRepository),
        ],
      );
      addTearDown(container.dispose);

      final namespace = container.read(cacheNamespaceProvider);
      await cache.put(
        '$namespace:insights_transactions:thisMonth:cached-range',
        jsonEncode({
          'transactions': [transaction.toJson()],
        }),
      );

      final report = await container.read(currentMonthlyReportProvider.future);

      expect(report?.totalSpend, Money.fromRupees(1200));
      expect(report?.rewardsEarned, Money.fromRupees(24));
    },
  );

  test('filtered missed-rewards history reuses Insights snapshots', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final now = DateTime.now();
    final transaction = TransactionEntry(
      id: 'missed-cached',
      amount: Money.fromRupees(500),
      occurredAt: now.subtract(const Duration(days: 3)),
      merchantName: 'Local merchant',
      source: 'sms',
      status: 'active',
    );
    final userCardsRepository = UserCardsRepository(
      apiBaseUrl: 'http://api.test',
      accessToken: 'expired-access',
      client: MockClient((_) async => http.Response('unauthorized', 401)),
    );
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'expired-access'),
        responseCacheProvider.overrideWith((ref) async => cache),
      ],
    );
    addTearDown(container.dispose);
    final namespace = container.read(cacheNamespaceProvider);
    await cache.put(
      '$namespace:insights_transactions:thisMonth:cached-range',
      jsonEncode({
        'transactions': [transaction.toJson()],
      }),
    );
    final provider = FutureProvider(
      (ref) => loadTransactionsWithOfflineCache(
        ref,
        repo: userCardsRepository,
        cacheKey: 'transactions:missed_opportunities',
        from: now.subtract(const Duration(days: 90)),
        preferCached: true,
        useReportSnapshots: true,
      ),
    );
    final rows = await container.read(provider.future);
    expect(rows.map((row) => row.id), ['missed-cached']);
  });
}
