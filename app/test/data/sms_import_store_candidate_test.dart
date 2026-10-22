import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/local/sms_rule_exposure_outbox.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

void main() {
  group('SmsImportStore candidate non-transaction rules', () {
    late AppDatabase database;
    late FinancialStore financialStore;

    setUp(() {
      database = openInMemoryForTesting();
      financialStore = FinancialStore(database);
    });

    tearDown(() {
      financialStore.dispose();
      database.close();
    });

    for (final testCase
        in <
          ({
            String family,
            String reasonCode,
            String sender,
            String body,
            String regex,
            Map<String, int> fieldMap,
            String eventType,
          })
        >[
          (
            family: 'balance_snapshot',
            reasonCode: 'downloaded_rule_balance',
            sender: 'ACMEBANK',
            body: 'ACMEBANK BALSNAP account 4321 available balance INR 54320.00',
            regex: r'BALSNAP account (\d{4}) available balance INR ([0-9.]+)',
            fieldMap: {'accountLast4': 1, 'availableBalance': 2},
            eventType: 'balance',
          ),
          (
            family: 'bill_obligation',
            reasonCode: 'downloaded_rule_bill',
            sender: 'ACMETEL',
            body: 'ACMETEL BILLDUE amount INR 899.00 due 28/10/2026 bill due',
            regex: r'BILLDUE amount INR ([0-9.]+) due (\d{2}/\d{2}/\d{4})',
            fieldMap: {'amountDue': 1, 'dueDate': 2},
            eventType: 'bill',
          ),
          (
            family: 'mandate_lifecycle',
            reasonCode: 'downloaded_rule_mandate',
            sender: 'ACMEPAY',
            body:
                'ACMEPAY MANDATE limit INR 1200.00 card 7788 AutoPay mandate registered',
            regex: r'MANDATE limit INR ([0-9.]+) card (\d{4})',
            fieldMap: {'autopayLimit': 1, 'last4': 2},
            eventType: 'autopay',
          ),
        ]) {
      test('${testCase.family} candidate is counted and applied', () {
        final bundle = _bundleFor(
          family: testCase.family,
          sender: testCase.sender,
          regex: testCase.regex,
          fieldMap: testCase.fieldMap,
        );
        final candidate = SmsCandidateRuleBundle(
          candidateId: 'candidate-${testCase.family}',
          stage: 'limited',
          mode: 'apply',
          assignmentId: 'assignment-${testCase.family}',
          stageVersion: 2,
          bundle: bundle,
        );
        final namespace = 'user-${testCase.family}';

                        
        SmsImportStore(financialStore, candidateRules: [candidate]).capture(
          namespace,
          QueuedSms(
            sender: testCase.sender,
            body: testCase.body,
            receivedAt: DateTime.utc(2026, 10, 22, 12),
          ),
        );

        final observations = financialStore.entities(
          namespace,
          'sms_observations',
        );
                expect(observations, hasLength(1));
        expect(observations.single['event_type'], testCase.eventType);
        expect(
          observations.single['reason_codes'],
          contains(testCase.reasonCode),
        );

        final exposures = SmsRuleExposureOutbox(database).pending(namespace);
        expect(exposures, hasLength(1));
        expect(exposures.single['candidateId'], candidate.candidateId);
        expect(exposures.single['matched'], isTrue);
        expect(exposures.single['applied'], isTrue);
        expect(exposures.single['candidateFamily'], testCase.eventType);
        expect(exposures.single['factValid'], isTrue);
      });
    }
  });
}

SmsRuleBundle _bundleFor({
  required String family,
  required String sender,
  required String regex,
  required Map<String, int> fieldMap,
}) {
  final bundle = SmsRuleBundle.fromJson({
    'bundleVersion': 1,
    'sha256': '0' * 64,
    'publishedAt': '2026-10-22T00:00:00Z',
    'minClientVersion': '1.0.0',
    'rules': [
      {
        'id': 'rule-$family',
        'family': family,
        'senderPattern': sender,
        'regex': regex,
        'fieldMap': fieldMap,
        'defaultFields': <String, dynamic>{},
        'confidence': 0.98,
      },
    ],
  }, verifySha: false);
  expect(bundle, isNotNull);
  return bundle!;
}
