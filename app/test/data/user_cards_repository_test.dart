import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Task 11: statement_day/opened_on now come back from GET /user-cards
/// (previously computed server-side for cap/milestone period math but never
/// returned to a client) — Billing Cycle Float needs both.
void main() {
  group('SMS history reconciliation version', () {
    test(
      'old API responses remain retryable after the v2 app update',
      () async {
        for (final response in [
          http.Response('{}', 404),
          http.Response(jsonEncode({'duplicateSuppressed': 1}), 200),
        ]) {
          final repository = UserCardsRepository(
            apiBaseUrl: 'https://api.test',
            accessToken: 'session-token',
            client: MockClient((_) async => response),
          );
          final repaired = await repository.reconcileSmsHistory();
          expect(repaired.reconciliationVersion, 0);
        }
      },
    );

    test('v2 response reports candidates for review refresh', () async {
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'reconciliationVersion': 2,
              'crossSourceCandidatesCreated': 1,
              'classificationReclassified': 2,
              'remappedTransactions': 3,
            }),
            200,
          ),
        ),
      );
      final repaired = await repository.reconcileSmsHistory();
      expect(repaired.reconciliationVersion, 2);
      expect(repaired.crossSourceCandidatesCreated, 1);
      expect(repaired.classificationReclassified, 2);
      expect(repaired.remappedTransactions, 3);
    });
  });

  group('TransactionEntry category labels', () {
    test('does not invent an Other subcategory when none was supplied', () {
      final transaction = TransactionEntry.fromJson({
        'id': 'txn-dining',
        'amount_inr': 125,
        'occurred_at': '2026-10-20T12:00:00Z',
        'category_name': 'Dining',
        'source': 'manual',
        'status': 'active',
      });

      expect(transaction.categoryName, 'Dining');
      expect(transaction.subcategoryName, isNull);
      expect(transaction.categoryLabel, 'Dining');
    });

    test('keeps Other for an explicitly unclassified subcategory', () {
      final transaction = TransactionEntry.fromJson({
        'id': 'txn-dining-other',
        'amount_inr': 125,
        'occurred_at': '2026-10-20T12:00:00Z',
        'category_name': 'Dining',
        'subcategory_name': 'Unclassified',
        'source': 'manual',
        'status': 'active',
      });

      expect(transaction.categoryLabel, 'Dining · Other');
    });
  });

  group('Home engagement check-in', () {
    test('submits only the fresh server-signed receipt', () async {
      final requests = <http.Request>[];
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'session-token',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/home-summary') {
            return http.Response(
              jsonEncode({
                'homeSummary': {
                  'rewardsThisMonthInr': 0,
                  'rewardsAllTimeInr': 0,
                  'transactionCount': 0,
                  'streakDays': 0,
                  'engagementReceipt': 'signed-short-lived-receipt',
                },
              }),
              200,
            );
          }
          expect(request.url.path, '/engagement/check-in');
          return http.Response(
            jsonEncode({'recorded': true, 'qualified': true}),
            200,
          );
        }),
      );

      final recorded = await repository.recordHomeEngagementCheckIn(
        anchor: DateTime.utc(2026, 10, 21),
        timeZone: 'Asia/Kolkata',
      );

      expect(recorded, isTrue);
      expect(requests, hasLength(2));
      expect(
        requests.every(
          (request) =>
              request.headers['authorization'] == 'Bearer session-token',
        ),
        isTrue,
      );
      expect(jsonDecode(requests[1].body), {
        'receiptToken': 'signed-short-lived-receipt',
      });
    });

    test(
      'does not post when the live summary has no campaign receipt',
      () async {
        var requestCount = 0;
        final repository = UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'session-token',
          client: MockClient((request) async {
            requestCount += 1;
            return http.Response(
              jsonEncode({
                'homeSummary': {
                  'rewardsThisMonthInr': 0,
                  'rewardsAllTimeInr': 0,
                  'transactionCount': 0,
                  'streakDays': 0,
                  'engagementReceipt': null,
                },
              }),
              200,
            );
          }),
        );

        expect(await repository.recordHomeEngagementCheckIn(), isFalse);
        expect(requestCount, 1);
      },
    );
  });

  group('UserCard.fromJson', () {
    test('parses statement_day and opened_on when both are set', () {
      final card = UserCard.fromJson({
        'id': 'uc-1',
        'card_product_id': 'cp-1',
        'nickname': null,
        'card_name': 'Test Card',
        'is_default': false,
        'statement_day': 15,
        'opened_on': '2025-03-10',
      });

      expect(card.statementDay, 15);
      expect(card.openedOn, DateTime(2025, 3, 10));
    });

    test('leaves both null when the card has never had them set', () {
      final card = UserCard.fromJson({
        'id': 'uc-1',
        'card_product_id': 'cp-1',
        'nickname': null,
        'card_name': 'Test Card',
        'is_default': false,
        'statement_day': null,
        'opened_on': null,
      });

      expect(card.statementDay, isNull);
      expect(card.openedOn, isNull);
    });

    test('defaults both to null when the keys are absent entirely', () {
      final card = UserCard.fromJson({
        'id': 'uc-1',
        'card_product_id': 'cp-1',
        'card_name': 'Test Card',
        'is_default': false,
      });

      expect(card.statementDay, isNull);
      expect(card.openedOn, isNull);
    });
  });

  group('manual transaction idempotency', () {
    test(
      'sends a caller-provided mutation id and accepts an exact-retry 200',
      () async {
        late Map<String, dynamic> requestBody;
        final repository = UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient((request) async {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'duplicate': true,
                'transaction': {'id': 'canonical-txn'},
              }),
              200,
            );
          }),
        );

        final id = await repository.logTransaction(
          userCardId: 'card-1',
          amount: Money.fromRupees(500),
          clientMutationId: 'fixed-mutation-id',
        );

        expect(id, 'canonical-txn');
        expect(requestBody['clientMutationId'], 'fixed-mutation-id');
      },
    );

    test(
      'generates a mutation id when a caller does not provide one',
      () async {
        late Map<String, dynamic> requestBody;
        final repository = UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient((request) async {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'transaction': {'id': 'new-txn'},
              }),
              201,
            );
          }),
        );

        await repository.logTransaction(
          userCardId: 'card-1',
          amount: Money.fromRupees(500),
        );

        expect(
          requestBody['clientMutationId'],
          matches(RegExp(r'^[0-9a-f-]{36}$')),
        );
      },
    );
  });

  test('SMS reconciliation tolerates an older API during rollout', () async {
    final repository = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((request) async => http.Response('Not found', 404)),
    );

    final result = await repository.reconcileSmsHistory();
    expect(result.duplicateSuppressed, 0);
    expect(result.reclassified, 0);
    expect(result.remainingLegacyRows, 0);
  });

  test('reads the server SMS checkpoint used for reset recovery', () async {
    final repository = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((request) async {
        expect(request.url.path, '/transactions/sms-import-state');
        return http.Response(
          jsonEncode({
            'smsObservationCount': 12,
            'latestSmsObservedAt': '2026-10-07T04:30:00.000Z',
          }),
          200,
        );
      }),
    );

    final state = await repository.fetchSmsImportState();
    expect(state.smsObservationCount, 12);
    expect(
      state.latestSmsObservedAt,
      DateTime.parse('2026-10-07T04:30:00.000Z'),
    );
  });

  test('tolerates an older API without the SMS checkpoint route', () async {
    final repository = UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((request) async => http.Response('Not found', 404)),
    );

    final state = await repository.fetchSmsImportState();
    expect(state.smsObservationCount, isNull);
  });

  test(
    'updates a transaction note through the dedicated note endpoint',
    () async {
      late http.Request request;
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'transaction': {'id': 'txn-1', 'note': 'remember this'},
            }),
            200,
          );
        }),
      );

      await repository.updateTransactionNote('txn-1', 'remember this');

      expect(request.method, 'PATCH');
      expect(request.url.path, '/transactions/txn-1/note');
      expect(jsonDecode(request.body), {'note': 'remember this'});
    },
  );

  test(
    'accepts a 200 when discovery links an existing card placeholder',
    () async {
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'linkedExisting': true,
              'userCard': {'id': 'uc-linked'},
            }),
            200,
          ),
        ),
      );

      expect(await repository.addCard('card-1', last4: '9087'), 'uc-linked');
    },
  );

  test(
    'exposes the duplicate-card API code for a friendly wallet message',
    () async {
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': 'card_already_added',
              'message': 'This card is already in your wallet.',
            }),
            409,
          ),
        ),
      );

      try {
        await repository.addCard('card-1');
        fail('expected duplicate-card error');
      } on ApiException catch (error) {
        expect(error.statusCode, 409);
        expect(error.errorCode, 'card_already_added');
        expect(error.userMessage, 'This card is already in your wallet.');
      }
    },
  );

  group('merchant category bulk boundary', () {
    test('parses a related preview and derives default selected ids', () async {
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.path,
            '/transactions/source/category-related-preview',
          );
          expect(request.url.queryParameters, {'targetCategoryId': 'food'});
          return http.Response(
            jsonEncode({
              'preview': {
                'preview_id': 'preview-1',
                'source_transaction_id': 'source',
                'target_category_id': 'food',
                'target_category_name': 'Food',
                'match_basis': 'vpa',
                'total_candidate_count': 2,
                'selectable_candidate_count': 2,
                'candidates': [
                  {
                    'id': 'other-1',
                    'occurred_at': '2026-10-05T00:00:00Z',
                    'amount_inr': 500,
                    'payment_source': 'UPI / bank account',
                    'selection_tier': 'default_selected',
                    'category_name': 'Other',
                    'updated_at': '2026-10-05T01:00:00Z',
                  },
                  {
                    'id': 'other-2',
                    'occurred_at': '2026-10-02T00:00:00Z',
                    'amount_inr': 777,
                    'payment_source': 'UPI / bank account',
                    'selection_tier': 'manual_review',
                    'category_name': 'Groceries',
                  },
                ],
              },
            }),
            200,
          );
        }),
      );

      final preview = await repository.fetchCategoryRelatedPreview(
        'source',
        targetCategoryId: 'food',
      );

      expect(preview.previewId, 'preview-1');
      expect(preview.matchBasis, RelatedTransactionMatchBasis.vpa);
      expect(preview.candidates, hasLength(2));
      expect(preview.defaultSelectedTransactionIds, ['other-1']);
      expect(preview.candidates[1].currentCategoryLabel, 'Groceries');
      expect(preview.candidates[0].updatedAt, isNotNull);
    });

    test('sends a deduplicated apply payload and parses the result', () async {
      late http.Request request;
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'operationId': 'operation-1',
              'changedCount': 2,
              'unchangedCount': 0,
              'targetCategoryId': 'food',
              'affectedTransactionIds': ['other-1', 'other-2'],
            }),
            200,
          );
        }),
      );

      final result = await repository.applyCategoryBulk(
        previewId: 'preview-1',
        selectedTransactionIds: const ['other-1', 'other-1', 'other-2'],
        targetCategoryId: 'food',
        idempotencyKey: 'idempotency-1',
      );

      expect(request.method, 'POST');
      expect(request.url.path, '/transactions/category-bulk-apply');
      expect(jsonDecode(request.body), {
        'previewId': 'preview-1',
        'selectedTransactionIds': ['other-1', 'other-2'],
        'targetCategoryId': 'food',
        'idempotencyKey': 'idempotency-1',
      });
      expect(result.operationId, 'operation-1');
      expect(result.changedCount, 2);
      expect(result.affectedTransactionIds, ['other-1', 'other-2']);
    });

    test('maps a stale preview response to a refreshable conflict', () async {
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': 'category_preview_stale',
              'message': 'Preview is stale',
            }),
            409,
          ),
        ),
      );

      expect(
        () => repository.applyCategoryBulk(
          previewId: 'preview-1',
          selectedTransactionIds: const ['other-1'],
          targetCategoryId: 'food',
          idempotencyKey: 'idempotency-1',
        ),
        throwsA(
          isA<CategoryBulkConflictException>()
              .having((error) => error.statusCode, 'status', 409)
              .having(
                (error) => error.errorCode,
                'code',
                'category_preview_stale',
              ),
        ),
      );
    });

    test(
      'can explicitly clear a category without changing other fields',
      () async {
        late Map<String, dynamic> body;
        final repository = UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient((request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('{}', 200);
          }),
        );

        await repository.clearTransactionCategory('txn-1');

        expect(body, {'categoryId': null, 'userCategoryId': null});
      },
    );

    test(
      'rejects bulk selection above the server limit before making a request',
      () async {
        var requests = 0;
        final repository = UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'token',
          client: MockClient((request) async {
            requests += 1;
            return http.Response('{}', 200);
          }),
        );

        expect(
          () => repository.applyCategoryBulk(
            previewId: 'preview-1',
            selectedTransactionIds: List<String>.generate(
              501,
              (index) => 'txn-$index',
            ),
            targetCategoryId: 'food',
          ),
          throwsArgumentError,
        );
        expect(requests, 0);
      },
    );
  });
}
