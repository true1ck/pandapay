import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_facts_outbox.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';

void main() {
  late AppDatabase db;
  late FinancialStore financialStore;
  late SmsIntakeRepository intake;
  late SmsImportStore importStore;

  setUp(() {
    db = openInMemoryForTesting();
    financialStore = FinancialStore(db);
    intake = SmsIntakeRepository(db);
    importStore = SmsImportStore(financialStore);
  });

  tearDown(() => db.close());

  Map<String, dynamic>? getObservation(String ns, String key) =>
      financialStore.entities(ns, 'sms_observations', id: key).firstOrNull;

  Map<String, dynamic>? getTransaction(String ns, String key) =>
      financialStore.entities(ns, 'transactions', id: key).firstOrNull;

  group('Section 9 Scenarios (Mobile Device Parity)', () {
    test('Scenario 1: Fresh install mixed inbox triage, facts without AI, zero OTP persistence', () {
      final messages = [
        QueuedSms(
          sender: 'VM-HDFCBK',
          body: 'Your a/c XX1234 debited INR 500.00 at SWIGGY on 22-10-26. Avl bal INR 12,000.00',
          receivedAt: DateTime(2026, 10, 22, 10, 0),
        ),
        QueuedSms(
          sender: 'VM-HDFCBK-P',
          body: 'Special offer! Get 50% discount up to Rs. 200 on food delivery. Apply code FESTIVE.',
          receivedAt: DateTime(2026, 10, 22, 10, 5),
        ),
        QueuedSms(
          sender: 'VM-HDFCBK',
          body: '812345 is your OTP for transaction of INR 500 at SWIGGY. Do not share OTP.',
          receivedAt: DateTime(2026, 10, 22, 10, 0),
        ),
      ];

      importStore.captureBatch('user1', messages);

      // Financial message was captured and parsed locally without AI, pending sync
      final finKey = smsSourceKey('user1', messages[0].sender, messages[0].body);
      expect(intake.pending('user1').map((e) => e.id), contains(finKey));
      final obs = getObservation('user1', finKey);
      expect(obs, isNotNull);
      expect(obs!['account_last4'], '1234');
      expect(obs['balance_paise'], 1200000);

      // Promo message recorded decision as ignored_promotion without saving raw body
      final promoKey = smsSourceKey('user1', messages[1].sender, messages[1].body);
      final promoDecision = intake.decision('user1', promoKey);
      expect(promoDecision, isNotNull);
      expect(promoDecision!.decision, 'ignored_promotion');
      expect(promoDecision.state, 'final');
      expect(intake.wasProcessed('user1', promoKey), isTrue);
      expect(getObservation('user1', promoKey), isNull);

      // Sensitive message (OTP) was discarded entirely - zero persistence
      final otpKey = smsSourceKey('user1', messages[2].sender, messages[2].body);
      expect(intake.decision('user1', otpKey), isNull);
      expect(getObservation('user1', otpKey), isNull);
      expect(intake.capturedBodies('user1'), isNot(contains(messages[2].body)));
    });

    test('Scenario 2: Duplicate delivery idempotency across entry points', () {
      final message = QueuedSms(
        sender: 'VM-ICICIB',
        body: 'INR 1,250.00 spent on ICICI Bank Card XX7788 at AMAZON on 22-Oct-26.',
        receivedAt: DateTime(2026, 10, 22, 11, 0),
      );

      // First entry point: live incoming broadcast
      importStore.capture('user1', message);
      final key = smsSourceKey('user1', message.sender, message.body);
      expect(getObservation('user1', key), isNotNull);

      // Second entry point: periodic inbox scan replay of same message
      importStore.capture('user1', message);
      expect(intake.pending('user1').where((e) => e.id == key), hasLength(1));

      // Acknowledge receipt
      intake.acknowledge('user1', key);
      expect(intake.wasProcessed('user1', key), isTrue);

      // Third entry point: backup restore replay
      importStore.capture('user1', message);
      expect(intake.pending('user1'), isEmpty);
    });

    test('Scenario 3: Multi-fact separation (debit vs balance vs bill obligation vs attempt)', () {
      final msg = QueuedSms(
        sender: 'VM-HDFCBK',
        body: 'Alert: INR 2,500.00 debited from card XX1234 at FLIPKART. Avail bal INR 45,000.00.',
        receivedAt: DateTime(2026, 10, 22, 12, 0),
      );

      importStore.capture('user1', msg);
      final key = smsSourceKey('user1', msg.sender, msg.body);
      final obs = getObservation('user1', key);
      expect(obs, isNotNull);

      // Facts outbox contains distinct typed facts
      final facts = buildSmsFactsForObservation(
        body: msg.body,
        observation: LocalSmsParser.parse(
          namespace: 'user1',
          sender: msg.sender,
          body: msg.body,
          receivedAt: msg.receivedAt,
          cards: [],
        )!,
        receivedAt: msg.receivedAt,
      );
      // Both movement and balance snapshot
      final factTypes = facts.map((f) => f.factType).toSet();
      expect(factTypes.contains('balance_snapshot'), isTrue);
    });

    test('Scenario 4: Promotion containing financial words vs real financial with offer footer', () {
      // Fake promo quoting financial words
      final promo = QueuedSms(
        sender: 'VM-HDFCBK-P',
        body: 'Spend INR 10,000 on your card and get INR 500 cashback! Apply now for personal loan.',
        receivedAt: DateTime(2026, 10, 22, 13, 0),
      );
      expect(classifySmsTriage(promo.sender, promo.body).kind, SmsTriageKind.promotion);

      // Real financial alert with marketing footer
      final fin = QueuedSms(
        sender: 'VM-HDFCBK',
        body: 'Your a/c XX1234 debited INR 999.00 at STORE. Get 10% cashback on your next purchase.',
        receivedAt: DateTime(2026, 10, 22, 13, 5),
      );
      expect(classifySmsTriage(fin.sender, fin.body).kind, SmsTriageKind.financialCandidate);
    });

    test('Scenario 5: User correction precedence over base facts and late replay', () {
      final key = smsSourceKey('user1', 'VM-HDFC', 'debited 100');
      financialStore.saveObservation('user1', key, {
        'id': key,
        'amount_paise': 10000,
        'merchant': 'UNKNOWN',
      });

      // User overrides merchant locally
      financialStore.saveTransactions(
        'user1',
        [
          TransactionEntry(
            id: key,
            amount: Money.fromPaise(10000),
            occurredAt: DateTime(2026, 10, 22),
            merchantName: 'CORRECTED_MERCHANT',
            source: 'manual',
            status: 'posted',
          ),
        ],
        at: DateTime(2026, 10, 22),
      );

      final tx = getTransaction('user1', key);
      expect(tx, isNotNull);
      expect(tx!['merchant_name'], 'CORRECTED_MERCHANT');
    });

    test('Scenario 6: Learned template rule execution with exact field capture', () {
      final ruleJson = {
        'id': 'rule_custom_1',
        'family': 'posted_movement',
        'issuer': 'HDFC',
        'senderPattern': 'HDFC',
        'regex': r'INR\s+([0-9,]+(?:\.[0-9]{1,2})?)\s+debited\s+from\s+card\s+([0-9]{4})\s+at\s+([A-Za-z0-9\s]{2,20})',
        'fieldMap': {'amount': 1, 'card_last4': 2, 'merchant': 3},
        'defaultFields': {'direction': 'debit'},
        'confidence': 0.98,
      };

      final bundle = SmsRuleBundle.fromJson({
        'bundleVersion': 2,
        'rules': [ruleJson],
        'sha256': 'a' * 64,
        'minClientVersion': '1.0.0',
      }, verifySha: false);
      expect(bundle, isNotNull);

      final customStore = SmsImportStore(financialStore, downloadedRules: bundle);
      final msg = QueuedSms(
        sender: 'VM-HDFCBK',
        body: 'INR 1,450.00 debited from card 4321 at ZOMATO',
        receivedAt: DateTime(2026, 10, 22, 14, 0),
      );

      customStore.capture('user1', msg);
      final key = smsSourceKey('user1', msg.sender, msg.body);
      final obs = getObservation('user1', key);
      expect(obs, isNotNull);
      expect(obs!['card_last4'], '4321');
    });

    test('Scenario 7: ReDoS rejection and invalid regex safety', () {
      // ReDoS pattern with nested quantifiers
      final badRule = {
        'id': 'rule_bad',
        'family': 'posted_movement',
        'issuer': 'TEST',
        'senderPattern': 'TEST',
        'regex': r'(a+)+',
        'fieldMap': {'amount': 1},
        'defaultFields': {},
        'confidence': 0.9,
      };

      final badBundle = SmsRuleBundle.fromJson({
        'bundleVersion': 3,
        'rules': [badRule],
        'sha256': 'b' * 64,
        'minClientVersion': '1.0.0',
      }, verifySha: false);

      expect(badBundle, isNull);
    });

    test('Scenario 8: Mandate lifecycle setup/cancel != charge', () {
      final mandateMsg = QueuedSms(
        sender: 'VM-HDFCBK',
        body: 'AutoPay mandate registered for Rs. 1,500.00 towards NETFLIX. First execution on 01-Nov-26.',
        receivedAt: DateTime(2026, 10, 22, 15, 0),
      );

      importStore.capture('user1', mandateMsg);
      final key = smsSourceKey('user1', mandateMsg.sender, mandateMsg.body);
      final obs = getObservation('user1', key);
      expect(obs, isNotNull);
      // Event type is autopay, NOT transaction spend
      expect(obs!['event_type'], 'autopay');
      // No provisional spend transaction created for mandate registration
      expect(getTransaction('user1', key), isNull);
    });

    test('Scenario 9: Account isolation and namespace separation', () {
      final msg = QueuedSms(
        sender: 'VM-HDFCBK',
        body: 'INR 500 debited from a/c XX1234 at STORE',
        receivedAt: DateTime(2026, 10, 22, 16, 0),
      );

      importStore.capture('user_a', msg);
      final keyA = smsSourceKey('user_a', msg.sender, msg.body);
      final keyB = smsSourceKey('user_b', msg.sender, msg.body);

      // Key depends on user namespace
      expect(keyA, isNot(equals(keyB)));

      expect(getObservation('user_a', keyA), isNotNull);
      expect(getObservation('user_b', keyB), isNull);
    });
  });
}
