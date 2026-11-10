// One set of messages, read through every list the app builds from the ledger,
// must tell the same story everywhere.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/pending_bills.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:agree';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;
  var n = 0;

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    final json = (jsonDecode(jsonEncode(testRuleBundle().toJson())) as Map)
        .cast<String, Object?>();
    json['solverPack'] =
        (jsonDecode(File('../rules/sms/solver/pack.json').readAsStringSync())
                as Map)
            .cast<String, Object?>();
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: RuleBundle.fromJson(json),
      appVersion: '2.0.0',
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  void send(String sender, String body, String day) {
    n++;
    pipeline.process(
      SmsMessage(
        sender: sender,
        body: body,
        sourceKey: n.toRadixString(16).padLeft(64, '0'),
        observedAt: DateTime.parse('${day}T06:00:00Z'),
      ),
    );
  }

  List<Fact> facts() => FactStore(db.db, namespace: _ns).all();
  List<Event> events() =>
      EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900));

  test('bills: the commitment list and the SMS bill rows agree on every bill', () {
    // A card statement, its payment, a newer statement, and a utility bill.
    send('VM-NEWBNK-S', 'Your credit card statement for card ending 4410 is generated. Total amount due Rs 10,000.00, minimum amount due Rs 500.00, payment due date 25-Oct-2026.', '2026-10-10');
    send('VM-NEWBNK-S', 'Your credit card statement for card ending 4410 is generated. Total amount due Rs 12,000.00, minimum amount due Rs 600.00, payment due date 25-Nov-2026.', '2026-11-10');
    send('VM-NEWBNK-S', 'Your electricity bill of Rs 927.00 for consumer 60013531 is due on 20-Nov-2026.', '2026-11-05');
    final now = DateTime(2026, 11, 12);
    final commitments = billsFromFacts(facts(), events());
    final rows = smsBillRowsFromFacts(facts(), events(), now: now);
    expect(rows.length, commitments.length);
    final byId = {for (final r in rows) r.id: r};
    for (final c in commitments) {
      final r = byId[c.id];
      expect(r, isNotNull, reason: 'a row for ${c.id}');
      expect(r!.dueDate, c.dueOn);
      switch (c.status) {
        case CommitmentStatus.paid:
          expect(r.state, SmsBillState.linked);
        case CommitmentStatus.paymentNotDetected:
          expect(r.state, SmsBillState.paymentNotDetected);
        default:
          expect(r.state, isNot(SmsBillState.linked));
      }
    }
    // The October card statement was replaced by the November one, in both.
    final october = commitments.firstWhere((c) => c.dueOn.month == 10);
    expect(october.status, CommitmentStatus.paymentNotDetected);
    expect(byId[october.id]!.state, SmsBillState.paymentNotDetected);
  });

  test('a card of an unregistered sender: statements replace each other and a payment settles the right one', () {
    send('VM-NEWBNK-S', 'Your credit card statement for card ending 4410 is generated. Total amount due Rs 10,000.00, minimum amount due Rs 500.00, payment due date 25-Oct-2026.', '2026-10-10');
    send('VM-NEWBNK-S', 'Your credit card statement for card ending 4410 is generated. Total amount due Rs 12,000.00, minimum amount due Rs 600.00, payment due date 25-Nov-2026.', '2026-11-10');
    send('VM-NEWBNK-S', 'Payment of Rs 12,000.00 has been received towards your card ending 4410. Thank you.', '2026-11-15');
    // Another card, same sender, same amounts: untouched by that payment.
    send('VM-NEWBNK-S', 'Your credit card statement for card ending 7788 is generated. Total amount due Rs 12,000.00, minimum amount due Rs 600.00, payment due date 25-Nov-2026.', '2026-11-10');
    final bills = billsFromFacts(facts(), events())
      ..sort((a, b) => a.dueOn.compareTo(b.dueOn));
    final byStatus = [for (final b in bills) '${b.dueOn.month}:${b.status.name}'];
    expect(byStatus.where((e) => e == '10:paymentNotDetected'), hasLength(1));
    expect(byStatus.where((e) => e == '11:paid'), hasLength(1), reason: '$byStatus');
    expect(byStatus.where((e) => e == '11:due'), hasLength(1), reason: 'the other card stays unpaid: $byStatus');
  });

  test('money in: the SMS Money-in screen and the transactions agree on income', () {
    send('VM-NEWBNK-S', 'Dear Customer, your A/c XX9988 has been credited with Rs 50,000.00 towards SALARY on 01-11-2026.', '2026-11-01');
    send('VM-NEWBNK-S', 'You have received Rs 2,000.00 from Priya S in your account ending 5566 via UPI on 07-11-2026.', '2026-11-07');
    send('VM-NEWBNK-S', 'Dear Customer, amount of Rs 20,000 has been received by your wallet A/c. Check it https://x.example Sample Loans', '2026-11-08');
    final list = moneyIn(facts(), events(), DateTime.utc(1900), DateTime.utc(2200));
    final screenTotal = list
        .where((i) => i.kind != 'refund')
        .fold<int>(0, (t, i) => t + i.amountMinor);
    final tx = financial
        .entities(_ns, 'transactions')
        .map(TransactionEntry.fromJson)
        .where((t) => t.entryKind.name == 'income')
        .fold<int>(0, (t, e) => t + e.amount.paise);
    expect(screenTotal, tx, reason: 'both screens add up the same income');
    expect(screenTotal, 5000000 + 200000 + 2000000);
  });
}
