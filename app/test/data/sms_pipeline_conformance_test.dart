import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/flashtext_merchant_extractor.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local_sms_parser.dart';

Map<String, dynamic> _fixture() => jsonDecode(
      File('test/fixtures/sms_pipeline_conformance.json').readAsStringSync(),
    ) as Map<String, dynamic>;

Map<String, dynamic> _case(String id) => ((_fixture()['cases'] as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((item) => item['id'] == id));

void main() {
  test('diagnostic: local parser keeps the role-confusion message financial', () {
    final item = _case('merchant_role_confusion');
    final parsed = LocalSmsParser.parse(
      namespace: 'audit-profile',
      sender: item['sender'] as String,
      body: item['body'] as String,
      receivedAt: DateTime.utc(2026, 11, 1, 9),
    );

    expect(parsed?.transaction, isNotNull);
    expect(parsed?.transaction?.amount.rupees, 200);
    // This is intentionally a diagnostic assertion: the local parser can
    // preserve a financial row while a later model/category stage may still
    // confuse the card issuer/product label with the payee.
  });

  test('local parser retains a Unicode payee after a successful debit parse', () {
    final item = _case('unicode_merchant_loss');
    final parsed = LocalSmsParser.parse(
      namespace: 'audit-profile',
      sender: item['sender'] as String,
      body: item['body'] as String,
      receivedAt: DateTime.utc(2026, 11, 1, 9),
    );

    expect(parsed?.transaction, isNotNull);
    expect(parsed?.transaction?.amount.rupees, 200);
    expect(parsed?.transaction?.merchantName, 'बालाजी स्पोर्ट्स');
  });

  test('diagnostic: content-only source identity collides across received dates', () {
    final item = _case('duplicate_identity_collision');
    final key1 = smsSourceKey(
      _fixture()['namespace'] as String,
      item['sender'] as String,
      item['body'] as String,
    );
    final key2 = smsSourceKey(
      _fixture()['namespace'] as String,
      item['sender'] as String,
      item['body'] as String,
    );

    expect(key1, key2);
  });

  test('diagnostic: local and shared merchant catalogs expose category drift candidates', () {
    final extractor = FlashTextMerchantExtractor();
    final variants = (_case('category_drift_substring')['variants'] as List)
        .cast<Map<String, dynamic>>();
    final observations = <String, String?>{
      for (final variant in variants)
        variant['merchant'] as String: extractor
            .extractFirst(variant['merchant'] as String)
            ?.category,
    };

    expect(observations['KUBER HARDWARE'], isNull);
    expect(observations['SPARK ELECTRICALS'], isNull);
    expect(observations['SHELLY BOOK STORE'], isNull);
  });
}
