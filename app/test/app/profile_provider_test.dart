import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';

/// The You tab used to await GET /profile before painting anything, so a slow
/// API showed a blank page even when the last profile snapshot was on disk.
/// These pin the cache-first contract that replaced it.
void main() {
  final token =
      'e30.${base64Url.encode(utf8.encode('{"sub":"account-a"}')).replaceAll('=', '')}.sig';

  late AppDatabase db;
  late ResponseCache cache;

  setUp(() {
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
  });

  tearDown(() {
    cache.financialStore.dispose();
    db.close();
  });

  test('a cached profile paints while the live request is still in flight', () async {
    const namespace = 'user:account-a';
    const key = '$namespace:profile';
    await cache.put(
      key,
      jsonEncode({
        'profile': {'display_name': 'Aarav', 'email': 'aarav@example.com'},
      }),
    );
    // Force _warmDisplay to actually start the refresh even though the
    // snapshot was written just now.
    cache.markAccountStale(namespace);

    final pending = Completer<http.Response>();
    final client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) => pending.future),
    );
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => token),
        responseCacheProvider.overrideWith((ref) async => cache),
        authenticatedHttpClientProvider.overrideWithValue(client),
      ],
    );

    final profile = await container
        .read(profileProvider.future)
        .timeout(const Duration(seconds: 1));

    expect(profile?['display_name'], 'Aarav');
    expect(
      pending.isCompleted,
      isFalse,
      reason: 'the cached row must not wait for the network response',
    );

    container.dispose();
    pending.complete(http.Response('{"profile":null}', 200));
  });

  test('a network failure with no snapshot still surfaces the error', () async {
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => token),
        responseCacheProvider.overrideWith((ref) async => cache),
        authenticatedHttpClientProvider.overrideWithValue(
          AuthenticatedHttpClient(
            refreshAccessToken: () async => null,
            inner: MockClient(
              (_) async => throw http.ClientException('offline'),
            ),
          ),
        ),
      ],
    );

    // A real transport failure and nothing cached is not silently turned into
    // "no profile": the screen keeps its error state with a Retry affordance.
    await expectLater(
      container.read(profileProvider.future),
      throwsA(isA<http.ClientException>()),
    );

    container.dispose();
  });
}
