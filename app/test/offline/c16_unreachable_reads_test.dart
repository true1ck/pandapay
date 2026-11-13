import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/connectivity/reachability.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';

class _HangingRepository implements UserCardsRepository {
  var calls = 0;

  @override
  Future<List<LoungeVisit>> fetchLoungeUsage() {
    calls++;
    return Completer<List<LoungeVisit>>().future; // captive Wi-Fi: never answers
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  homeRefreshTests();
  test('unreachable server: cached lounge usage is served without waiting',
      () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final reachability = ServerReachability(
      probe: () async => false,
      radioUp: () => true,
    );
    await reachability.check();
    final repo = _HangingRepository();
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith((ref) async => cache),
        userCardsRepositoryProvider.overrideWithValue(repo),
        serverReachabilityProvider.overrideWithValue(reachability),
      ],
    );
    addTearDown(container.dispose);
    final ns = container.read(cacheNamespaceProvider);
    await cache.put('$ns:lounge_usage', jsonEncode({'loungeUsage': []}));

    final visits = await container
        .read(loungeUsageServerProvider.future)
        .timeout(const Duration(seconds: 2));

    expect(visits, isEmpty);
    expect(repo.calls, 0);
  });

  test('unknown reachability still fetches (healthy user unchanged)', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final cache = ResponseCache(database);
    final repo = _HangingRepository();
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith((ref) async => cache),
        userCardsRepositoryProvider.overrideWithValue(repo),
        serverReachabilityProvider.overrideWithValue(
          ServerReachability(probe: () async => true, radioUp: () => true),
        ),
      ],
    );
    addTearDown(container.dispose);
    final ns = container.read(cacheNamespaceProvider);
    await cache.put('$ns:lounge_usage', jsonEncode({'loungeUsage': []}));

    unawaited(container.read(loungeUsageServerProvider.future));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(repo.calls, 1);
  });
}

class _CountingRepository implements UserCardsRepository {
  var calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    return Future<dynamic>.error(StateError('should not be called'));
  }
}

void homeRefreshTests() {
  test('Home refresh burst is skipped when the API is unreachable', () async {
    final database = openInMemoryForTesting();
    addTearDown(database.close);
    final reachability = ServerReachability(
      probe: () async => false,
      radioUp: () => true,
    );
    await reachability.check();
    final repo = _CountingRepository();
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => 'test-token'),
        responseCacheProvider.overrideWith(
          (ref) async => ResponseCache(database),
        ),
        userCardsRepositoryProvider.overrideWithValue(repo),
        serverReachabilityProvider.overrideWithValue(reachability),
      ],
    );
    addTearDown(container.dispose);

    await container.read(homeDataRefreshProvider.future);

    expect(repo.calls, 0);
  });
}
