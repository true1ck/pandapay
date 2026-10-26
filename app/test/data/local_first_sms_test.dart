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
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  const body =
      'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 16-Oct-26.';
  final token =
      'e30.${base64Url.encode(utf8.encode('{"sub":"account-a"}')).replaceAll('=', '')}.sig';
  late AppDatabase db;
  late ResponseCache cache;
  List<UserCard> capturedCards() => cache.financialStore
      .entities('user:account-a', 'cards')
      .map(UserCard.fromJson)
      .toList();
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
    expect(SmsIntakeRepository(db).pending('user:account-a'), isEmpty);
  });

  test(
    'generic Tata Neu HDFC bill does not teach the wrong card when two HDFC cards exist',
    () {
      cache.financialStore.replaceCards('user:account-a', [
        UserCard.fromJson({
          'id': 'moneyback',
          'card_product_id': 'moneyback',
          'card_name': 'MoneyBack+ Credit Card',
          'last4': '8708',
          'is_default': false,
        }),
        UserCard.fromJson({
          'id': 'tata-neu',
          'card_product_id': 'tata-neu',
          'card_name': 'Tata Neu Plus HDFC Bank Credit Card',
          'last4': '1366',
          'is_default': false,
        }),
      ]);

      SmsImportStore(cache.financialStore).capture(
        'user:account-a',
        QueuedSms(
          sender: 'JX-TNBPAY-S',
          body:
              'Your HDFC BANK CREDIT CARD bill of Rs.1147.00 is generated. Pay by 2026-09-08 to avoid late charges.',
          receivedAt: DateTime(2026, 8, 29),
        ),
      );

      final cards = cache.financialStore
          .entities('user:account-a', 'cards')
          .map(UserCard.fromJson)
          .toList();
      expect(cards.every((card) => card.dueDay == null), isTrue);
      expect(cards.every((card) => card.statementDay == null), isTrue);
    },
  );

  test('rich local bill commitments are acknowledged without raw upload', () {
    const bill =
        'Alegra Broadband ... Payment of Rs.800/- is due on 24-11-2026.';
    SmsImportStore(cache.financialStore).capture(
      'user:account-a',
      QueuedSms(
        sender: 'TNBPAY',
        body: bill,
        receivedAt: DateTime(2026, 10, 18),
      ),
    );

    expect(SmsIntakeRepository(db).pending('user:account-a'), isEmpty);
    final observation = cache.financialStore
        .entities('user:account-a', 'sms_observations')
        .single;
    expect(observation['sample_body'], bill);
    expect(observation['event_type'], 'bill');
    expect(
      db.db.select('SELECT id FROM local_commitments WHERE namespace=?', [
        'user:account-a',
      ]),
      hasLength(1),
    );
  });

  test('Axio Pay Later bill is stored only as an upcoming commitment', () {
    const namespace = 'user:axio-pay-later';
    const bill =
        'Your Pay Later bill of Rs 1038 will be debited on 5th of this month '
        'from registered bank a/c. View Bill https://u.axio.co/axo/example -axio';

    SmsImportStore(cache.financialStore).capture(
      namespace,
      QueuedSms(
        sender: 'VM-axioFS',
        body: bill,
        receivedAt: DateTime(2026, 11, 1, 9, 30),
      ),
    );

    final commitments = db.db.select(
      'SELECT payload FROM local_commitments WHERE namespace=?',
      [namespace],
    );
    expect(commitments, hasLength(1));
    final commitment = jsonDecode(commitments.single['payload'] as String);
    expect(commitment['title'], 'Axio Pay Later');
    expect(commitment['amount_paise'], 103800);
    expect(commitment['due_on'], DateTime(2026, 11, 5).toIso8601String());
    expect(cache.financialStore.bankAccounts(namespace), isEmpty);
    expect(cache.financialStore.entities(namespace, 'transactions'), isEmpty);
  });

  test('insurance renewals survive triage and use only evidenced cadence', () {
    for (final (evidence, cadence) in [
      ('', 'oneTime'),
      ('Monthly premium.', 'monthly'),
      ('Quarterly premium.', 'quarterly'),
      ('Half-yearly premium.', 'halfYearly'),
      ('Annual premium.', 'annual'),
    ]) {
      final namespace = 'user:insurance-$cadence';
      final body = 'Your vehicle insurance expires on 25-Oct-2027. $evidence';
      expect(classifySmsTriage('VM-HDFCER-S', body).kind,
          SmsTriageKind.financialCandidate);
      SmsImportStore(cache.financialStore).capture(namespace, QueuedSms(
        sender: 'VM-HDFCER-S', body: body,
        receivedAt: DateTime(2026, 10, 22),
      ));
      final commitments = db.db.select(
        'SELECT payload FROM local_commitments WHERE namespace=?', [namespace],
      );
      final commitment = jsonDecode(commitments.single['payload'] as String);
      expect(commitment['cadence'], cadence);
      expect(cache.financialStore.entities(namespace, 'sms_observations'), hasLength(1));
      expect(cache.financialStore.entities(namespace, 'transactions'), isEmpty);
    }
    const expiry = 'Your vehicle insurance expires tomorrow. Renew now.';
    expect(classifySmsTriage('VM-HDFCER-P', expiry).kind,
        SmsTriageKind.financialCandidate);
    expect(classifySmsTriage('VM-HDFCER-S', '$expiry OTP 123456').kind,
        SmsTriageKind.sensitive);
    expect(classifySmsTriage('9876543210', expiry).kind,
        SmsTriageKind.unrelated);
    expect(capturesFinancialSms('Buy insurance now! Premium Rs 1000.',
        sender: 'VM-HDFCER-P'), isFalse);
  });

  test('capture and historical reads preserve explicitly cleared user dates', () {
    cache.financialStore.replaceCards('user:account-a', [
      const UserCard(
        id: 'user-cleared', cardProductId: 'credit', cardName: 'Credit Card',
        isDefault: false, last4: '8708',
        dueDaySource: 'user', statementDaySource: 'user',
      ),
    ]);
    SmsImportStore(cache.financialStore).capture('user:account-a', QueuedSms(
      sender: 'HDFCBK',
      body: 'Your credit card XX8708 statement is generated. Total amount due Rs 800. Pay by 24-10-2026.',
      receivedAt: DateTime(2026, 10, 20),
    ));
    final card = capturedCards().single;
    expect(card.dueDay, isNull);
    expect(card.statementDay, isNull);
    expect(card.dueDaySource, 'user');
    expect(card.statementDaySource, 'user');
  });

  test('aggregator utility notices cannot teach a saved HDFC card cycle', () {
    cache.financialStore.replaceCards('user:account-a', [
      UserCard(id: 'hdfc', cardProductId: 'hdfc', cardName: 'HDFC Credit Card',
        cardType: 'credit', last4: '8708', isDefault: false),
    ]);
    SmsImportStore(cache.financialStore).capture('user:account-a', QueuedSms(
      sender: 'JX-TNBPAY-S',
      body: 'Alegra Broadband ... Payment of Rs.800/- is due on 24-10-2026.',
      receivedAt: DateTime(2026, 10, 20),
    ));
    final card = capturedCards().single;
    expect(card.dueDay, isNull);
    expect(card.statementDay, isNull);
  });

  test('ambiguous card suffixes never teach multiple credit-card cycles', () {
    cache.financialStore.replaceCards('user:account-a', [
      for (final id in ['one', 'two'])
        UserCard(id: id, cardProductId: id, cardName: 'Credit Card $id',
          cardType: 'credit', last4: '8708', isDefault: false),
    ]);
    SmsImportStore(cache.financialStore).capture('user:account-a', QueuedSms(
      sender: 'HDFCBK',
      body: 'Your credit card XX8708 statement is generated. Total amount due Rs 800. Pay by 24-10-2026.',
      receivedAt: DateTime(2026, 10, 20),
    ));
    final cards = capturedCards();
    expect(cards.every((card) => card.dueDay == null && card.statementDay == null), isTrue);
  });

  test('AutoPay learns due day without claiming reminder arrival as statement day', () {
    cache.financialStore.replaceCards('user:account-a', [
      UserCard(id: 'active', cardProductId: 'hdfc', cardName: 'HDFC Credit Card',
        cardType: 'credit', last4: '8708', isDefault: false),
      UserCard(id: 'archived', cardProductId: 'hdfc', cardName: 'HDFC Credit Card',
        cardType: 'credit', last4: '8708', isDefault: false, isArchived: true),
      UserCard(id: 'debit', cardProductId: 'debit', cardName: 'HDFC Debit Card',
        cardType: 'debit', last4: '8708', isDefault: false),
    ]);
    SmsImportStore(cache.financialStore).capture('user:account-a', QueuedSms(
      sender: 'HDFCBK',
      body: 'AutoPay scheduled for your credit card ending in 8708 on 25-Oct-2026 for Rs 4500. Maintain sufficient balance in your account.',
      receivedAt: DateTime(2026, 10, 20),
    ));
    final cards = capturedCards();
    final active = cards.singleWhere((card) => card.id == 'active');
    expect(active.dueDay, 25);
    expect(active.dueDaySource, 'sms');
    expect(cards.every((card) => card.statementDay == null), isTrue);
    expect(cards.where((card) => card.id != 'active').every((card) => card.dueDay == null), isTrue);
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
      SmsImportStore(
        cache.financialStore,
      ).captureBatch('user:account-a', [jio, axis]);

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
      final promoKey = smsSourceKey('user:account-a', jio.sender, jio.body);
      final promoDecision = intake.decision('user:account-a', promoKey);
      expect(promoDecision, isNotNull);
      expect(promoDecision!.decision, 'ignored_promotion');
      expect(promoDecision.state, 'final');
      final observations = cache.financialStore.entities(
        'user:account-a',
        'sms_observations',
      );
      expect(observations.map((row) => row['event_type']), contains('autopay'));
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
