import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';

/// End-to-end check of the SMS bill pipeline through paymentsDueProvider:
/// a captured bill SMS must surface the issuer's bill on the dues screen,
/// and a local payment receipt must mark it paid — all offline.
void main() {
  final card = UserCard.fromJson({
    'id': 'card',
    'card_product_id': 'product',
    'card_name': 'Axis Flipkart',
    'last4': '7788',
    'is_default': false,
  });
  final token =
      'e30.${base64Url.encode(utf8.encode('{"sub":"account-a"}')).replaceAll('=', '')}.sig';

  late AppDatabase db;
  late ResponseCache cache;
  late TestClock clock;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
    clock = TestClock(DateTime(2026, 11, 1));
  });
  tearDown(() {
    cache.financialStore.dispose();
    db.close();
  });

  ProviderContainer offlineContainer() {
    final client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => throw http.ClientException('offline')),
    );
    final container = ProviderContainer(
      overrides: [
        accessTokenProvider.overrideWith((ref) => token),
        responseCacheProvider.overrideWith((ref) async => cache),
        authenticatedHttpClientProvider.overrideWithValue(client),
        clockProvider.overrideWithValue(clock),
        myCardsProvider.overrideWith((ref) async => [card]),
      ],
    );
    return container;
  }

  test(
    'captured bill SMS shows the issuer bill, then payment marks it paid',
    () async {
      final store = cache.financialStore;
      store.replaceCards('user:account-a', [card]);
      // Known-empty coverage keeps every transaction read offline-local.
      store.saveTransactions(
        'user:account-a',
        [],
        completeQuery: const TransactionQuery(),
      );
      // Same fields SmsImportStore writes when the local parser reads
      // "statement generated ... Total amount due ... Minimum due ... Due date".
      store.saveObservation('user:account-a', 'obs1', {
        'id': 'obs1',
        'received_at': DateTime(2026, 10, 18).toUtc().toIso8601String(),
        'sender_bank': 'AXISBK',
        'card_last4': '7788',
        'event_type': 'bill',
        'statement_date': DateTime(2026, 10, 18).toIso8601String(),
        'statement_date_explicit': true,
        'due_date': DateTime(2026, 11, 2).toIso8601String(),
        'amount_due_paise': 2156000,
        'minimum_due_paise': 107800,
        'confidence': 0.95,
      });

      final container = offlineContainer();
      addTearDown(container.dispose);
      final subscription = container.listen(paymentsDueProvider, (_, next) {});
      addTearDown(subscription.close);
      final rows = await container
          .read(paymentsDueProvider.future)
          .timeout(const Duration(seconds: 10));

      expect(rows, hasLength(1));
      final bill = rows.single.bill;
      expect(bill, isNotNull);
      expect(bill!.statementDate, DateTime(2026, 10, 18));
      expect(bill.dueDate, DateTime(2026, 11, 2));
      expect(bill.amountDue, Money.fromRupees(21560));
      expect(bill.minimumDue, Money.fromRupees(1078));
      expect(bill.isPaid, isFalse);
      expect(bill.outstanding, Money.fromRupees(21560));

      // The payment receipt arrives (imported SMS or server sync, either way
      // it lands in the local store before the screen re-reads the ledger).
      store.saveTransactions('user:account-a', [
        TransactionEntry(
          id: 'pay1',
          amount: Money.fromRupees(21560),
          occurredAt: DateTime(2026, 10, 21),
          merchantName: 'Credit card bill payment',
          entryKind: TxnEntryKind.transfer,
          instrument: TxnInstrument.creditCard,
          source: 'sms',
          status: 'active',
        ),
      ], completeQuery: const TransactionQuery());
      await Future<void>.delayed(Duration.zero);
      final ledger = await container
          .read(cardBillLedgerProvider.future)
          .timeout(const Duration(seconds: 10));
      expect(ledger['card']!.current!.isPaid, isTrue);
      expect(ledger['card']!.current!.outstanding, Money.fromRupees(0));
    },
  );

  test('an empty ledger refreshes when its first bill arrives', () async {
    final store = cache.financialStore;
    store.replaceCards('user:account-a', [card]);
    store.saveTransactions('user:account-a', [], completeQuery: const TransactionQuery());
    final container = offlineContainer();
    addTearDown(container.dispose);
    final subscription = container.listen(cardBillLedgerProvider, (_, _) {});
    addTearDown(subscription.close);
    expect(await container.read(cardBillLedgerProvider.future), isEmpty);
    store.saveObservation('user:account-a', 'first-bill', {
      'id': 'first-bill', 'event_type': 'bill', 'card_last4': '7788',
      'received_at': DateTime(2026, 10, 18).toIso8601String(),
      'statement_date': DateTime(2026, 10, 18).toIso8601String(),
      'statement_date_explicit': true,
      'due_date': DateTime(2026, 11, 2).toIso8601String(),
      'amount_due_paise': 10000,
    });
    await Future<void>.delayed(Duration.zero);
    final ledger = await container.read(cardBillLedgerProvider.future);
    expect(ledger['card']!.current!.amountDue, Money.fromRupees(100));
  });

  test('reminder without a stated statement date keeps the unverified claim '
      'off the screen', () async {
    final store = cache.financialStore;
    store.replaceCards('user:account-a', [card]);
    store.saveTransactions(
      'user:account-a',
      [],
      completeQuery: const TransactionQuery(),
    );
    // A bare reminder: statement date is the received date (not explicit),
    // so the ledger cycle anchor is unverified and the row must not appear.
    store.saveObservation('user:account-a', 'obs2', {
      'id': 'obs2',
      'received_at': DateTime(2026, 10, 16).toUtc().toIso8601String(),
      'sender_bank': 'AXISBK',
      'card_last4': '7788',
      'event_type': 'bill',
      'due_date': DateTime(2026, 11, 2).toIso8601String(),
      'amount_due_paise': 2156000,
      'confidence': 0.6,
    });

    final container = offlineContainer();
    addTearDown(container.dispose);
    final subscription = container.listen(paymentsDueProvider, (_, next) {});
    addTearDown(subscription.close);
    final rows = await container
        .read(paymentsDueProvider.future)
        .timeout(const Duration(seconds: 10));
    expect(rows, isEmpty);
  });
}
