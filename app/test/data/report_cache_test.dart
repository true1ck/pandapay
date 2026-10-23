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
  test('pending SMS preserves established subscription series', () async {
    final database = openInMemoryForTesting();
    final cache = ResponseCache(database);
    final client = MockClient(
      (_) async => throw http.ClientException('offline'),
    );
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'restored-session'),
        responseCacheProvider.overrideWith((ref) async => cache),
        spendReportsRepositoryProvider.overrideWithValue(
          SpendReportsRepository(
            apiBaseUrl: 'http://api.test',
            accessToken: 'restored-session',
            client: client,
          ),
        ),
      ],
    );
    addTearDown(() {
      container.dispose();
      client.close();
      cache.financialStore.dispose();
      database.close();
    });
    final namespace = container.read(cacheNamespaceProvider);
    final saved = RecurringReport(
      series: [
        RecurringSeries(
          id: 'established',
          displayName: 'Streaming Service',
          typicalAmount: Money.fromRupees(649),
          cadenceDays: 30,
          occurrenceCount: 3,
          annualCost: Money.fromRupees(7896),
          nextExpectedOn: DateTime(2026, 11, 5),
        ),
        RecurringSeries(
          id: 'legacy-openai-mandate',
          displayName: 'OPENAILLC',
          typicalAmount: Money.fromRupees(1999),
          cadenceDays: 30,
          occurrenceCount: 1,
          annualCost: Money.fromRupees(24321),
          nextExpectedOn: DateTime(2026, 11, 19),
          isMandate: true,
          detectionSource: 'mandate',
          autopayStatus: 'active',
        ),
      ],
      totalAnnual: Money.fromRupees(7896),
    );
    await cache.put('$namespace:recurring_report', jsonEncode(saved.toJson()));
    cache.financialStore.saveObservation(namespace, 'openai-setup', {
      'id': 'openai-setup',
      'received_at': DateTime(2026, 10, 18).toUtc().toIso8601String(),
      'sender_bank': 'AXISBK',
      'biller_name': 'OPENAILLC',
      'event_type': 'autopay',
      'disposition': 'local_ignore',
      'is_autopay': true,
    });
    cache.financialStore.saveProvisional(
      namespace,
      TransactionEntry(
        id: 'unrelated-sms',
        sourceKey: 'unrelated',
        amount: Money.fromRupees(50),
        occurredAt: DateTime.now(),
        merchantName: 'Groceries',
        status: 'active',
        source: 'sms',
      ),
    );
    final report = await container.read(recurringReportProvider.future);
    expect(report!.series.map((item) => item.id), contains('established'));
    expect(report.series.where((item) => item.setupConfirmed), hasLength(1));
    expect(report.series.singleWhere((item) => item.setupConfirmed).displayName, 'OpenAI');
    final setup = report.series.singleWhere((item) => item.setupConfirmed);
    expect(setup.amountKnown, isFalse);
    expect(setup.cadenceDays, 0);
    expect(setup.nextExpectedOn, isNull);
    expect(setup.annualCost, Money.zero());
    cache.financialStore.discardProvisional(namespace, 'unrelated');
    await Future<void>.delayed(Duration.zero);
    final afterSync = await container.read(recurringReportProvider.future);
    expect(afterSync!.series.map((item) => item.id), contains('established'));
    expect(afterSync.series.where((item) => item.setupConfirmed), hasLength(1));
  });

  test(
    'pending local patterns do not resurrect dismissed server series',
    () async {
      final database = openInMemoryForTesting();
      final cache = ResponseCache(database);
      final client = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      final container = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'restored-session'),
          responseCacheProvider.overrideWith((ref) async => cache),
          spendReportsRepositoryProvider.overrideWithValue(
            SpendReportsRepository(
              apiBaseUrl: 'http://api.test',
              accessToken: 'restored-session',
              client: client,
            ),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        client.close();
        cache.financialStore.dispose();
        database.close();
      });
      final namespace = container.read(cacheNamespaceProvider);
      await cache.put(
        '$namespace:recurring_report',
        jsonEncode(
          const RecurringReport(series: [], totalAnnual: Money.zero()).toJson(),
        ),
      );
      for (var month = 7; month <= 9; month++) {
        cache.financialStore.saveProvisional(
          namespace,
          TransactionEntry(
            id: 'charge-$month',
            sourceKey: 'charge-$month',
            amount: Money.fromRupees(649),
            occurredAt: DateTime(2026, month, 5),
            merchantName: 'Streaming Service',
            categoryName: 'Entertainment',
            status: 'active',
            source: 'sms',
          ),
        );
      }
      final report = await container.read(recurringReportProvider.future);
      expect(report!.series, isEmpty);
    },
  );

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
