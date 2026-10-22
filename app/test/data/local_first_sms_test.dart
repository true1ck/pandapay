import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

void main() {
  const body =
      'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 16-Oct-26.';
  final token =
      'e30.${base64Url.encode(utf8.encode('{"sub":"account-a"}')).replaceAll('=', '')}.sig';
  late AppDatabase db;
  late ResponseCache cache;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
  });
  tearDown(() {
    cache.financialStore.dispose();
    db.close();
  });

  test('batch capture keeps both reminders without guessing a card due day', () {
    cache.financialStore.replaceCards('user:account-a', [
      UserCard.fromJson({
        'id': 'card',
        'card_product_id': 'product',
        'card_name': 'Card',
        'last4': '7788',
        'is_default': false,
        'statement_day': 5,
      }),
    ]);
    SmsImportStore(cache.financialStore).captureBatch('user:account-a', [
      for (final day in [20, 21])
        QueuedSms(
          sender: 'VM-ICICIB',
          body:
              'Your credit card XX7788 payment due on $day-Oct-2026. Total amount due INR 3000.',
          receivedAt: DateTime(2026, 10, 16),
        ),
    ]);
    final cards = cache.financialStore.entities('user:account-a', 'cards');
    expect(UserCard.fromJson(cards.single).dueDay, isNull);
    final observations = cache.financialStore.entities(
      'user:account-a',
      'sms_observations',
    );
    expect(observations, hasLength(2));
    expect(SmsIntakeRepository(db).pending('user:account-a'), hasLength(2));
  });

  test(
    'high-confidence promotion and AutoPay messages stop locally without spending',
    () {
      final jio = QueuedSms(
        sender: 'JM-JIOINF-P',
        body:
            'Want to keep your number active? Recharge with Rs.349 today and get an additional Rs.349 recharge FREE. Offer valid today.',
        receivedAt: DateTime(2026, 10, 18),
      );
      final axis = QueuedSms(
        sender: 'VM-AXISBK-S',
        body:
            'AutoPay activation successful. Txn amt: INR 0.00 Merchant: OpenAI LLC Axis Bank Card no.: XX7105 Max limit: INR 1999.00.',
        receivedAt: DateTime(2026, 10, 18),
      );
      SmsImportStore(cache.financialStore).captureBatch(
        'user:account-a',
        [jio, axis],
      );

      expect(SmsIntakeRepository(db).pending('user:account-a'), isEmpty);
      expect(
        cache.financialStore.transactions(
          'user:account-a',
          const TransactionQuery(),
        ),
        isNull,
      );
      // The promotion is recorded as a decided observation — no raw body is
      // retained, no spending, no pending intake — per the SMS intelligence
      // contract (see sms_intelligence_scenarios_test.dart Scenario 1).
      final intake = SmsIntakeRepository(db);
      final promoKey = smsSourceKey(
        'user:account-a',
        jio.sender,
        jio.body,
      );
      final promoDecision = intake.decision('user:account-a', promoKey);
      expect(promoDecision, isNotNull);
      expect(promoDecision!.decision, 'ignored_promotion');
      expect(promoDecision.state, 'final');
      final observations = cache.financialStore.entities(
        'user:account-a',
        'sms_observations',
      );
      expect(
        observations.map((row) => row['event_type']),
        contains('autopay'),
      );
    },
  );

  test(
    'balance-only SMS feeds account snapshots without creating spending',
    () {
      SmsImportStore(cache.financialStore).capture(
        'user:account-a',
        QueuedSms(
          sender: 'VM-HDFCBK-B',
          body: 'Your account XX1234 available balance is INR 3000.',
          receivedAt: DateTime(2026, 10, 18),
        ),
      );

      expect(SmsIntakeRepository(db).pending('user:account-a'), isEmpty);
      expect(
        cache.financialStore.transactions(
          'user:account-a',
          const TransactionQuery(),
        ),
        isNull,
      );
      final account = cache.financialStore
          .bankAccounts('user:account-a')
          .single;
      expect(account.accountLast4, '1234');
      expect(account.availableBalance?.rupees, 3000);
    },
  );

  test(
    'sender variants of one bank account collapse and keep the newest balance',
    () {
      final store = SmsImportStore(cache.financialStore);
      store.capture(
        'user:account-a',
        QueuedSms(
          sender: 'AX-HDFCBK',
          body: 'Your account XX1797 available balance is INR 7000.',
          receivedAt: DateTime.utc(2026, 10, 20),
        ),
      );
      store.capture(
        'user:account-a',
        QueuedSms(
          sender: 'AD-HDFCBK-S',
          body: 'Your account XX1797 available balance is INR 5000.',
          receivedAt: DateTime.utc(2026, 10, 18),
        ),
      );
      store.capture(
        'user:account-a',
        QueuedSms(
          sender: 'AD-HDFCBK',
          body: 'Rs.200 debited from your account XX1797.',
          receivedAt: DateTime.utc(2026, 10, 21),
        ),
      );
      final accounts = cache.financialStore.bankAccounts('user:account-a');
      expect(accounts, hasLength(1));
      expect(accounts.single.accountLast4, '1797');
      expect(accounts.single.issuerShortName, 'HDFC Bank');
      expect(accounts.single.availableBalance?.rupees, 7000);
      // Use explicit UTC instants so this test is independent of the
      // machine's timezone (developer laptops are often IST; CI is UTC).
      expect(accounts.single.latestSmsAt?.toUtc(), DateTime.utc(2026, 10, 21));
    },
  );

  test(
    'unsupported formats move into account-scoped review without becoming spending',
    () async {
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        inner: MockClient(
          (request) async => request.method == 'POST'
              ? http.Response('{"parsed":false,"reason":"no_regex_match"}', 200)
              : http.Response('{"transactions":[]}', 200),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => token),
          responseCacheProvider.overrideWith((ref) async => cache),
          authenticatedHttpClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.close);
      await container
          .read(userCardsRepositoryProvider)!
          .logTransactionFromSms(
            sender: 'VM-BANK',
            body: 'INR 50 charged in an unfamiliar template.',
            occurredAt: DateTime(2026, 10, 16),
          );
      expect(
        await container.read(needsReviewRepositoryProvider).fetchAll(),
        hasLength(1),
      );
      expect(SmsIntakeRepository(db).pending('user:account-a'), isEmpty);
      expect(
        cache.financialStore.transactions(
          'user:account-a',
          const TransactionQuery(),
        ),
        isNull,
      );
      container.read(accessTokenProvider.notifier).state =
          'e30.${base64Url.encode(utf8.encode('{"sub":"account-b"}')).replaceAll('=', '')}.sig';
      expect(
        await container.read(needsReviewRepositoryProvider).fetchAll(),
        isEmpty,
      );
    },
  );

  test(
    'a failed upload leaves parsed data and durable intake on the device',
    () async {
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        inner: MockClient((_) async => throw http.ClientException('offline')),
      );
      final container = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => token),
          responseCacheProvider.overrideWith((ref) async => cache),
          authenticatedHttpClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.close);
      await expectLater(
        container
            .read(userCardsRepositoryProvider)!
            .logTransactionFromSms(
              sender: 'VM-ICICIB',
              body: body,
              occurredAt: DateTime(2026, 10, 16),
            ),
        throwsA(isA<http.ClientException>()),
      );
      final snapshot = cache.financialStore.transactions(
        'user:account-a',
        const TransactionQuery(),
      )!;
      expect(snapshot.rows.single.amount.rupees, 250);
      expect(SmsIntakeRepository(db).pending('user:account-a'), hasLength(1));
    },
  );

  test(
    'successful retry reconciles the provisional row without duplicate spending',
    () async {
      final key = smsSourceKey('user:account-a', 'VM-ICICIB', body);
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        inner: MockClient(
          (request) async => request.method == 'POST'
              ? http.Response(
                  jsonEncode({
                    'parsed': true,
                    'transaction': {'id': 'server-id'},
                  }),
                  201,
                )
              : http.Response(
                  jsonEncode({
                    'transactions': [
                      {
                        'id': 'server-id',
                        'source_key': key,
                        'amount_inr': 250,
                        'occurred_at': '2026-10-16T00:00:00.000',
                        'instrument': 'credit_card',
                        'entry_kind': 'spend',
                        'source': 'sms',
                        'status': 'active',
                      },
                    ],
                  }),
                  200,
                ),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => token),
          responseCacheProvider.overrideWith((ref) async => cache),
          authenticatedHttpClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.close);
      await container
          .read(userCardsRepositoryProvider)!
          .logTransactionFromSms(
            sender: 'VM-ICICIB',
            body: body,
            occurredAt: DateTime(2026, 10, 16),
          );
      expect(
        cache.financialStore
            .transactions('user:account-a', const TransactionQuery())!
            .rows
            .single
            .id,
        'server-id',
      );
      expect(SmsIntakeRepository(db).pending('user:account-a'), isEmpty);
    },
  );

  test(
    'a locally captured reminder does not claim an unverified due day offline',
    () async {
      cache.financialStore.replaceCards('user:account-a', [
        UserCard.fromJson({
          'id': 'card',
          'card_product_id': 'product',
          'card_name': 'Card',
          'last4': '7788',
          'is_default': false,
          'statement_day': 5,
        }),
      ]);
      SmsImportStore(cache.financialStore).capture(
        'user:account-a',
        QueuedSms(
          sender: 'VM-ICICIB',
          body:
              'Your credit card XX7788 payment due on 20-Oct-2026. Total amount due INR 3000.',
          receivedAt: DateTime(2026, 10, 16),
        ),
      );
      cache.financialStore.saveTransactions(
        'user:account-a',
        [],
        completeQuery: const TransactionQuery(),
      );
      final client = AuthenticatedHttpClient(
        refreshAccessToken: () async => null,
        inner: MockClient((_) async => throw http.ClientException('offline')),
      );
      final container = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => token),
          responseCacheProvider.overrideWith((ref) async => cache),
          authenticatedHttpClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.close);
      final subscription = container.listen(paymentsDueProvider, (_, next) {});
      addTearDown(subscription.close);
      final due = await container
          .read(paymentsDueProvider.future)
          .timeout(const Duration(seconds: 5));
      expect(due, isEmpty);
      final cards = cache.financialStore.entities('user:account-a', 'cards');
      expect(UserCard.fromJson(cards.single).dueDay, isNull);
    },
  );

  test(
    'a UPI-platform sender quoting a counterpart account mints no account row',
    () {
      final store = SmsImportStore(cache.financialStore);
      store.capture(
        'user:account-a',
        QueuedSms(
          sender: 'SBIUPI',
          body:
              'Your A/c XX2626 received Rs.500 from PQR on 12-01-25. '
              'Not you? Call 1800. SBIPU? Msg STOP.',
          receivedAt: DateTime(2026, 10, 20),
        ),
      );
      store.capture(
        'user:account-a',
        QueuedSms(
          sender: 'KOTAKB',
          body:
              'Rs.900 debited from a/c XX2626 net banking. New Bal: Rs.45,120.',
          receivedAt: DateTime(2026, 10, 21),
        ),
      );
      final accounts = cache.financialStore.bankAccounts('user:account-a');
      // One real account (Kotak 2626) with its balance; the SBIUPI notice
      // quoted the same last4 but belongs to the counterparty's snapshot.
      expect(accounts, hasLength(1));
      expect(accounts.single.issuerSlug, 'kotak');
      expect(accounts.single.accountLast4, '2626');
      expect(accounts.single.availableBalance?.rupees, 45120);
    },
  );
}
