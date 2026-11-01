import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/sms_fact_contract.dart';

Map<String, dynamic> _fixture() => jsonDecode(
      File('test/fixtures/sms_category_taxonomy_v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;

List<String> _slugs(Map<String, dynamic> fixture) =>
    (fixture['canonicalSpendSlugs'] as List).cast<String>();

Map<String, dynamic> _rule(String category) => {
      'merchantKey': 'EXAMPLE CAFE',
      'senderKey': 'TX-CAFE-S',
      'contextKey': 'DINING',
      'factFamily': 'posted_movement',
      'categorySlug': category,
      'supportCount': 10,
      'agreementBp': 10000,
    };

void main() {
  test('mobile SMS fact and downloaded-rule contracts match taxonomy v1', () {
    final fixture = _fixture();
    final expected = _slugs(fixture);

    expect(fixture['contractId'], 'sms-category-vocabulary');
    expect(fixture['version'], 1);
    expect(smsFactContractVersion, 1);
    expect(smsSpendCategories, expected);
    expect(SmsSharedCategoryRule.allowedCategories, expected.toSet());

    for (final slug in expected) {
      expect(
        SmsSharedCategoryRule.fromJson(_rule(slug)),
        isNotNull,
        reason: 'canonical slug $slug must be accepted by shared rules',
      );
    }
  });

  test('Sports proposals and historical non-spend labels stay outside v1', () {
    final fixture = _fixture();
    final notApproved = (fixture['notApprovedCandidates'] as List).cast<String>();
    final legacy =
        (fixture['legacyOutsideSmsSpendVocabulary'] as List).cast<String>();

    for (final slug in [...notApproved, ...legacy]) {
      expect(
        SmsSharedCategoryRule.fromJson(_rule(slug)),
        isNull,
        reason: '$slug must not enter the v1 downloaded shared-rule cache',
      );
    }
  });
}
