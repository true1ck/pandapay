import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/referral_repository.dart';

void main() {
  group('HttpReferralRepository', () {
    test(
      'loads v2 referral page, own progress, rewards and own code',
      () async {
        final requests = <http.Request>[];
        final repository = HttpReferralRepository(
          apiBaseUrl: 'https://api.test/',
          accessToken: 'member-token',
          client: MockClient((request) async {
            requests.add(request);
            return http.Response(
              jsonEncode(_responseFor(request)),
              request.method == 'POST' ? 201 : 200,
            );
          }),
        );

        final dashboard = await repository.loadDashboard(year: 2026);

        expect(
          requests.map((request) => request.url.path),
          containsAll([
            '/referrals/v2',
            '/referrals/mine',
            '/rewards',
            '/referrals/code',
          ]),
        );
        expect(
          requests.every(
            (request) =>
                request.headers['Authorization'] == 'Bearer member-token',
          ),
          isTrue,
        );
        expect(
          requests
              .singleWhere((request) => request.url.path == '/referrals/v2')
              .url
              .queryParameters['year'],
          '2026',
        );
        expect(dashboard.code, 'PANDA26');
        expect(dashboard.page.joinedCount, 3);
        expect(dashboard.page.awardedPaise, 3200);
        expect(dashboard.page.friends.single.displayState, 'Bamboo progress');
        expect(dashboard.page.friends.single.completedDays, 2);
        expect(dashboard.mine?.completedDays, 2);
        expect(dashboard.mine?.requiredDays, 3);
        expect(dashboard.rewards.single.isReady, isTrue);
      },
    );

    test('sends a selected year and opaque cursor for the next page', () async {
      late http.Request request;
      final repository = HttpReferralRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'friends': [
                {'id': 'f-2', 'state': 'credited', 'label': 'Friend'},
              ],
              'nextCursor': null,
            }),
            200,
          );
        }),
      );

      final page = await repository.loadMore(
        year: 2025,
        cursor: 'opaque / cursor',
      );

      expect(request.url.path, '/referrals/v2');
      expect(request.url.queryParameters, {
        'year': '2025',
        'cursor': 'opaque / cursor',
      });
      expect(page.friends.single.displayState, 'Credits added');
    });

    test(
      'surfaces a structured invitation denial without fabricating empty data',
      () async {
        final repository = HttpReferralRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient((request) async {
            if (request.url.path == '/referrals/v2') {
              return http.Response(
                jsonEncode({'error': 'invitation_required'}),
                403,
              );
            }
            return http.Response(jsonEncode(_responseFor(request)), 200);
          }),
        );

        await expectLater(
          repository.loadDashboard(year: 2026),
          throwsA(
            isA<ApiException>()
                .having((error) => error.statusCode, 'statusCode', 403)
                .having(
                  (error) => error.errorCode,
                  'errorCode',
                  'invitation_required',
                )
                .having(
                  (error) => error.userMessage,
                  'userMessage',
                  contains('cannot access'),
                ),
          ),
        );
      },
    );

    test(
      'surfaces server errors and preserves offline transport failures',
      () async {
        final serverFailure = HttpReferralRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient(
            (request) async => http.Response('unavailable', 503),
          ),
        );
        await expectLater(
          serverFailure.loadDashboard(year: 2026),
          throwsA(
            isA<ApiException>().having(
              (error) => error.statusCode,
              'statusCode',
              503,
            ),
          ),
        );

        final offline = HttpReferralRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );
        await expectLater(
          offline.loadDashboard(year: 2026),
          throwsA(isA<http.ClientException>()),
        );
      },
    );

    test(
      'uses an account-scoped cached dashboard after a network failure',
      () async {
        final cache = _MemoryJsonCache();
        final fetchedAt = DateTime.utc(2026, 10, 21, 10);
        cache.fetchedAt = fetchedAt;
        final freshRepository = HttpReferralRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token-a',
          cache: cache,
          cacheNamespace: () => 'user:a',
          client: MockClient(
            (request) async => http.Response(
              jsonEncode(_responseFor(request)),
              request.method == 'POST' ? 201 : 200,
            ),
          ),
        );
        await freshRepository.loadDashboard(year: 2026);

        final offlineRepository = HttpReferralRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token-a',
          cache: cache,
          cacheNamespace: () => 'user:a',
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );
        final dashboard = await offlineRepository.loadDashboard(year: 2026);

        expect(dashboard.isStale, isTrue);
        expect(dashboard.cachedAt, fetchedAt);
        expect(dashboard.code, 'PANDA26');
        expect(dashboard.page.friends.single.id, 'friend-1');
      },
    );

    test('does not hide a denied response behind a cached dashboard', () async {
      final cache = _MemoryJsonCache();
      final seedRepository = HttpReferralRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token-a',
        cache: cache,
        cacheNamespace: () => 'user:a',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(_responseFor(request)),
            request.method == 'POST' ? 201 : 200,
          ),
        ),
      );
      await seedRepository.loadDashboard(year: 2026);
      final deniedRepository = HttpReferralRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token-a',
        cache: cache,
        cacheNamespace: () => 'user:a',
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'error': 'invitation_required'}), 403),
        ),
      );

      await expectLater(
        deniedRepository.loadDashboard(year: 2026),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
    });

    test(
      'never replays a spin from read cache after an offline error',
      () async {
        final cache = _MemoryJsonCache();
        final repository = HttpReferralRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token-a',
          cache: cache,
          cacheNamespace: () => 'user:a',
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );

        await expectLater(
          repository.spin('entitlement-1'),
          throwsA(isA<http.ClientException>()),
        );
      },
    );

    test('a repeated spin returns the same server-committed result', () async {
      var calls = 0;
      final repository = HttpReferralRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/rewards/entitlement-1/spin');
          calls++;
          return http.Response(
            jsonEncode({
              'entitlementId': 'entitlement-1',
              'spinId': 'spin-committed',
              'outcomeId': 'credit-32',
              'amountPaise': '3200',
              'ledgerEntryId': 'ledger-1',
              'state': 'credited',
              'replayed': calls > 1,
            }),
            200,
          );
        }),
      );

      final first = await repository.spin('entitlement-1');
      final replay = await repository.spin('entitlement-1');

      expect(calls, 2);
      expect(first.spinId, replay.spinId);
      expect(first.amount.value, 3200);
      expect(replay.amount.value, 3200);
      expect(first.ledgerEntryId, replay.ledgerEntryId);
      expect(replay.replayed, isTrue);
    });

    test(
      'loads the server version of prize values and weighted odds',
      () async {
        late http.Request request;
        final repository = HttpReferralRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient((incoming) async {
            request = incoming;
            return http.Response(
              jsonEncode({
                'role': 'inviter',
                'campaignVersion': 'bamboo-spin-v1-2026-10',
                'state': 'ready',
                'distribution': [
                  {'id': 'zero', 'amountPaise': '0', 'weight': 1000},
                  {'id': 'five-hundred', 'amountPaise': '50000', 'weight': 20},
                ],
              }),
              200,
            );
          }),
        );

        final config = await repository.loadSpinConfiguration('entitlement-1');

        expect(request.method, 'GET');
        expect(request.url.path, '/rewards/entitlement-1/spin-config');
        expect(config.campaignVersion, 'bamboo-spin-v1-2026-10');
        expect(config.totalWeight, 1020);
        expect(config.prizes.first.amount.value, 0);
        expect(config.prizes.last.amount.inr, '₹500');
      },
    );

    test(
      'parses a committed zero prize without inventing a ledger entry',
      () async {
        final repository = HttpReferralRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'entitlementId': 'entitlement-1',
                'spinId': 'spin-zero',
                'outcomeId': 'zero',
                'amountPaise': '0',
                'ledgerEntryId': null,
                'state': 'completed',
              }),
              200,
            ),
          ),
        );

        final spin = await repository.spin('entitlement-1');

        expect(spin.isCredited, isTrue);
        expect(spin.amount.value, 0);
        expect(spin.ledgerEntryId, isNull);
      },
    );

    test('restores completed spins from the flat rewards response', () {
      final paid = RewardEntitlement.fromJson({
        'entitlementId': 'entitlement-paid',
        'state': 'claimed',
        'spinId': 'spin-paid',
        'outcomeId': 'ten',
        'amountPaise': '1000',
        'ledgerEntryId': 'ledger-1',
      });
      final zero = RewardEntitlement.fromJson({
        'entitlementId': 'entitlement-zero',
        'state': 'claimed',
        'spinId': 'spin-zero',
        'outcomeId': 'zero',
        'amountPaise': '0',
        'ledgerEntryId': null,
      });

      expect(paid.result?.amount.inr, '₹10');
      expect(zero.result?.state, 'completed');
      expect(zero.result?.isCredited, isTrue);
    });
  });

  group('PaiseAmount', () {
    test('formats integer paise without floating point arithmetic', () {
      expect(PaiseAmount.fromJson('1000').inr, '₹10');
      expect(PaiseAmount.fromJson('123456789').inr, '₹12,34,567.89');
      expect(PaiseAmount.fromJson('-5').inr, '-₹0.05');
    });

    test('rejects rupee decimals and fractional numeric values', () {
      expect(() => PaiseAmount.fromJson(10.5), throwsFormatException);
      expect(() => PaiseAmount.fromJson('10.50'), throwsFormatException);
    });
  });
}

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

Map<String, dynamic> _responseFor(http.Request request) =>
    switch (request.url.path) {
      '/referrals/v2' => {
        'code': 'PANDA26',
        'rewardsActive': true,
        'joinTotals': {'count': 3},
        'awardTotals': {'amountPaise': '3200'},
        'referrals': [
          {
            'id': 'friend-1',
            'label': 'Kai',
            'state': 'in_progress',
            'milestone': {'completedDays': 2, 'requiredDays': 3},
            'joinedAt': '2026-10-20T12:00:00Z',
          },
        ],
      },
      '/referrals/mine' => {
        'referral': {
          'state': 'in_progress',
          'rewardEligible': true,
          'inviterAlias': 'Mira',
          'milestone': {'completedDays': 2, 'requiredDays': 3},
          'deadlineAt': '2026-11-20T06:00:00Z',
        },
      },
      '/rewards' => {
        'rewards': [
          {'id': 'entitlement-1', 'role': 'referee', 'state': 'ready'},
        ],
      },
      '/referrals/code' => {'code': 'PANDA26'},
      _ => <String, dynamic>{},
    };
