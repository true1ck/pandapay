import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/ios_sms_acquisition_receipts.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/features/sms_import/ios_shortcut_sms.dart';

void main() {
  test(
    'an old security input releases its batch without a body hash or decision',
    () {
      final db = openInMemoryForTesting();
      final store = FinancialStore(db);
      addTearDown(() {
        store.dispose();
        db.close();
      });
      const ns = 'user:synthetic', generation = 'g1';
      final rows = <Map<Object?, Object?>>[
        {
          'id': 'security',
          'namespace': ns,
          'generation': generation,
          'sender': 'VM-TESTBK',
          'body': 'Registration Alert: Device Name: SYNTHETIC PHONE.',
          'receivedAt': '2026-03-07T06:00:00Z',
        },
        {
          'id': 'other',
          'namespace': ns,
          'generation': generation,
          'sender': 'VM-TESTBK',
          'body': 'Welcome to synthetic service.',
          'receivedAt': '2026-03-07T06:01:00Z',
        },
      ];
      final batch = IosShortcutSmsBatch.fromRows(
        rows,
        allowSenderInference: false,
      );
      expect(batch.sensitive, 1);
      SmsImportStore(store).captureBatch(ns, batch.messages);
      final outcomes = IosSmsAcquisitionReceipts(
        store,
      ).record(ns, generation, rows);
      expect(outcomes.map((r) => r['outcome']), [
        'excluded_security',
        'ignored',
      ]);
      expect(outcomes.first.containsKey('sourceKey'), isFalse);
      expect(db.db.select('SELECT * FROM sms_source_decisions'), hasLength(1));
      expect(
        db.db.select('SELECT * FROM ios_sms_acquisition_receipts'),
        hasLength(1),
      );
    },
  );
  test(
    'production preserves unknown senders while explicit probe inference remains available',
    () {
      final rows = <Map<Object?, Object?>>[
        {
          'body': 'ICICI INR 250 spent at CAFE',
          'receivedAt': '2026-10-29T12:00:00Z',
        },
      ];
      final production = IosShortcutSmsBatch.fromRows(
        rows,
        allowSenderInference: false,
      );
      expect(production.messages.single.sender, '');
      expect(production.missingSender, 1);
      expect(production.incomplete, 0);
      expect(production.sourceRows.single['senderInferred'], isFalse);
      expect(
        IosShortcutSmsBatch.fromRows(rows).messages.single.sender,
        'VM-ICICIB',
      );
    },
  );

}
