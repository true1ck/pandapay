import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/local/sms_rule_bundle_store.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  group('RestrictedSmsRule validation', () {
    test('accepts valid rules across supported families', () {
      final spendRule = RestrictedSmsRule.fromJson({
        'id': 'rule_spend_01',
        'family': 'posted_movement',
        'senderPattern': 'CUSTOMBK',
        'regex': r'debited by Rs\.?\s*([0-9.]+) for ([A-Za-z0-9 ]+) on card (\d{4})',
        'fieldMap': {'amount': 1, 'merchant': 2, 'last4': 3},
        'defaultFields': {'instrument': 'creditCard', 'entryKind': 'spend'},
        'confidence': 0.99,
      });
      expect(spendRule, isNotNull);
      expect(spendRule!.id, 'rule_spend_01');
      expect(spendRule.family, SmsRuleFamily.postedMovement);
      expect(spendRule.matchesSender('VK-CUSTOMBK-T'), isTrue);

      final balRule = RestrictedSmsRule.fromJson({
        'id': 'rule_bal_01',
        'family': 'balance_snapshot',
        'senderPattern': 'TESTBK',
        'regex': r'A/c (\d{4}) Avail Bal Rs\.?\s*([0-9.]+)',
        'fieldMap': {'accountLast4': 1, 'availableBalance': 2},
        'confidence': 0.98,
      });
      expect(balRule, isNotNull);
      expect(balRule!.family, SmsRuleFamily.balanceSnapshot);

      final billRule = RestrictedSmsRule.fromJson({
        'id': 'rule_bill_01',
        'family': 'bill_obligation',
        'senderPattern': 'AIRTEL',
        'regex': r'Bill due on (\d{2}-\d{2}-\d{4}) for Rs\.?\s*([0-9.]+)',
        'fieldMap': {'dueDate': 1, 'amountDue': 2},
        'confidence': 0.95,
      });
      expect(billRule, isNotNull);
      expect(billRule!.family, SmsRuleFamily.billObligation);

      final noiseRule = RestrictedSmsRule.fromJson({
        'id': 'rule_noise_01',
        'family': 'ignore_noise',
        'senderPattern': 'PROMO',
        'regex': r'Special festive discount buy now',
        'confidence': 1.0,
      });
      expect(noiseRule, isNotNull);
      expect(noiseRule!.family, SmsRuleFamily.ignoreNoise);
    });

    test('rejects unsafe ReDoS patterns', () {
      expect(
        RestrictedSmsRule.fromJson({
          'id': 'bad_01',
          'family': 'posted_movement',
          'senderPattern': 'BK',
          'regex': r'(a+)+',
          'fieldMap': {'amount': 1},
        }),
        isNull,
      );

      expect(
        RestrictedSmsRule.fromJson({
          'id': 'bad_02',
          'family': 'posted_movement',
          'senderPattern': 'BK',
          'regex': r'([0-9]*)*',
          'fieldMap': {'amount': 1},
        }),
        isNull,
      );

      expect(
        RestrictedSmsRule.fromJson({
          'id': 'bad_03',
          'family': 'posted_movement',
          'senderPattern': 'BK',
          'regex': r'start .* mid .* end',
          'fieldMap': {'amount': 1},
        }),
        isNull,
      );
    });

    test('rejects invalid capture indices and empty field maps', () {
      expect(
        RestrictedSmsRule.fromJson({
          'id': 'bad_group_01',
          'family': 'posted_movement',
          'senderPattern': 'BK',
          'regex': r'spent Rs\.?\s*([0-9.]+)',
          'fieldMap': {'amount': 0}, // 0 is invalid
        }),
        isNull,
      );

      expect(
        RestrictedSmsRule.fromJson({
          'id': 'bad_group_02',
          'family': 'posted_movement',
          'senderPattern': 'BK',
          'regex': r'spent Rs\.?\s*([0-9.]+)',
          'fieldMap': {}, // empty is invalid for movements
        }),
        isNull,
      );
    });
  });

  group('SmsRuleBundle & Store', () {
    late AppDatabase db;
    late SmsRuleBundleStore store;

    setUp(() {
      db = openInMemoryForTesting();
      store = SmsRuleBundleStore(db);
    });

    tearDown(() {
      db.close();
    });

    test('stores and loads valid bundle locally for offline startup', () async {
      final rawRules = [
        {
          'id': 'rule_01',
          'family': 'posted_movement',
          'senderPattern': 'HDFC',
          'regex': r'spent Rs\.?\s*([0-9.]+)',
          'fieldMap': {'amount': 1},
          'confidence': 0.99,
        },
      ];
      final sha = SmsRuleBundle.computeSha256(
        bundleVersion: 1,
        minClientVersion: '1.0.0',
        rawRules: rawRules,
      );
      final bundlePayload = {
        'bundleVersion': 1,
        'sha256': sha,
        'publishedAt': '2026-10-21T22:00:00Z',
        'minClientVersion': '1.0.0',
        'rules': rawRules,
      };

      final saved = await store.saveBundle(bundlePayload);
      expect(saved, isTrue);

      final loaded = await store.loadActiveBundle();
      expect(loaded, isNotNull);
      expect(loaded!.bundleVersion, 1);
      expect(loaded.rules.length, 1);
      expect(loaded.rules.first.id, 'rule_01');

      // Rollback clears active bundle
      await store.rollback();
      final afterRollback = await store.loadActiveBundle();
      expect(afterRollback, isNull);
    });

    test('syncRules downloads new bundle and ignores upToDate response', () async {
      final syncRawRules = [
        {
          'id': 'rule_02',
          'family': 'posted_movement',
          'senderPattern': 'SBI',
          'regex': r'debited by ([0-9.]+)',
          'fieldMap': {'amount': 1},
          'confidence': 0.99,
        },
      ];
      final syncSha = SmsRuleBundle.computeSha256(
        bundleVersion: 2,
        minClientVersion: '1.0.0',
        rawRules: syncRawRules,
      );
      final mockClient = MockClient((request) async {
        if (request.url.queryParameters['since_version'] == '0') {
          return http.Response(
            jsonEncode({
              'bundleVersion': 2,
              'sha256': syncSha,
              'publishedAt': '2026-10-21T22:30:00Z',
              'minClientVersion': '1.0.0',
              'rules': syncRawRules,
            }),
            200,
          );
        } else if (request.url.queryParameters['since_version'] == '2') {
          return http.Response(jsonEncode({'upToDate': true, 'bundleVersion': 2}), 200);
        }
        return http.Response('not found', 404);
      });

      // First sync: downloads version 2
      final updated = await store.syncRules(mockClient, apiBaseUrl: 'http://localhost');
      expect(updated, isTrue);
      final active = await store.loadActiveBundle();
      expect(active?.bundleVersion, 2);

      // Second sync: returns upToDate, does not re-write
      final secondSync = await store.syncRules(mockClient, apiBaseUrl: 'http://localhost');
      expect(secondSync, isFalse);
    });
  });

  group('LocalSmsParser with downloaded rules', () {
    final parserRawRules = [
      {
        'id': 'rule_custom_spend',
        'family': 'posted_movement',
        'senderPattern': 'CUSTOMGW',
        'regex': r'Custom Gateway: Rs\.?\s*([0-9.]+) paid to Merchant ([A-Za-z ]+) card (\d{4})',
        'fieldMap': {'amount': 1, 'merchant': 2, 'last4': 3},
        'defaultFields': {'instrument': 'creditCard'},
        'confidence': 0.99,
      },
      {
        'id': 'rule_custom_bal',
        'family': 'balance_snapshot',
        'senderPattern': 'CUSTOMBK',
        'regex': r'CustomBank A/c (\d{4}) Balance is Rs\.?\s*([0-9.]+)',
        'fieldMap': {'accountLast4': 1, 'availableBalance': 2},
        'confidence': 0.98,
      },
      {
        'id': 'rule_custom_bill',
        'family': 'bill_obligation',
        'senderPattern': 'TELCO',
        'regex': r'Telco bill due on (\d{2}/\d{2}/\d{4}) amount Rs\.?\s*([0-9.]+)',
        'fieldMap': {'dueDate': 1, 'amountDue': 2},
        'confidence': 0.95,
      },
    ];
    final parserSha = SmsRuleBundle.computeSha256(
      bundleVersion: 1,
      minClientVersion: '1.0.0',
      rawRules: parserRawRules,
    );
    final bundle = SmsRuleBundle.fromJson({
      'bundleVersion': 1,
      'sha256': parserSha,
      'publishedAt': '2026-10-21T22:00:00Z',
      'minClientVersion': '1.0.0',
      'rules': parserRawRules,
    })!;

    test('matches downloaded spend rule on-device without AI fallback', () {
      final obs = LocalSmsParser.parse(
        namespace: 'profile1',
        sender: 'VK-CUSTOMGW-T',
        body: 'Custom Gateway: Rs. 1499.50 paid to Merchant Amazon India card 9876',
        receivedAt: DateTime(2026, 10, 21, 14, 30),
        downloadedRules: bundle,
      );

      expect(obs, isNotNull);
      expect(obs!.transaction, isNotNull);
      expect(obs.transaction!.amount.rupees, 1499.50);
      expect(obs.transaction!.merchantName, 'Amazon India');
      expect(obs.transaction!.cardLast4, '9876');
      expect(obs.transaction!.instrument, TxnInstrument.creditCard);
      expect(obs.confidence, 0.90);
      expect(obs.reasonCodes, contains('downloaded_rule_match'));
    });

    test('matches downloaded balance snapshot rule on-device', () {
      final obs = LocalSmsParser.parse(
        namespace: 'profile1',
        sender: 'CUSTOMBK',
        body: 'CustomBank A/c 4321 Balance is Rs. 54320.00',
        receivedAt: DateTime(2026, 10, 21, 15, 0),
        downloadedRules: bundle,
      );

      expect(obs, isNotNull);
      expect(obs!.eventType, LocalSmsEventType.balance);
      expect(obs.accountLast4, '4321');
      expect(obs.availableBalance?.rupees, 54320.00);
      expect(obs.confidence, 0.98);
      expect(obs.reasonCodes, contains('downloaded_rule_balance'));
    });

    test('matches downloaded bill obligation rule on-device', () {
      final obs = LocalSmsParser.parse(
        namespace: 'profile1',
        sender: 'TELCO',
        body: 'Telco bill due on 28/10/2026 amount Rs. 899.00',
        receivedAt: DateTime(2026, 10, 21, 16, 0),
        downloadedRules: bundle,
      );

      expect(obs, isNotNull);
      expect(obs!.eventType, LocalSmsEventType.bill);
      expect(obs.amountDue?.rupees, 899.00);
      expect(obs.dueDate, isNotNull);
      expect(obs.dueDate!.day, 28);
      expect(obs.dueDate!.month, 10);
      expect(obs.confidence, 0.95);
      expect(obs.reasonCodes, contains('downloaded_rule_bill'));
    });

    test('safety gate drops OTP even if it happens to match a downloaded regex', () {
      final obs = LocalSmsParser.parse(
        namespace: 'profile1',
        sender: 'CUSTOMGW',
        body: 'OTP 123456: Custom Gateway: Rs. 500 paid to Merchant XYZ card 1234',
        receivedAt: DateTime(2026, 10, 21, 14, 30),
        downloadedRules: bundle,
      );

      expect(obs, isNull); // Sensitive filter drops before any rule executes
    });

    test('falls through to built-in parser if no downloaded rule matches', () {
      final obs = LocalSmsParser.parse(
        namespace: 'profile1',
        sender: 'HDFCBK',
        body: 'Rs 500.00 spent on HDFC Bank Card ending 1234 at Swiggy on 21-10-2026',
        receivedAt: DateTime(2026, 10, 21, 14, 30),
        downloadedRules: bundle,
      );

      expect(obs, isNotNull);
      expect(obs!.transaction?.amount.rupees, 500.00);
      expect(obs.transaction?.cardLast4, '1234');
    });
  });
}
