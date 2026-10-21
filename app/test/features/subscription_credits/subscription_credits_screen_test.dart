import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/referral_repository.dart';
import 'package:pandapay/data/subscription_credits_repository.dart';
import 'package:pandapay/features/subscription_credits/subscription_credits_screen.dart';

void main() {
  testWidgets(
    'shows exact available/reserved/used credits and disabled redemption',
    (tester) async {
      await tester.pumpWidget(_app(_FakeCreditsRepository(_data())));
      await tester.pumpAndSettle();

      expect(find.text('₹25'), findsNWidgets(2));
      expect(find.text('₹5'), findsOneWidget);
      expect(find.text('₹10'), findsOneWidget);
      expect(find.text('Referral reward'), findsOneWidget);
      expect(
        find.text('For a future PandaPay subscription benefit'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Subscription redemption is not available yet'),
        findsOneWidget,
      );

      final redemption = tester.widget<FilledButton>(
        find.widgetWithText(
          FilledButton,
          'Subscription redemption unavailable',
        ),
      );
      expect(redemption.onPressed, isNull);
    },
  );

  testWidgets('shows denied server state instead of displaying a zero balance', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _FakeCreditsRepository(
          _data(),
          loadError: ApiException(
            'GET /subscription-credits failed: 403 {}',
            userMessage:
                'Subscription credit details are not available for this account.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Subscription credit details are not available for this account.',
      ),
      findsOneWidget,
    );
    expect(find.text('₹25'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('shows offline state without rendering an empty history', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _FakeCreditsRepository(
          _data(),
          loadError: http.ClientException('offline'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Something went wrong. Please check your connection and try again.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('No subscription-credit activity yet'),
      findsNothing,
    );
  });

  testWidgets('labels account-scoped saved credit data as stale', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_FakeCreditsRepository(_data(stale: true))));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Offline — showing saved information'),
      findsOneWidget,
    );
    expect(find.text('₹25'), findsNWidgets(2));
  });
}

Widget _app(_FakeCreditsRepository repository) => ProviderScope(
  overrides: [
    subscriptionCreditsRepositoryProvider.overrideWith((ref) => repository),
  ],
  child: const MaterialApp(home: SubscriptionCreditsScreen()),
);

SubscriptionCreditData _data({bool stale = false}) => SubscriptionCreditData(
  balance: SubscriptionCreditBalance(
    available: const PaiseAmount(2500),
    reserved: const PaiseAmount(500),
    used: const PaiseAmount(1000),
    currency: 'INR',
    lastConfirmedAt: DateTime.utc(2026, 10, 21, 10),
  ),
  ledger: const SubscriptionCreditLedgerPage(
    entries: [
      SubscriptionCreditLedgerEntry(
        id: 'entry-1',
        kind: 'award',
        state: 'posted',
        amount: PaiseAmount(2500),
      ),
    ],
  ),
  isStale: stale,
  cachedAt: stale ? DateTime.utc(2026, 10, 21, 10) : null,
);

class _FakeCreditsRepository implements SubscriptionCreditsRepository {
  _FakeCreditsRepository(this.data, {this.loadError});

  final SubscriptionCreditData data;
  final Object? loadError;

  @override
  Future<SubscriptionCreditData> load() async {
    final error = loadError;
    if (error != null) throw error;
    return data;
  }

  @override
  Future<SubscriptionCreditLedgerPage> loadMore(String cursor) async =>
      const SubscriptionCreditLedgerPage(entries: []);
}
