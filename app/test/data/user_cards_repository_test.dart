import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Task 11: statement_day/opened_on now come back from GET /user-cards
/// (previously computed server-side for cap/milestone period math but never
/// returned to a client) — Billing Cycle Float needs both.
void main() {
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
}
