import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// V9: with no usable transaction snapshot and no network, the Bills data
/// provider must degrade to "no rows", not an error.
void main() {
  final card = UserCard.fromJson({
    'id': 'card',
    'card_product_id': 'product',
    'card_name': 'Synthetic Card',
    'last4': '0000',
    'due_day': 10,
    'is_default': false,
  });
  final token =
      'e30.${base64Url.encode(utf8.encode('{"sub":"account-a"}')).replaceAll('=', '')}.sig';

  test('paymentsDueProvider does not error offline without a snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    final db = openInMemoryForTesting();
    final cache = ResponseCache(db);
    addTearDown(() {
      cache.financialStore.dispose();
      db.close();
    });
    final client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => throw http.ClientException('offline')),
    );
    final container = ProviderContainer(overrides: [
      accessTokenProvider.overrideWith((ref) => token),
      responseCacheProvider.overrideWith((ref) async => cache),
      authenticatedHttpClientProvider.overrideWithValue(client),
      clockProvider.overrideWithValue(TestClock(DateTime(2026, 11, 1))),
      myCardsProvider.overrideWith((ref) async => [card]),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(paymentsDueProvider, (_, _) {});
    addTearDown(sub.close);
    final rows = await container
        .read(paymentsDueProvider.future)
        .timeout(const Duration(seconds: 10));
    expect(rows, isA<List<DuePayment>>());
  });
}
