import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_text_hint.dart';
import 'package:pandapay/features/sms_v2/pipeline/intake_gate.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

// The intake gate reads keywords and rejects some real transactions. A header
// message it rejects gets one pass through the rules before it is dropped.
// Every message here is invented.
const _ns = 'user:test';

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late RuleBundle bundle;
  late SmsV2Pipeline pipeline;

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    bundle = RuleBundle.fromJson(
      (jsonDecode(
                File(
                  '../contracts/sms/v2/fixtures/valid/bundle/full.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>(),
    );
    pipeline = SmsV2Pipeline(
      financial: financial,
      namespace: _ns,
      bundle: bundle,
      appVersion: '2.0.0',
    );
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  // The rule reads this spend, but the "convert to EMI" footer makes the
  // keyword gate call it a promotion.
  const spendWithEmiFooter =
      'Rs.499.00 spent on HDFC Bank Card x5678 at SWIGGY on 2026-11-01:12:30:11. '
      'Avl Lmt: Rs.45,000.00. To convert this txn to EMI give a missed call on '
      '1800123456. Know more about EMI';

  String? decisionOf(String sender, String body) =>
      SmsIntakeRepository(
        db,
      ).decision(_ns, smsSourceKey(_ns, sender, body))?.decision;

  QueuedSms sms(String sender, String body) => QueuedSms(
    sender: sender,
    body: body,
    receivedAt: DateTime.utc(2026, 11, 1, 7),
  );

  group('gateRejectionMayBeOverruled', () {
    test('a bank header may be overruled, with or without the iPhone tag', () {
      expect(gateRejectionMayBeOverruled('VM-HDFCBK-S'), isTrue);
      expect(gateRejectionMayBeOverruled('HDFCBK-S(smsft_fi)'), isTrue);
    });

    test('promotional routes, contact names and blanks may not', () {
      expect(gateRejectionMayBeOverruled('VM-HDFCBK-P'), isFalse);
      expect(gateRejectionMayBeOverruled('Rahul Sharma'), isFalse);
      expect(gateRejectionMayBeOverruled('  '), isFalse);
    });
  });

  test('the keyword gate alone rejects the EMI-footer spend', () {
    expect(
      classifySmsV2Intake('VM-HDFCBK-S', spendWithEmiFooter).kind,
      isNot(SmsTriageKind.financialCandidate),
    );
  });

  test('a spend the gate rejects but a rule reads is still captured', () {
    SmsImportStore(
      financial,
      v2Pipeline: pipeline,
    ).capture(_ns, sms('VM-HDFCBK-S', spendWithEmiFooter));

    expect(decisionOf('VM-HDFCBK-S', spendWithEmiFooter), 'matched');
    final entries = LedgerStore(db.db, namespace: _ns).list();
    expect(entries.single.amountMinor, 49900);
    expect(entries.single.isSpend, isTrue);
  });

  test('a promotion no rule reads stays ignored', () {
    const promo =
        'Dear Customer, your Rs.50,000 spends are eligible for conversion to '
        'EMI. Call 1800123456 to convert.';
    SmsImportStore(
      financial,
      v2Pipeline: pipeline,
    ).capture(_ns, sms('VM-HDFCBK-S', promo));

    expect(decisionOf('VM-HDFCBK-S', promo), 'ignored');
    expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
  });

  test('a promotional route stays ignored even when a rule would read it', () {
    SmsImportStore(
      financial,
      v2Pipeline: pipeline,
    ).capture(_ns, sms('VM-HDFCBK-P', spendWithEmiFooter));

    expect(decisionOf('VM-HDFCBK-P', spendWithEmiFooter), 'ignored');
    expect(LedgerStore(db.db, namespace: _ns).list(), isEmpty);
  });
}
