import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/ios_sms_acquisition_receipts.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/ios_shortcut_sms.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'only committed shared decisions establish receipts; personal policy is shared',
    () async {
      final db = openInMemoryForTesting();
      final store = FinancialStore(db);
      addTearDown(() {
        store.dispose();
        db.close();
      });
      final receipts = IosSmsAcquisitionReceipts(store);
      const namespace = 'user:synthetic-a', generation = 'g1';
      const body =
          'INR 250 spent on ICICI Bank Card XX1234 at SYNTHETIC CAFE. Ref TEST-55';
      final rows = <Map<Object?, Object?>>[
        {
          'id': 'bank',
          'namespace': namespace,
          'generation': generation,
          'body': body,
          'sender': 'VM-ICICIB',
          'receivedAt': '2026-10-29T12:00:00Z',
          'dateProvenance': 'original',
        },
        {
          'id': 'personal',
          'namespace': namespace,
          'generation': generation,
          'body': body,
          'sender': '+919000000001',
          'receivedAt': '2026-10-29T12:01:00Z',
          'dateProvenance': 'original',
        },
      ];
      expect(
        () => receipts.record(namespace, generation, rows),
        throwsStateError,
      );
      expect(
        db.db.select('SELECT * FROM ios_sms_acquisition_receipts'),
        isEmpty,
      );
      final batch = IosShortcutSmsBatch.fromRows(
        rows,
        allowSenderInference: false,
      );
      SmsImportStore(store).captureBatch(namespace, batch.messages);
      final outcomes = receipts.record(namespace, generation, rows);
      expect(outcomes.map((r) => r['outcome']), ['captured', 'ignored']);
      expect(
        SmsIntakeRepository(db)
            .decision(
              namespace,
              smsSourceKey(namespace, '+919000000001', body),
            )!
            .reasonCode,
        'p2p_mobile_number',
      );
      receipts.record(namespace, generation, rows);
      expect(
        db.db.select('SELECT * FROM ios_sms_acquisition_receipts'),
        hasLength(2),
      );
      final repeated = {
        ...rows.first,
        'id': 'another-original-date',
        'receivedAt': '2026-10-30T12:00:00Z',
      };
      final again = IosShortcutSmsBatch.fromRows([
        repeated,
      ], allowSenderInference: false);
      SmsImportStore(store).captureBatch(namespace, again.messages);
      receipts.record(namespace, generation, [repeated]);
      expect(
        db.db.select('SELECT * FROM ios_sms_acquisition_receipts'),
        hasLength(3),
      );
      expect(
        SmsIntakeRepository(db).hasRepeatedOccurrence(
          namespace,
          smsSourceKey(namespace, 'VM-ICICIB', body),
        ),
        isTrue,
      );
      expect(
        () => receipts.record(namespace, 'other-generation', rows),
        throwsStateError,
      );
      await db.clearAccountNamespace(namespace);
      expect(
        db.db.select('SELECT * FROM ios_sms_acquisition_receipts'),
        isEmpty,
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

  test(
    'unknown-sender financial input is durable local review across replay and reads',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = openInMemoryForTesting();
      final store = FinancialStore(db);
      addTearDown(() {
        store.dispose();
        db.close();
      });
      const ns = 'user:missing-sender', generation = 'g1';
      const body =
          'INR 250 spent on ICICI Bank Card XX1234 at SYNTHETIC CAFE. Ref TEST-77';
      final rows = <Map<Object?, Object?>>[
        {
          'id': 'unknown',
          'namespace': ns,
          'generation': generation,
          'body': body,
          'sender': '',
          'senderEvidence': 'missing',
          'receivedAt': '2026-10-29T12:00:00Z',
          'dateProvenance': 'original',
        },
      ];
      final batch = IosShortcutSmsBatch.fromRows(
        rows,
        allowSenderInference: false,
      );
      final importer = SmsImportStore(store);
      importer.captureBatch(ns, batch.messages);
      final receipts = IosSmsAcquisitionReceipts(store);
      expect(receipts.record(ns, generation, rows).single['outcome'], 'review');
      expect(SmsIntakeRepository(db).pending(ns), isEmpty);
      expect(store.entities(ns, 'transactions'), isEmpty);
      final review = NeedsReviewRepository(
        namespace: ns,
        loadDatabase: () async => db,
      );
      for (var read = 0; read < 2; read++) {
        final items = await review.fetchAll();
        expect(items, hasLength(1));
        expect(items.single.sender, '');
        expect(items.single.body, body);
        expect(items.single.needsSender, isTrue);
        expect(store.entities(ns, 'transactions'), isEmpty);
      }
      importer.captureBatch(ns, batch.messages);
      receipts.record(ns, generation, rows);
      expect(await review.fetchAll(), hasLength(1));
      expect(
        SmsIntakeRepository(
          db,
        ).capturedById(ns, smsSourceKey(ns, '', body))!.message.body,
        body,
      );

      // Android's shared capture entry point applies the identical unknown-input policy.
      importer.capture(
        ns,
        QueuedSms(
          sender: '',
          body: body,
          receivedAt: DateTime.utc(2026, 10, 30),
        ),
      );
      expect(await review.fetchAll(), hasLength(1));
      expect(store.entities(ns, 'transactions'), isEmpty);
      expect(
        SmsIntakeRepository(
          db,
        ).hasRepeatedOccurrence(ns, smsSourceKey(ns, '', body)),
        isTrue,
      );
    },
  );
}
