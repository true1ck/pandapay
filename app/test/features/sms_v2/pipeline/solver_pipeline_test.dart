// Tier 2 through the real phone pipeline: a message no rule matches is read by
// the evidence solver, and its facts flow through instruments, linker, ledger
// and review exactly as a rule's facts do.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/user_cards_repository.dart';
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
