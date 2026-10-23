import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/merchant_issue_rules_repository.dart';

void main() {
  test('preview sends the typed issue_flag action and parses candidates', () async {
    late http.Request request;
    final repository = MerchantIssueRulesRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response(
          jsonEncode({
            'preview': {
              'previewId': 'preview-1',
              'sourceTransactionId': 'txn-1',
              'displayMerchantName': 'Coffee House',
              'matchBasis': 'vpa',
              'flag': 'wrong_reward',
              'candidates': [
                {
                  'id': 'txn-2',
                  'occurredAt': '2026-10-20T09:00:00Z',
                  'amountInr': 240,
                  'merchantName': 'Coffee House',
                  'isDefaultSelected': true,
                },
              ],
            },
          }),
          200,
        );
      }),
    );

    final preview = await repository.preview(
      sourceTransactionId: 'txn-1',
      issueKind: MerchantIssueKind.wrongReward,
    );

    expect(jsonDecode(request.body), {
      'sourceTransactionId': 'txn-1',
      'action': 'flag',
      'flag': 'wrong_reward',
    });
    expect(preview.previewId, 'preview-1');
    expect(preview.candidates.single.id, 'txn-2');
  });

  test('create future flag sends action without category fields', () async {
    late http.Request request;
    final repository = MerchantIssueRulesRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response('{}', 201);
      }),
    );

    await repository.createFutureRule(
      sourceTransactionId: 'txn-1',
      issueKind: MerchantIssueKind.cardNotRecognized,
      idempotencyKey: 'idem-flag-2',
    );

    expect(jsonDecode(request.body), {
      'sourceTransactionId': 'txn-1',
      'action': 'flag',
      'flag': 'card_not_recognized',
      'idempotencyKey': 'idem-flag-2',
    });
  });
}
