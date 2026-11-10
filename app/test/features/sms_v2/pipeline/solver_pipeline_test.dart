// Tier 2 through the real phone pipeline: a message no rule matches is read by
// the evidence solver, and its facts flow through instruments, linker, ledger
// and review exactly as a rule's facts do.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart' show QueuedSms;
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/event_store.dart';
import 'package:pandapay/features/sms_v2/storage/fact_store.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

const _ns = 'user:solver';

Map<String, Object?> _read(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late SmsV2Pipeline pipeline;

  RuleBundle bundle({bool pack = true}) {
    final json = _read('../contracts/sms/v2/fixtures/valid/bundle/full.json');
    if (pack) json['solverPack'] = _read('../rules/sms/solver/pack.json');
    return RuleBundle.fromJson(json);
  }

  SmsV2Pipeline build(RuleBundle b) => SmsV2Pipeline(
    financial: financial,
    namespace: _ns,
    bundle: b,
    appVersion: '2.0.0',
  );

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    pipeline = build(bundle());
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  var counter = 0;
  SmsMessage sms(String body, {String sender = 'VM-NEWBNK-S'}) {
    counter++;
    return SmsMessage(
      sender: sender,
      body: body,
      sourceKey: counter.toRadixString(16).padLeft(64, '0'),
      observedAt: DateTime.utc(2026, 11, 9, 6),
    );
  }

  List<Fact> factsOf(SmsMessage m) => FactStore(db.db, namespace: _ns).forSource(m.sourceKey);
  List<TransactionEntry> transactions() =>
      financial.entities(_ns, 'transactions').map(TransactionEntry.fromJson).toList();

  test('an unmatched spend alert becomes a counted transaction through the real stores', () {
    final m = sms('Rs 540.00 debited from A/c XX8812 on 05-Nov-26 towards UPI/DR/330098871/CHAI POINT. Avl bal Rs 12,300.45');
    expect(pipeline.process(m), isTrue);
    final facts = factsOf(m);
    expect(facts, hasLength(1));
    expect(facts.single.provenance.ruleId, 'SOLVER-DEBIT');
    final entries = LedgerStore(db.db, namespace: _ns).list();
    expect(entries.single.amountMinor, 54000);
    expect(EventStore(db.db, namespace: _ns).get(entries.single.eventId)!.type, isNot(EventType.unknown));
    final row = transactions().single;
    expect(row.amount.paise, 54000);
    expect(row.pipelineVersion, 2);
    // Processing the same message again changes nothing.
    expect(pipeline.process(m), isFalse);
    expect(transactions(), hasLength(1));
  });

  test('without the pack the same message is unresolved and nothing is counted', () {
    final plain = build(bundle(pack: false));
    final m = sms('Rs 540.00 debited from A/c XX8812 on 05-Nov-26 towards UPI/DR/330098871/CHAI POINT. Avl bal Rs 12,300.45');
    plain.process(m);
    expect(transactions(), isEmpty);
    expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
    expect(
      db.db.select("SELECT * FROM v2_review_items WHERE kind='template'"),
      isNotEmpty,
    );
  });

  test('a card statement is a bill fact with its dates, and is never counted as spending', () {
    final m = sms(
      'Your credit card statement for card ending 4410 dated 01-Nov-2026 is generated. '
      'Total amount due Rs 23,540.00, minimum amount due Rs 1,177.00, payment due date 20-Nov-2026.',
      sender: 'VM-CARDBK-S',
    );
    pipeline.process(m);
    final bill = factsOf(m).whereType<BillDueFact>().single;
    expect(bill.dueDate, '2026-11-20');
    expect(bill.statementDate, '2026-11-01');
    expect(bill.amount(AmountRole.dueTotal)!.minor, 2354000);
    expect(bill.amount(AmountRole.dueMinimum)!.minor, 117700);
    expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
    expect(transactions(), isEmpty);
  });

  test('a biller receipt (a paid e-bill) is evidence and never counts as spending by itself', () {
    final m = sms(
      'Payment of Rs 1,420.00 received for your electricity bill, consumer no 100234. Thank you. Receipt no 5566.',
      sender: 'BZ-POWERC',
    );
    pipeline.process(m);
    final movement = factsOf(m).whereType<MovementFact>().single;
    expect(movement.evidenceOnly, isTrue);
    expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
    expect(transactions(), isEmpty);
  });

  test('a card bill payment received is a transfer leg, not income and not spending', () {
    final m = sms('Payment of Rs 23,540.00 has been received towards your card ending 4410. Thank you.', sender: 'VM-CARDBK-S');
    pipeline.process(m);
    final movement = factsOf(m).whereType<MovementFact>().single;
    expect(movement.purpose, MovementPurpose.cardPayment);
    final types = LedgerStore(db.db, namespace: _ns).list().map((e) => e.isSpend).toList();
    expect(types.where((s) => s), isEmpty, reason: 'a card payment must not count as spending');
  });

  test('a subscription debit alert is counted and records the mandate', () {
    final m = sms('UPI AutoPay: Rs 149 debited from A/c XX1111 for EXAMPLE VIDEO on 08-Nov. Mandate ID 5566.');
    pipeline.process(m);
    final facts = factsOf(m);
    expect(facts.whereType<MandateFact>(), hasLength(1));
    expect((facts.whereType<MovementFact>().single).mandateRef, '5566');
    expect(transactions().single.amount.paise, 14900);
  });

  test('a promotion that quotes amounts is ignored and counts nothing', () {
    final m = sms('Flat Rs 500 OFF on orders above Rs 2,999. Use code SAVE500. Valid till 15-Nov. T&C apply.', sender: 'VM-SHOPXX-P');
    pipeline.process(m);
    expect(factsOf(m).single, isA<InfoFact>());
    expect(transactions(), isEmpty);
    expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
  });

  test('a message the solver is not sure of goes to review, never counted', () {
    final m = sms('Quantum flux of Rs 4,321 noted on A/c XX1111');
    pipeline.process(m);
    expect(transactions(), isEmpty);
    expect(
      db.db.select("SELECT * FROM v2_review_items WHERE kind='template' AND status='open'"),
      isNotEmpty,
    );
  });

  test('a mandate set-up and its AutoPay debit become one NAMED subscription', () {
    final setup = sms('Mandate created for Rs 149 for SAMPLE VIDEO. Mandate ID 5566. Auto debit will happen on the 8th of every month.');
    final charge = sms('UPI AutoPay: Rs 149 debited from A/c XX1111 for SAMPLE VIDEO on 08-Nov. Mandate ID 5566.');
    pipeline.process(setup);
    pipeline.process(charge);
    final rows = subscriptionsFromLedger(
      FactStore(db.db, namespace: _ns).all(),
      EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900)),
      now: DateTime.utc(2026, 11, 9),
    );
    expect(rows, hasLength(1), reason: 'one service, not one per message');
    expect(rows.single.displayName.toUpperCase(), contains('SAMPLE VIDEO'));
    expect(rows.single.displayName, isNot(contains('Unknown')));
  });

  test('a bill and its reminder for the same cycle from a sender no rule knows are one bill', () {
    final statement = sms(
      'Your credit card statement for card ending 4410 is generated. Total amount due Rs 23,540.00, minimum amount due Rs 1,177.00, payment due date 20-Nov-2026.',
      sender: 'VM-NEWBNK-S',
    );
    final reminder = sms(
      'Reminder: your credit card bill of Rs 23,540 for card ending 4410 is due on 20-Nov-2026. Pay now to avoid late charges.',
      sender: 'VM-NEWBNK-S',
    );
    pipeline.process(statement);
    pipeline.process(reminder);
    final bills = FactStore(db.db, namespace: _ns).all().whereType<BillDueFact>().toList();
    expect(bills, hasLength(2));
    expect(bills.map((b) => b.instrument?.issuerSlug).toSet(), {'newbnk'});
    expect(bills.map((b) => b.instrument?.maskDigits).toSet(), {'4410'});
    expect(bills.map((b) => b.dueDate).toSet(), {'2026-11-20'});
  });

  group('a reminder with an amount but no due date', () {
    const statementText =
        'Your credit card statement for card ending 4410 is generated. Total amount due Rs 23,540.00, minimum amount due Rs 1,177.00, payment due date 20-Nov-2026.';
    String nudge(String amount, {String card = '4410'}) =>
        'Reminder: your credit card bill of Rs $amount for card ending $card is due. Pay on or before the due date to avoid late charges.';

    List<BillDueFact> bills() =>
        FactStore(db.db, namespace: _ns).all().whereType<BillDueFact>().toList();
    int openReviews() => db.db.select(
      "SELECT count(*) c FROM v2_review_items WHERE namespace=? AND status='open'",
      [_ns],
    ).first['c'] as int;

    test('borrows the due date of the one statement it can only be about, as an inference', () {
      pipeline.process(sms(statementText));
      final m = sms(nudge('23,540'));
      pipeline.process(m);
      final fact = factsOf(m).whereType<BillDueFact>().single;
      expect(fact.dueDate, '2026-11-20');
      expect(fact.instrument?.maskDigits, '4410');
      expect(fact.confidence, lessThan(0.7));
      expect(fact.provenance.ruleId, 'SOLVER-BILL-DUE-INFERRED');
      // It joins the statement's cycle: still one bill, still the statement's amount.
      final rows = billsFromFacts(FactStore(db.db, namespace: _ns).all(), const []);
      expect(rows, hasLength(1));
      expect(rows.single.amount!.paise, 2354000);
      // A person is asked to confirm the inference.
      expect(openReviews(), greaterThan(0));
    });

    test('the minimum amount is matched to the statement minimum', () {
      pipeline.process(sms(statementText));
      final m = sms(nudge('1,177'));
      pipeline.process(m);
      expect(factsOf(m).whereType<BillDueFact>().single.amount(AmountRole.dueMinimum)!.minor, 117700);
      expect(billsFromFacts(FactStore(db.db, namespace: _ns).all(), const []).single.amount!.paise, 2354000);
    });

    test('an amount that matches nothing on the statement stays unresolved', () {
      pipeline.process(sms(statementText));
      final m = sms(nudge('9,999'));
      pipeline.process(m);
      expect(factsOf(m), isEmpty);
      expect(bills(), hasLength(1));
    });

    test('another card is never borrowed from', () {
      pipeline.process(sms(statementText));
      final m = sms(nudge('23,540', card: '7788'));
      pipeline.process(m);
      expect(factsOf(m), isEmpty);
    });

    const emiBill =
        'Dear Customer, your EMI of Rs 4,500.00 for loan A/c XX3345 is due on 05-12-2026. Please maintain sufficient balance in your account.';
    const emiNudge =
        'Dear customer, paying your EMI of Rs 4,500.00 on or before the due date helps in avoiding penalty charges. Please maintain sufficient balance in your bank account to honour your payment on your due date.';

    test('an EMI nudge borrows the due date of the one earlier EMI bill of that sender and amount', () {
      pipeline.process(sms(emiBill, sender: 'VM-SAMPLF-S'));
      final m = sms(emiNudge, sender: 'VM-SAMPLF-S');
      pipeline.process(m);
      final fact = factsOf(m).whereType<BillDueFact>().single;
      expect(fact.dueDate, '2026-12-05');
      expect(fact.confidence, lessThan(0.7));
      expect(billsFromFacts(FactStore(db.db, namespace: _ns).all(), const []), hasLength(1));
    });

    test('an EMI nudge from another sender, or for another amount, borrows nothing', () {
      pipeline.process(sms(emiBill, sender: 'VM-SAMPLF-S'));
      final other = sms(emiNudge, sender: 'VM-OTHERB-S');
      pipeline.process(other);
      expect(factsOf(other), isEmpty);
      final amount = sms(emiNudge.replaceAll('4,500.00', '7,000.00'), sender: 'VM-SAMPLF-S');
      pipeline.process(amount);
      expect(factsOf(amount), isEmpty);
    });

    test('two loans with the same EMI amount are ambiguous', () {
      pipeline.process(sms(emiBill, sender: 'VM-SAMPLF-S'));
      pipeline.process(
        sms(emiBill.replaceAll('XX3345', 'XX9911').replaceAll('05-12-2026', '10-12-2026'), sender: 'VM-SAMPLF-S'),
      );
      final m = sms(emiNudge, sender: 'VM-SAMPLF-S');
      pipeline.process(m);
      expect(factsOf(m), isEmpty);
    });

    SmsMessage captured(String body, String sender, DateTime at) {
      // As the phone does: kept in the capture store before the pipeline reads it.
      SmsIntakeRepository(db).remember(_ns, QueuedSms(sender: sender, body: body, receivedAt: at));
      return SmsMessage(
        sender: sender,
        body: body,
        sourceKey: smsSourceKey(_ns, sender, body),
        observedAt: at,
      );
    }

    test('a reminder read in an earlier chunk is completed when its statement arrives in a later one', () {
      final reminder = captured(nudge('23,540'), 'VM-NEWBNK-S', DateTime.utc(2026, 11, 12, 6));
      final statement = captured(statementText, 'VM-NEWBNK-S', DateTime.utc(2026, 11, 9, 6));
      // Chunk 1 holds the newer reminder; the statement is in the next chunk.
      pipeline.processBatch([reminder]);
      expect(factsOf(reminder), isEmpty, reason: 'nothing to borrow from yet');
      pipeline.processBatch([statement]);
      final fact = factsOf(reminder).whereType<BillDueFact>().single;
      expect(fact.dueDate, '2026-11-20');
      expect(fact.provenance.ruleId, 'SOLVER-BILL-DUE-INFERRED');
      // Done once: a third chunk does not read it again or reopen anything.
      pipeline.processBatch([captured('Rs.540.00 spent on HDFC Bank Card x5678 at CHAI POINT on 13-11-26', 'VM-HDFCBK-S', DateTime.utc(2026, 11, 13, 6))]);
      expect(factsOf(reminder), hasLength(1), reason: 'not read or stored a second time');
      expect(
        db.db.select("SELECT count(*) c FROM v2_sync_state WHERE namespace=? AND key LIKE 'history-pending:%'", [_ns]).first['c'],
        0,
        reason: 'no longer waiting',
      );
    });

    test('a message that never finds its statement stays in review and is not read over and over', () {
      final reminder = captured(nudge('23,540'), 'VM-NEWBNK-S', DateTime.utc(2026, 11, 12, 6));
      pipeline.processBatch([reminder]);
      // Dismiss its review question, as a person may.
      db.db.execute("UPDATE v2_review_items SET status='dismissed' WHERE namespace=?", [_ns]);
      // Unrelated history arrives (a spend), which wakes the retry.
      pipeline.processBatch([
        captured('Rs.540.00 spent on HDFC Bank Card x5678 at CHAI POINT on 01-11-26', 'VM-HDFCBK-S', DateTime.utc(2026, 11, 1, 6)),
      ]);
      expect(factsOf(reminder), isEmpty);
      final open = db.db.select(
        "SELECT count(*) c FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open'",
        [_ns],
      ).first['c'] as int;
      expect(open, 0, reason: 'a dismissed question is not reopened by the retry');
    });

    test('a batch handed over newest first still completes the reminder', () {
      final statement = sms(statementText);
      final reminder = SmsMessage(
        sender: 'VM-NEWBNK-S',
        body: nudge('23,540'),
        sourceKey: 'f' * 64,
        observedAt: DateTime.utc(2026, 11, 12, 6),
      );
      // The statement arrived 3 days before the reminder, but is listed after it.
      pipeline.processBatch([reminder, statement]);
      expect(factsOf(reminder).whereType<BillDueFact>().single.dueDate, '2026-11-20');
    });

    test('a refund listed before its spend is still linked', () {
      final spend = SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: 'Rs.540.00 spent on HDFC Bank Card x5678 at CHAI POINT on 01-11-26',
        sourceKey: 'e' * 64,
        observedAt: DateTime.utc(2026, 11, 1, 6),
      );
      final refund = SmsMessage(
        sender: 'VM-NEWPAY-S',
        body: 'Refund for order CHAI POINT of Rs 540.00 is successfully processed to your Sample Payment Wallet.',
        sourceKey: 'd' * 64,
        observedAt: DateTime.utc(2026, 11, 5, 6),
      );
      pipeline.processBatch([refund, spend]);
      expect(factsOf(refund).whereType<MovementFact>(), hasLength(1));
    });

    test('with no statement on file there is nothing to borrow', () {
      final m = sms(nudge('23,540'));
      pipeline.process(m);
      expect(factsOf(m), isEmpty);
    });

    test('two statements with the same amount are ambiguous, so it stays unresolved', () {
      pipeline.process(sms(statementText));
      pipeline.process(
        sms(statementText.replaceAll('20-Nov-2026', '20-Dec-2026')),
      );
      final m = sms(nudge('23,540'));
      pipeline.process(m);
      expect(factsOf(m), isEmpty);
    });
  });

  group('a deposit confirmation', () {
    const confirm = 'Hi Ravi, your deposit of Rs 5,000.00 was processed successfully. - Sample Savings';
    int events() => EventStore(db.db, namespace: _ns).listSince(DateTime.utc(1900)).length;

    test('joins the one bank debit of that amount and adds no second spend', () {
      pipeline.process(
        sms('Rs 5,000.00 debited from A/c XX1234 on 05-Nov-26 via UPI to SAMPLE SAVINGS. Avl Bal Rs 20,000.00', sender: 'VM-HDFCBK-S'),
      );
      final before = events();
      final m = sms(confirm, sender: 'VM-SAMPL-S');
      pipeline.process(m);
      final fact = factsOf(m).whereType<MovementFact>().single;
      expect(fact.evidenceOnly, isTrue);
      expect(fact.purpose, MovementPurpose.investment);
      expect(events(), before, reason: 'the confirmation joined the debit');
      expect(transactions().where((t) => t.entryKind.name == 'spend' || t.entryKind.name == 'transfer'), hasLength(1));
    });

    test('with no matching debit it is never counted (the receipt sweep asks later)', () {
      final m = sms(confirm, sender: 'VM-SAMPL-S');
      pipeline.process(m);
      expect(transactions(), isEmpty);
      expect(factsOf(m).whereType<MovementFact>().single.evidenceOnly, isTrue);
    });
  });

  group('a refund that names no account', () {
    SmsMessage spend(String day, {String merchant = 'CHAI POINT', String card = '5678'}) {
      counter++;
      return SmsMessage(
        sender: 'VM-HDFCBK-S',
        body: 'Rs.540.00 spent on HDFC Bank Card x$card at $merchant on 01-11-26',
        sourceKey: counter.toRadixString(16).padLeft(64, '0'),
        observedAt: DateTime.parse('${day}T06:00:00Z'),
      );
    }

    SmsMessage refund({String merchant = 'CHAI POINT', String amount = '540.00', String day = '2026-11-05'}) {
      counter++;
      return SmsMessage(
        sender: 'VM-NEWPAY-S',
        body: 'Refund for order $merchant of Rs $amount is successfully processed to your Sample Payment Wallet.',
        sourceKey: counter.toRadixString(16).padLeft(64, '0'),
        observedAt: DateTime.parse('${day}T06:00:00Z'),
      );
    }

    List<Fact> movements(SmsMessage m) => factsOf(m).whereType<MovementFact>().toList();

    test('links to the one earlier spend of that amount, as an inference, and is not a debit', () {
      pipeline.process(spend('2026-11-01'));
      final m = refund();
      pipeline.process(m);
      final fact = movements(m).single as MovementFact;
      expect(fact.direction, Direction.credit);
      expect(fact.purpose, MovementPurpose.refund);
      expect(fact.confidence, lessThan(0.7));
      expect(fact.provenance.ruleId, 'SOLVER-REFUND-INFERRED');
      final rows = transactions();
      expect(rows.where((t) => t.entryKind.name == 'spend'), hasLength(1));
      expect(rows.where((t) => t.entryKind.name == 'refund'), hasLength(1));
    });

    test('with no earlier spend it stays unresolved', () {
      final m = refund();
      pipeline.process(m);
      expect(factsOf(m), isEmpty);
    });

    test('two earlier spends of that amount are ambiguous', () {
      pipeline.process(spend('2026-11-01'));
      pipeline.process(spend('2026-11-02', card: '1111'));
      final m = refund();
      pipeline.process(m);
      expect(factsOf(m), isEmpty);
    });

    test('a spend at an unrelated merchant is not the original', () {
      pipeline.process(spend('2026-11-01', merchant: 'PETROL STATION'));
      final m = refund();
      pipeline.process(m);
      expect(factsOf(m), isEmpty);
    });

    test('a different amount, or a spend older than 90 days, is not the original', () {
      pipeline.process(spend('2026-11-01'));
      final other = refund(amount: '999.00');
      pipeline.process(other);
      expect(factsOf(other), isEmpty);
      final old = refund(day: '2027-03-10');
      pipeline.process(old);
      expect(factsOf(old), isEmpty);
    });
  });

  test('a message a rule matches is read by the rule, never by the solver', () {
    final b = bundle();
    final example = b.rules.first.examples.first;
    final m = SmsMessage(
      sender: example.sender,
      body: example.body,
      sourceKey: 'f' * 64,
      observedAt: DateTime.utc(2026, 11, 1, 7),
    );
    build(b).process(m);
    expect(
      factsOf(m).every((f) => !f.provenance.ruleId.startsWith('SOLVER-')),
      isTrue,
    );
  });
}
