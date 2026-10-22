import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_facts_outbox.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/local/sms_rule_bundle_store.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  group('Autonomous Learning Device Rule Execution & Durability', () {
    late AppDatabase database;
    late SmsRuleBundleStore bundleStore;
    late FinancialStore financialStore;

    setUp(() {
      database = openInMemoryForTesting();
      bundleStore = SmsRuleBundleStore(database);
      financialStore = FinancialStore(database);
    });

    tearDown(() {
      financialStore.dispose();
      database.close();
    });

    test(
      'learned HDFC template rule matches on-device for later user with distinct values and prioritizes manual override',
      () async {
        // 1. Prepare and load active rule bundle containing a learned HDFC template rule
        final rawRule = {
          'id': 'learned_hdfc_spend_v1',
          'family': 'posted_movement',
          'senderPattern': 'HDFC',
          'regex':
              r'debited by Rs\. ([0-9,.]+) on card (\d{4}) at ([A-Za-z0-9]+) on (\d{2}-\d{2}-\d{4}) ref (\d+)\. Avail Bal Rs\. ([0-9,.]+)',
          'fieldMap': {
            'amount': 1,
            'last4': 2,
            'merchant': 3,
            'date': 4,
            'reference': 5,
            'availableBalance': 6,
          },
          'defaultFields': {
            'instrument': 'creditCard',
            'entryKind': 'spend',
          },
          'confidence': 0.98,
        };

        final sha = SmsRuleBundle.computeSha256(
          bundleVersion: 1,
          minClientVersion: '1.0.0',
          rawRules: [rawRule],
        );

        final saved = await bundleStore.saveBundle({
          'bundleVersion': 1,
          'sha256': sha,
          'publishedAt': '2026-10-24T12:00:00Z',
          'minClientVersion': '1.0.0',
          'rules': [rawRule],
        });
        expect(saved, isTrue);

        final activeBundle = bundleStore.loadActiveBundleSync();
        expect(activeBundle, isNotNull);
        expect(activeBundle!.rules, hasLength(1));
        final loadedRule = activeBundle.rules.first;
        expect(loadedRule.id, 'learned_hdfc_spend_v1');
        expect(loadedRule.family, SmsRuleFamily.postedMovement);

        // 2. Simulate incoming SMS for a LATER user from AD-HDFCBK with COMPLETELY DIFFERENT values
        const laterUserNamespace = 'user_later_456';
        const sender = 'AD-HDFCBK';
        const body =
            'debited by Rs. 7,450.00 on card 9912 at Swiggy on 25-10-2026 ref 88776655. Avail Bal Rs. 1,20,000';
        final receivedAt = DateTime(2026, 10, 25, 14, 30);

        // 3. Run LocalSmsParser with the loaded bundle rule on device
        final obs = LocalSmsParser.parse(
          namespace: laterUserNamespace,
          sender: sender,
          body: body,
          receivedAt: receivedAt,
          downloadedRules: activeBundle,
        );

        // 4. Assert that the rule matches locally on the device!
        expect(obs, isNotNull);
        expect(obs!.disposition, LocalSmsDisposition.sync);
        expect(obs.eventType, LocalSmsEventType.transaction);
        expect(obs.reasonCodes, contains('downloaded_rule_match'));
        expect(obs.reasonCodes, contains('learned_hdfc_spend_v1'));

        // 5. Assert that extracted fields match the new values:
        // amount is 7450.00, last4 is 9912, merchant is Swiggy, date is 25-10-2026, reference is 88776655
        expect(obs.transaction, isNotNull);
        expect(obs.transaction!.amount.rupees, 7450.00);
        expect(obs.transaction!.cardLast4, '9912');
        expect(obs.cardLast4, '9912');
        expect(obs.transaction!.merchantName, 'Swiggy');

        // Verify rule capture groups match all extracted fields
        final match = loadedRule.regExp.firstMatch(body);
        expect(match, isNotNull);
        final extractedAmountStr = match!.group(loadedRule.fieldMap['amount']!);
        final extractedLast4 = match.group(loadedRule.fieldMap['last4']!);
        final extractedMerchant = match.group(loadedRule.fieldMap['merchant']!);
        final extractedDate = match.group(loadedRule.fieldMap['date']!);
        final extractedReference = match.group(loadedRule.fieldMap['reference']!);
        final extractedBalance = match.group(loadedRule.fieldMap['availableBalance']!);

        expect(
          double.parse(extractedAmountStr!.replaceAll(',', '')),
          7450.00,
        );
        expect(extractedLast4, '9912');
        expect(extractedMerchant, 'Swiggy');
        expect(extractedDate, '25-10-2026');
        expect(extractedReference, '88776655');
        expect(extractedBalance, '1,20,000');

        // 6. Verify user override priority: when a user provides an override for this source key
        // in FinancialStore / SmsFactsRepository, the manual override takes precedence over the rule.
        final sourceKey = smsSourceKey(laterUserNamespace, sender, body);

        // User records a manual correction in FinancialStore
        final manualOverride = TransactionEntry(
          id: 'manual-$sourceKey',
          sourceKey: sourceKey,
          amount: Money.fromRupees(7450.00),
          merchantName: 'Swiggy Instamart - Office Dinner',
          cardLast4: '9912',
          occurredAt: receivedAt,
          source: 'manual',
          status: 'active',
          note: 'Categorized by user as Office Dinner',
        );
        financialStore.saveTransactions(laterUserNamespace, [manualOverride]);

        // When incoming SMS capture runs or replays with downloaded rules
        final importStore = SmsImportStore(
          financialStore,
          downloadedRules: activeBundle,
        );
        importStore.capture(
          laterUserNamespace,
          QueuedSms(sender: sender, body: body, receivedAt: receivedAt),
        );

        // FinancialStore preserves the manual user override over the downloaded rule output
        final storedTxns = financialStore.transactions(
          laterUserNamespace,
          const TransactionQuery(),
        )!;
        expect(storedTxns.rows, hasLength(1));
        expect(
          storedTxns.rows.first.merchantName,
          'Swiggy Instamart - Office Dinner',
        );
        expect(
          storedTxns.rows.first.note,
          'Categorized by user as Office Dinner',
        );
        expect(storedTxns.rows.first.source, 'manual');

        // Also verify fact correction outbox records override for sync
        final factsOutbox = SmsFactsOutbox(database);
        factsOutbox.enqueueOverride(
          laterUserNamespace,
          sourceKey: sourceKey,
          factIndex: 0,
          patch: {
            'merchant': 'Swiggy Instamart - Office Dinner',
            'note': 'Categorized by user as Office Dinner',
          },
          reason: 'user_correction',
        );

        final pendingOverrides = factsOutbox.pendingOverrides(laterUserNamespace);
        expect(pendingOverrides, hasLength(1));
        expect(pendingOverrides.first.sourceKey, sourceKey);
        expect(pendingOverrides.first.factIndex, 0);
        expect(
          pendingOverrides.first.patch['merchant'],
          'Swiggy Instamart - Office Dinner',
        );
      },
    );

    test(
      'learned ICICI template rule matches on-device with new values and respects manual override',
      () async {
        final rawRule = {
          'id': 'learned_icici_spend_v1',
          'family': 'posted_movement',
          'senderPattern': 'ICICI',
          'regex':
              r'ICICI Bank: debited by Rs\. ([0-9,.]+) on card (\d{4}) at ([A-Za-z0-9]+) on (\d{2}-\d{2}-\d{4}) ref (\d+)\. Avail Bal Rs\. ([0-9,.]+)',
          'fieldMap': {
            'amount': 1,
            'last4': 2,
            'merchant': 3,
            'date': 4,
            'reference': 5,
            'availableBalance': 6,
          },
          'defaultFields': {
            'instrument': 'creditCard',
            'entryKind': 'spend',
          },
          'confidence': 0.98,
        };

        final sha = SmsRuleBundle.computeSha256(
          bundleVersion: 2,
          minClientVersion: '1.0.0',
          rawRules: [rawRule],
        );

        await bundleStore.saveBundle({
          'bundleVersion': 2,
          'sha256': sha,
          'publishedAt': '2026-10-24T12:00:00Z',
          'minClientVersion': '1.0.0',
          'rules': [rawRule],
        });

        final bundle = bundleStore.loadActiveBundleSync()!;
        const namespace = 'user_icici_789';
        const sender = 'VM-ICICIB';
        const body =
            'ICICI Bank: debited by Rs. 3,299.00 on card 5544 at Croma on 26-10-2026 ref 11223344. Avail Bal Rs. 85,000';
        final receivedAt = DateTime(2026, 10, 26, 11, 0);

        final obs = LocalSmsParser.parse(
          namespace: namespace,
          sender: sender,
          body: body,
          receivedAt: receivedAt,
          downloadedRules: bundle,
        );

        expect(obs, isNotNull);
        expect(obs!.disposition, LocalSmsDisposition.sync);
        expect(obs.transaction!.amount.rupees, 3299.00);
        expect(obs.transaction!.cardLast4, '5544');
        expect(obs.transaction!.merchantName, 'Croma');

        final match = bundle.rules.first.regExp.firstMatch(body)!;
        expect(match.group(bundle.rules.first.fieldMap['date']!), '26-10-2026');
        expect(match.group(bundle.rules.first.fieldMap['reference']!), '11223344');

        // Override in FinancialStore takes priority
        final sourceKey = smsSourceKey(namespace, sender, body);
        financialStore.saveTransactions(namespace, [
          TransactionEntry(
            id: 'manual-$sourceKey',
            sourceKey: sourceKey,
            amount: Money.fromRupees(3299.00),
            merchantName: 'Croma Electronics - Store Visit',
            cardLast4: '5544',
            occurredAt: receivedAt,
            source: 'manual',
            status: 'active',
          ),
        ]);

        final importStore = SmsImportStore(financialStore, downloadedRules: bundle);
        importStore.capture(
          namespace,
          QueuedSms(sender: sender, body: body, receivedAt: receivedAt),
        );

        final txns = financialStore.transactions(namespace, const TransactionQuery())!;
        expect(txns.rows.first.merchantName, 'Croma Electronics - Store Visit');
        expect(txns.rows.first.source, 'manual');
      },
    );
  });
}
