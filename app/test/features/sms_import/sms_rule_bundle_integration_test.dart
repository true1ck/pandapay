import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_rule_bundle.dart';
import 'package:pandapay/data/local/sms_rule_bundle_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_capture_worker.dart';

void main() {
  test(
    'end-to-end: downloaded rule bundle runs inside isolate capture worker and respects user override',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pandapay-rule-worker-',
      );
      final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await directory.resolveSymbolicLinks();
      if (!target.startsWith('$temporaryRoot${Platform.pathSeparator}') ||
          !directory.path.contains('pandapay-rule-worker-')) {
        throw StateError('Unexpected temporary test directory');
      }

      final dbPath = '${directory.path}/financial.sqlite';
      final database = AppDatabase.openFile(dbPath);
      final bundleStore = SmsRuleBundleStore(database);
      final financialStore = FinancialStore(database);

      // 1. Prepare and store active rule bundle in database
      final rawRules = [
        {
          'id': 'rule_neo_spend',
          'family': 'posted_movement',
          'senderPattern': 'NEOBANK',
          'regex': r'NeoBank: Rs\.?\s*([0-9.]+) spent at ([A-Za-z ]+) with card (\d{4})',
          'fieldMap': {'amount': 1, 'merchant': 2, 'last4': 3},
          'defaultFields': {'instrument': 'creditCard'},
          'confidence': 0.98,
        },
      ];
      final sha = SmsRuleBundle.computeSha256(
        bundleVersion: 1,
        minClientVersion: '1.0.0',
        rawRules: rawRules,
      );
      final saved = await bundleStore.saveBundle({
        'bundleVersion': 1,
        'sha256': sha,
        'publishedAt': '2026-10-21T23:00:00Z',
        'minClientVersion': '1.0.0',
        'rules': rawRules,
      });
      expect(saved, isTrue);

      // Verify synchronous isolate loader can read it
      final loadedSync = bundleStore.loadActiveBundleSync();
      expect(loadedSync, isNotNull);
      expect(loadedSync!.rules.first.id, 'rule_neo_spend');

      // 2. Spin up SmsCaptureWorker isolate pointing to dbPath
      final worker = SmsCaptureWorker(dbPath);

      addTearDown(() async {
        worker.dispose();
        financialStore.dispose();
        database.close();
        for (var attempt = 0; attempt < 20; attempt++) {
          try {
            await directory.delete(recursive: true);
            return;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        await directory.delete(recursive: true);
      });

      // 3. Incoming SMS matching the downloaded rule (not covered by built-in regexes)
      final message = QueuedSms(
        sender: 'VK-NEOBANK-T',
        body: 'NeoBank: Rs. 1850.00 spent at Urban Company with card 4321',
        receivedAt: DateTime(2026, 10, 21, 18, 30),
      );

      final changed = await worker.capture('profile:alpha', [message]);
      expect(changed, contains('transactions'));

      // Verify transaction was written to FinancialStore on-device
      final txns = financialStore.transactions('profile:alpha', const TransactionQuery())!;
      expect(txns.rows, hasLength(1));
      final capturedTxn = txns.rows.first;
      expect(capturedTxn.amount.rupees, 1850.00);
      expect(capturedTxn.merchantName, 'Urban Company');
      expect(capturedTxn.cardLast4, '4321');

      // 4. User corrects the transaction (e.g. adjusts note)
      final userModifiedTxn = capturedTxn.copyWith(
        note: 'User verified in Needs Review',
      );
      financialStore.saveTransactions('profile:alpha', [userModifiedTxn]);

      final updatedTxns = financialStore.transactions('profile:alpha', const TransactionQuery())!;
      expect(updatedTxns.rows.first.note, 'User verified in Needs Review');
      expect(updatedTxns.rows.first.status, 'active');

      // 5. Duplicate delivery / replay of the same SMS must NOT overwrite the user correction
      final replayedChanges = await worker.capture('profile:alpha', [message]);
      expect(replayedChanges, isEmpty); // Suppressed by deduplication / intake hash

      final finalTxns = financialStore.transactions('profile:alpha', const TransactionQuery())!;
      expect(finalTxns.rows.first.note, 'User verified in Needs Review');
      expect(finalTxns.rows.first.status, 'active');

      // 6. Test Rollback: deactivate rules and verify new messages for that pattern are ignored
      await bundleStore.rollback();
      expect(bundleStore.loadActiveBundleSync(), isNull);

      final secondMessage = QueuedSms(
        sender: 'VK-NEOBANK-T',
        body: 'NeoBank: Rs. 990.00 spent at Starbucks with card 4321',
        receivedAt: DateTime(2026, 10, 21, 19, 0),
      );
      final afterRollbackChanges = await worker.capture('profile:alpha', [secondMessage]);
      // Built-in parser doesn't know NeoBank pattern, and rules are rolled back -> no transaction change
      expect(afterRollbackChanges.contains('transactions'), isFalse);
    },
  );
}
