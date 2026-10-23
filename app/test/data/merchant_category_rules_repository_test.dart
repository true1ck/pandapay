import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/merchant_category_rules_repository.dart';

void main() {
  test(
    'previews a rule from the source transaction and parses examples',
    () async {
      late http.Request request;
      final repository = MerchantCategoryRulesRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'preview': {
                'source_transaction_id': 'txn-1',
                'display_merchant_name': 'Coffee House',
                'match_basis': 'vpa',
                'category_id': 'food',
                'category_name': 'Food',
                'can_create': true,
                'examples': [
                  {
                    'id': 'txn-2',
                    'occurred_at': '2026-10-20T09:00:00Z',
                    'amount_inr': 240,
                    'merchant_name': 'Coffee House',
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
        categoryId: 'food',
      );

      expect(request.method, 'POST');
      expect(request.url.path, '/merchant-category-rules/preview');
      expect(jsonDecode(request.body), {
        'sourceTransactionId': 'txn-1',
        'categoryId': 'food',
      });
      expect(preview.matchBasis, MerchantRuleMatchBasis.vpa);
      expect(preview.displayMerchantName, 'Coffee House');
      expect(preview.examples.single.id, 'txn-2');
    },
  );

  test('create includes idempotency and maps a concurrent conflict', () async {
    late http.Request request;
    final repository = MerchantCategoryRulesRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response(
          jsonEncode({
            'error': 'merchant_rule_conflict',
            'message': 'A rule already exists.',
            'current_rule': {
              'id': 'rule-1',
              'display_merchant_name': 'Coffee House',
              'match_basis': 'vpa',
              'category_id': 'food',
              'is_active': true,
              'version': 4,
            },
          }),
          409,
        );
      }),
    );

    await expectLater(
      repository.create(
        sourceTransactionId: 'txn-1',
        categoryId: 'food',
        idempotencyKey: 'idem-1',
      ),
      throwsA(
        isA<MerchantRuleConflictException>()
            .having((error) => error.currentRule?.id, 'rule id', 'rule-1')
            .having((error) => error.statusCode, 'status', 409),
      ),
    );
    expect(jsonDecode(request.body)['idempotencyKey'], 'idem-1');
  });

  test('updates and disables with owner-safe version payloads', () async {
    var call = 0;
    final repository = MerchantCategoryRulesRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((request) async {
        call++;
        expect(request.url.path, '/merchant-category-rules/rule-1');
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        if (call == 1) {
          expect(request.method, 'PATCH');
          expect(body, {'categoryId': 'travel', 'expectedVersion': 3});
        } else {
          expect(request.method, 'DELETE');
          expect(body, {'expectedVersion': 4});
        }
        return http.Response(
          jsonEncode({
            'rule': {
              'id': 'rule-1',
              'display_merchant_name': 'Coffee House',
              'match_basis': 'vpa',
              'category_id': call == 1 ? 'travel' : 'food',
              'is_active': call == 1,
              'version': call + 3,
            },
          }),
          200,
        );
      }),
    );

    final updated = await repository.update(
      'rule-1',
      categoryId: 'travel',
      expectedVersion: 3,
    );
    final disabled = await repository.disable('rule-1', expectedVersion: 4);
    expect(updated.categoryId, 'travel');
    expect(disabled.isActive, isFalse);
  });

  test('lists active and disabled rules', () async {
    final repository = MerchantCategoryRulesRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((request) async {
        expect(request.url.queryParameters['includeDisabled'], 'true');
        return http.Response(
          jsonEncode({
            'rules': [
              {
                'id': 'rule-1',
                'merchant_name': 'Coffee House',
                'match_basis': 'strict_name',
                'category_id': 'food',
                'is_active': false,
                'version': 2,
              },
            ],
          }),
          200,
        );
      }),
    );

    final rules = await repository.fetchRules();
    expect(rules.single.isActive, isFalse);
    expect(rules.single.matchBasis, MerchantRuleMatchBasis.strictName);
  });

  test('rejects a rule request without a category identity', () async {
    final repository = MerchantCategoryRulesRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'token',
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    expect(
      () => repository.preview(sourceTransactionId: 'txn-1'),
      throwsArgumentError,
    );
  });
}
