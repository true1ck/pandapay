import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/ai_withdrawal.dart';
import 'package:pandapay/features/sms_v2/pipeline/salary_recheck.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_pipeline.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/rules.dart';

const _ns = 'user:salary';

/// Synthetic alert in the layout some banks print: no rail word, the employer
/// sits between a reference and "Salary". The names and numbers are invented.
const _narration =
    'Update! INR 45,000.00 deposited in Example Bank A/c XX1234 on 30-OCT-26 for A2AINT01-ACME TECHNOLOGIES PVT LTD-Salary-Salary Oct 2026.Avl bal INR 1,38,743.58.';

/// The same alert with no employer anywhere in it.
const _noEmployer =
    'Rs 85000.00 credited to A/c XX1234 on 01-11-26. SALARY CREDIT. Avl Bal Rs 120000.00';

RuleBundle _withSolver(RuleBundle b, {bool Function(String id)? drop, bool solver = true}) {
  final json = (jsonDecode(jsonEncode(b.toJson())) as Map).cast<String, Object?>();
  if (drop != null) {
    json['rules'] = [
      for (final r in json['rules'] as List)
        if (!drop((r as Map)['id'] as String)) r,
    ];
  }
  if (solver) {
    json['solverPack'] =
        (jsonDecode(File('../rules/sms/solver/pack.json').readAsStringSync()) as Map)
            .cast<String, Object?>();
  }
  return RuleBundle.fromJson(json);
}

void main() {
  late AppDatabase db;
  late FinancialStore financial;
  late RuleBundle current;
  late RuleBundle older;
  late SmsIntakeRepository intake;
  final sent = <SmsMessage>[];

  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    financial = FinancialStore(db);
    SmsV2Schema.ensure(db.db);
    current = _withSolver(testRuleBundle());
    // What a phone ran before the employer reading existed: the rules, no
    // evidence solver, so a salary alert with no cue word names nobody.
    older = _withSolver(
      testRuleBundle(),
      drop: (id) => id.startsWith('GEN-ACCT-SALARY-NARRATION'),
      solver: false,
    );
    intake = SmsIntakeRepository(db);
    sent.clear();
  });
  tearDown(() {
    financial.dispose();
    db.db.dispose();
  });

  SmsV2Pipeline pipeline(RuleBundle b) => SmsV2Pipeline(
    financial: financial,
    namespace: _ns,
    bundle: b,
    appVersion: '2.0.0',
  );

  void receive(RuleBundle b, String sender, String body, String day, {bool keep = true}) {
    final sms = QueuedSms(
      sender: sender,
      body: body,
      receivedAt: DateTime.parse('${day}T06:00:00Z'),
    );
    if (keep) intake.remember(_ns, sms);
    final m = SmsMessage(
      sender: sender,
      body: body,
      sourceKey: smsSourceKey(_ns, sender, body),
      observedAt: sms.receivedAt,
    );
    sent.add(m);
    pipeline(b).process(m, backfill: true);
  }

  /// "income:4500000:ACME TECHNOLOGIES PVT LTD" for each active transaction.
  List<String> rows() =>
      financial
          .entities(_ns, 'transactions')
          .map(TransactionEntry.fromJson)
          .where((t) => t.status == 'active')
          .map((t) => '${t.entryKind.name}:${t.amount.paise}:${t.merchantName}')
          .toList()
        ..sort();

  /// What the sync does after a rules update.
  int recheck(RuleBundle b) {
    final sources = SalaryRecheck(
      financial: financial,
      namespace: _ns,
      bundle: b,
    ).sourcesToRecheck();
    final taken = AiWithdrawal(
      financial: financial,
      namespace: _ns,
      bundle: b,
    ).withdraw(sources);
    final again = [
      for (final m in sent)
        if (taken.contains(m.sourceKey)) m,
    ];
    if (again.isNotEmpty) pipeline(b).processBatch(again, backfill: true);
    return taken.length;
  }

  test('salary read with no employer is still income and says Salary received', () {
    receive(older, 'VD-EXAMPL-S', _narration, '2026-10-30');
    expect(rows(), ['income:4500000:Salary received']);
  });

  test('a newer rule that finds the employer fills it in, once', () {
    receive(older, 'VD-EXAMPL-S', _narration, '2026-10-30');
    expect(rows(), ['income:4500000:Salary received']);

    expect(recheck(current), 1);

    expect(rows(), ['income:4500000:ACME TECHNOLOGIES'], reason: 'one row, not two');
    expect(recheck(current), 0, reason: 'nothing is left to read again');
  });

  test('a salary the rules still cannot name stays one income row', () {
    receive(current, 'VD-EXAMPL-S', _noEmployer, '2026-11-01');
    expect(rows(), ['income:8500000:Salary received']);

    recheck(current);
    recheck(current);

    expect(rows(), ['income:8500000:Salary received']);
  });

  test('a message that is no longer on the phone is left as it is', () {
    receive(older, 'VD-EXAMPL-S', _narration, '2026-10-30', keep: false);
    expect(recheck(current), 0);
    expect(rows(), ['income:4500000:Salary received']);
  });

  test('a salary that already names its employer is not touched', () {
    receive(current, 'VD-EXAMPL-S', _narration, '2026-10-30');
    expect(rows(), ['income:4500000:ACME TECHNOLOGIES']);
    expect(recheck(current), 0);
  });

  test('ordinary credits and spends are never re-read', () {
    receive(
      current,
      'VD-EXAMPL-S',
      'Rs 500.00 credited to A/c XX1234 on 01-11-26 by Cash. Avl Bal Rs 1000.00',
      '2026-11-01',
    );
    receive(
      current,
      'VD-EXAMPL-S',
      'Rs 250.00 debited from A/c XX1234 on 02-11-26 by UPI/123456789012/SAMPLE SHOP. Avl Bal Rs 750.00',
      '2026-11-02',
    );
    expect(recheck(current), 0);
  });
}
