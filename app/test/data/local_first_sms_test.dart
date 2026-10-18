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
    'a locally captured reminder supplies due dates on a cold offline read',
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
      expect(due.single.card.dueDay, 20);
      expect(due.single.loggedThisCycle.paise, 0);
    },
  );
}
