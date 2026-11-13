import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/user_budgets_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A budget created offline is listed with spent computed on the phone and is
/// labelled as an estimate; nothing needs the server.
void main() {
  final token =
      'e30.${base64Url.encode(utf8.encode('{"sub":"account-a"}')).replaceAll('=', '')}.sig';

  test('a budget saved offline shows a local estimate of spent', () async {
    SharedPreferences.setMockInitialValues({});
    final db = openInMemoryForTesting();
    final cache = ResponseCache(db);
    addTearDown(() {
      cache.financialStore.dispose();
      db.close();
    });
    const ns = 'user:account-a';
    cache.financialStore.saveTransactions(ns, [
      TransactionEntry(
        id: 't1',
        amount: Money.fromRupees(300),
        occurredAt: DateTime(2026, 11, 3),
        merchantName: 'Synthetic Shop',
        source: 'manual',
        status: 'active',
        userCardId: 'card-a',
      ),
      TransactionEntry(
        id: 't2',
        amount: Money.fromRupees(900),
        occurredAt: DateTime(2026, 11, 4),
        merchantName: 'Synthetic Shop',
        source: 'manual',
        status: 'active',
        userCardId: 'card-b',
      ),
    ], completeQuery: const TransactionQuery());
    UserBudgetsStore(db, ns).put('b1', {
      'scope': 'card',
      'scopeRefId': 'card-a',
      'period': 'monthly',
      'amountInr': 1000.0,
      'label': 'Synthetic Card',
    });

    final client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => throw http.ClientException('offline')),
    );
    final container = ProviderContainer(overrides: [
      accessTokenProvider.overrideWith((ref) => token),
      responseCacheProvider.overrideWith((ref) async => cache),
      authenticatedHttpClientProvider.overrideWithValue(client),
      clockProvider.overrideWithValue(TestClock(DateTime(2026, 11, 14))),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(budgetsProvider, (_, _) {});
    addTearDown(sub.close);
    final rows = await container
        .read(budgetsProvider.future)
        .timeout(const Duration(seconds: 10));
    expect(rows, hasLength(1));
    expect(rows.single.isEstimate, isTrue);
    expect(rows.single.spent, Money.fromRupees(300));
    expect(rows.single.consumedFraction, closeTo(0.3, 1e-9));
  });
}
