import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/sms_amount_evidence.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/sms_fact_scoring.dart';

void main() {
  test('a confident AI result cannot turn an available limit into spending', () {
    const body =
        'USD 20.00 spent using ICICI Bank Card XX1234 at SYNTHETIC AI. Avl Limit: INR 286388.46.';
    final assessment = assessSmsFacts(
      [
        {
          'factType': 'posted_movement',
          'payload': {
            'amountRole': 'posted',
            'entryKind': 'spend',
            'amountInr': 286388.46,
            'occurredAt': '2026-03-07T06:00:00Z',
            'instrument': 'credit_card',
            'last4': '1234',
            'merchant': 'SYNTHETIC AI',
            'category': 'subscriptions',
            'isComplete': true,
            'confidence': 1.0,
          },
        },
      ],
      body,
      receivedAt: DateTime.parse('2026-03-07T06:00:00Z'),
    );
    expect(assessment.autoResolvable, isFalse);
  });
  final cases =
      (jsonDecode(
                File('test/fixtures/sms_amount_roles.json').readAsStringSync(),
              )
              as List)
          .cast<Map>();
  for (final row in cases) {
    test('monetary roles: ${row['id']}', () {
      final body = row['body'] as String;
      expect(SmsAmountEvidence.reviewReason(body) != null, row['review']);
      final printed = SmsAmountEvidence.firstPaymentAmount(body);
      expect(
        printed == null ? null : num.parse(printed.replaceAll(',', '')),
        row['paymentInr'],
      );
      if (row['review'] == true) {
        final parsed = LocalSmsParser.parse(
          namespace: 'user:test',
          sender: 'VM-ICICIT-S',
          body: body,
          receivedAt: DateTime(2026, 11, 2),
        );
        expect(parsed?.transaction, isNull);
        expect(parsed?.disposition, LocalSmsDisposition.review);
        expect(
          LocalSmsParser.reviewDraft(
            namespace: 'user:test',
            sender: 'VM-ICICIT-S',
            body: body,
            receivedAt: DateTime(2026, 11, 2),
          ).amount,
          isNull,
        );
      } else if (row['paymentInr'] != null) {
        final parsed = LocalSmsParser.parse(namespace: 'user:test', sender: 'VM-ICICIT-S',
          body: body, receivedAt: DateTime(2026, 11, 2));
        expect(parsed?.transaction?.amount.rupees, row['paymentInr']);
      }
    });
  }
  test(
    'foreign payment is preserved for review without a provisional limit expense',
    () {
      SharedPreferences.setMockInitialValues({});
      final db = openInMemoryForTesting();
      final store = FinancialStore(db);
      addTearDown(() {
        store.dispose();
        db.close();
      });
      const ns = 'user:test';
      final body = cases.first['body'] as String;
      SmsImportStore(store).capture(
        ns,
        QueuedSms(
          sender: 'VM-ICICIT-S',
          body: body,
          receivedAt: DateTime(2025, 12, 2),
        ),
      );
      expect(store.entities(ns, 'transactions'), isEmpty);
      expect(db.db.select('SELECT * FROM local_needs_review'), hasLength(1));
      expect(SmsIntakeRepository(db).pending(ns), isEmpty);
    },
  );
  for (final edited in [false, true]) {
    test('old provisional limit expense repair preserves edits=$edited', () {
      SharedPreferences.setMockInitialValues({});
      final db = openInMemoryForTesting();
      final store = FinancialStore(db);
      addTearDown(() {
        store.dispose();
        db.close();
      });
      const ns = 'user:test', sender = 'VM-ICICIT-S';
      final body = cases.first['body'] as String;
      final received = DateTime(2025, 12, 2);
      final key = smsSourceKey(ns, sender, body);
      SmsIntakeRepository(db).capture(
        ns,
        QueuedSms(sender: sender, body: body, receivedAt: received),
      );
      final entry = TransactionEntry(
        id: 'local-sms:$key',
        sourceKey: key,
        amount: Money.fromRupees(286388.46),
        occurredAt: received,
        source: 'sms',
        status: 'active',
      );
      store.saveProvisional(ns, entry);
      if (edited) {
        db.db.execute(
          "INSERT INTO sync_pending_changes(namespace,entity,entity_id,op,payload_json,field_clocks_json,created_at) VALUES(?, 'transactions', ?, 'upsert', '{}', '{}', 1)",
          [ns, entry.id],
        );
      }
      expect(store.entities(ns, 'transactions'), hasLength(edited ? 1 : 0));
      if (!edited) {
        expect(db.db.select('SELECT * FROM local_needs_review'), hasLength(1));
      }
    });
  }
}
