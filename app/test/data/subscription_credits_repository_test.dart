import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/referral_repository.dart'
    show AccountScopedJsonCache, CachedJsonSnapshot;
import 'package:pandapay/data/subscription_credits_repository.dart';

void main() {
  group('HttpSubscriptionCreditsRepository', () {
    test('loads exact paise balances and the durable ledger page', () async {
      final requests = <http.Request>[];
      final repository = HttpSubscriptionCreditsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'member-token',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/ledger')
                  ? {
                      'ledger': [
                        {
                          'id': 'entry-1',
                          'kind': 'award',
                          'state': 'posted',
                          'amountPaise': '1250',
                          'createdAt': '2026-10-21T10:00:00Z',
                        },
                      ],
                      'nextCursor': 'cursor-2',
                    }
                  : {
                      'availablePaise': '1250',
                      'reservedPaise': '500',
                      'usedPaise': '1000',
                      'currency': 'INR',
                      'asOf': '2026-10-21T10:00:00Z',
                    },
            ),
            200,
          );
        }),
      );

      final data = await repository.load();

      expect(
        requests.map((request) => request.url.path),
        containsAll(['/subscription-credits', '/subscription-credits/ledger']),
      );
      expect(
        requests.every(
          (request) =>
              request.headers['Authorization'] == 'Bearer member-token',
        ),
        isTrue,
      );
      expect(data.balance.available.value, 1250);
      expect(data.balance.reserved.value, 500);
      expect(data.balance.used?.value, 1000);
      expect(data.balance.available.inr, '₹12.50');
      expect(data.ledger.entries.single.displayKind, 'Referral reward');
      expect(data.ledger.entries.single.amount.value, 1250);
      expect(data.ledger.nextCursor, 'cursor-2');
    });

    test('uses the opaque cursor when loading older ledger entries', () async {
      late http.Request request;
      final repository = HttpSubscriptionCreditsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(jsonEncode({'entries': []}), 200);
        }),
      );

      await repository.loadMore('older / entry');

      expect(request.url.path, '/subscription-credits/ledger');
      expect(request.url.queryParameters['cursor'], 'older / entry');
    });

    test('parses the backend availableDeltaPaise field as integer paise', () {
      final entry = SubscriptionCreditLedgerEntry.fromJson({
        'id': 'entry-delta',
        'kind': 'award',
        'availableDeltaPaise': '1750',
      });
      final page = SubscriptionCreditLedgerPage.fromJson({
        'ledger': [
          {'id': 'entry-delta', 'kind': 'award', 'availableDeltaPaise': '1750'},
        ],
      });

      expect(entry.amount.value, 1750);
      expect(entry.state, 'posted');
      expect(entry.expiresAt, isNull);
      expect(page.nextCursor, isNull);
      expect(page.entries.single.amount.inr, '₹17.50');
    });

    test(
      'surfaces denied and server failures as errors, not zero balances',
      () async {
        for (final status in [403, 500]) {
          final repository = HttpSubscriptionCreditsRepository(
            apiBaseUrl: 'https://api.test',
            accessToken: 'token',
            client: MockClient((_) async => http.Response('{}', status)),
          );
          await expectLater(
            repository.load(),
            throwsA(
              isA<ApiException>().having(
                (error) => error.statusCode,
                'statusCode',
                status,
              ),
            ),
          );
        }
      },
    );

    test(
      'preserves offline failures instead of returning an empty ledger',
      () async {
        final repository = HttpSubscriptionCreditsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );

        await expectLater(
          repository.load(),
          throwsA(isA<http.ClientException>()),
        );
      },
    );

    test(
      'uses account-scoped saved balance and ledger while offline',
      () async {
        final cache = _MemoryJsonCache();
        final fetchedAt = DateTime.utc(2026, 10, 21, 10);
        cache.fetchedAt = fetchedAt;
        final online = HttpSubscriptionCreditsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token-a',
          cache: cache,
          cacheNamespace: () => 'user:a',
          client: MockClient(
            (request) async =>
                http.Response(jsonEncode(_creditsResponse(request)), 200),
          ),
        );
        await online.load();

        final offline = HttpSubscriptionCreditsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token-a',
          cache: cache,
          cacheNamespace: () => 'user:a',
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );
        final data = await offline.load();

        expect(data.isStale, isTrue);
        expect(data.cachedAt, fetchedAt);
        expect(data.balance.available.value, 1250);
        expect(data.ledger.entries.single.amount.value, 1250);
      },
    );

    test(
      'a denied balance is not replaced by a cached credit snapshot',
      () async {
        final cache = _MemoryJsonCache();
        final online = HttpSubscriptionCreditsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token-a',
          cache: cache,
          cacheNamespace: () => 'user:a',
          client: MockClient(
            (request) async =>
                http.Response(jsonEncode(_creditsResponse(request)), 200),
          ),
        );
        await online.load();
        final denied = HttpSubscriptionCreditsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token-a',
          cache: cache,
          cacheNamespace: () => 'user:a',
          client: MockClient((_) async => http.Response('{}', 403)),
        );

        await expectLater(
          denied.load(),
          throwsA(
            isA<ApiException>().having(
              (error) => error.statusCode,
              'statusCode',
              403,
            ),
          ),
        );
      },
    );

    test('rejects fractional or rupee-valued balance DTOs', () async {
      final repository = HttpSubscriptionCreditsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path.endsWith('/ledger')
                  ? {'ledger': []}
                  : {'availablePaise': 1.25, 'reservedPaise': '0'},
            ),
            200,
          ),
        ),
      );

      await expectLater(repository.load(), throwsFormatException);
    });
  });
}

Map<String, dynamic> _creditsResponse(http.Request request) =>
    request.url.path.endsWith('/ledger')
    ? {
        'ledger': [
          {'id': 'entry-1', 'kind': 'award', 'availableDeltaPaise': '1250'},
        ],
      }
    : {'availablePaise': '1250', 'reservedPaise': '0', 'currency': 'INR'};

class _MemoryJsonCache implements AccountScopedJsonCache {
  final Map<String, CachedJsonSnapshot> _values = {};
  DateTime fetchedAt = DateTime.utc(2026, 10, 21, 9);

  @override
  Future<CachedJsonSnapshot?> read(String namespace, String key) async =>
      _values['$namespace:$key'];

  @override
  Future<void> write(
    String namespace,
    String key,
    Map<String, dynamic> body,
  ) async {
    _values['$namespace:$key'] = CachedJsonSnapshot(
      body: body,
      fetchedAt: fetchedAt,
    );
  }
}
