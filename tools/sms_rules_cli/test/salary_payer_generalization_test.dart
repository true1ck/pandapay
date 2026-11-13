// Salary credits across bank layouts, through the real rules plus the evidence
// solver (`EvidenceSolver.salaryNote`, applied by `RuleEngine._withSalaryPayer`).
// No rule here is written per layout: the employer is found by where the name
// sits next to the salary word, so a new bank wording needs no new rule.
//
// Two promises are checked: a real salary credit is ALWAYS counted as salary
// (the employer is read when the alert prints one, and its absence never loses
// the money), and wording that only looks like salary (a reversal, a promotion,
// a job scam, a debit, a person called Sal) never is. Every message is synthetic.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

void main() {
  test('salary payer + worst cases', () {
    final source = readRulesFolder('../../rules/sms/v2');
    expect(source.problems, isEmpty);
    final bundle = parseUnsignedBundle(source.bundle);
    final engine = RuleEngine();
    const pre = 'Rs 85000.00 credited to A/c XX1234 on 01-11-26';
    // label, sender, body, expected purpose ('salary' | 'not-salary'), expected payer (null = none, '*' = any)
    final cases = <(String, String, String, String, String?)>[
      ('ach payer', 'VM-NEWBNK-S', '$pre by ACH CR-ACME TECHNOLOGIES-SALARY. Avl Bal Rs 120000.00', 'salary', 'ACME TECHNOLOGIES'),
      ('nach no cr', 'VM-NEWBNK-S', '$pre by NACH-ACME TECHNOLOGIES-SALARY. Avl Bal Rs 120000.00', 'salary', 'ACME TECHNOLOGIES'),
      ('upi slash payer', 'VM-NEWBNK-S', '$pre by UPI/CR/123456789012/ACME TECHNOLOGIES/SALARY. Avl Bal Rs 120000.00', 'salary', 'ACME TECHNOLOGIES'),
      ('label payer', 'VM-NEWBNK-S', '$pre. SALARY CREDIT ACME TECHNOLOGIES. Avl Bal Rs 120000.00', 'salary', 'ACME TECHNOLOGIES'),
      ('salary for month from', 'VM-NEWBNK-S', '$pre - Salary for Oct 2026 from ACME TECHNOLOGIES. Avl Bal Rs 120000.00', 'salary', 'ACME TECHNOLOGIES'),
      ('payer then salary no rail', 'VM-NEWBNK-S', '$pre ACME TECHNOLOGIES SALARY. Avl Bal Rs 120000.00', 'salary', 'ACME TECHNOLOGIES'),
      ('sbi salary first', 'BG-CBSXXX-S', 'Your A/C XXXXX123456 has credit for SALARY ACME TECHNOLOGIES of Rs 85,000.00 on 01/11/26. Avl Bal Rs 1,04,079.26.-BANK', 'salary', 'ACME TECHNOLOGIES'),
      ('sbi salary first month', 'BG-CBSXXX-S', 'Your A/C XXXXX123456 has credit for SALARY OCT 2026 ACME TECHNOLOGIES of Rs 85,000.00 on 01/11/26.', 'salary', 'ACME TECHNOLOGIES'),
      ('sbi payer first', 'BG-CBSXXX-S', 'Your A/C XXXXX123456 has credit for ACME TECHNOLOGIES SALARY of Rs 85,000.00 on 01/11/26.', 'salary', 'ACME TECHNOLOGIES'),
      ('sbi no employer', 'BG-CBSXXX-S', 'Your A/C XXXXX123456 has credit for SALARY of Rs 85,000.00 on 01/11/26.', 'salary', null),
      // worst cases: still salary, payer may be absent but the money is never lost
      ('employer with parens', 'VM-NEWBNK-S', '$pre by ACH CR-ACME (INDIA) PVT LTD-SALARY. Avl Bal Rs 120000.00', 'salary', '*'),
      ('employer with ampersand', 'VM-NEWBNK-S', '$pre by NEFT-ACME & SONS-SALARY. Avl Bal Rs 120000.00', 'salary', '*'),
      ('upper case shouting', 'VM-NEWBNK-S', 'RS 85000.00 CREDITED TO A/C XX1234 ON 01-11-26 BY UPI/CR/123456789012/ACME TECHNOLOGIES/SALARY. AVL BAL RS 120000.00', 'salary', 'ACME TECHNOLOGIES'),
      ('rupee sign + extra spaces', 'VM-NEWBNK-S', '₹85,000.00   credited  to  A/c   XX1234  on 01-11-26   by ACH CR-ACME TECHNOLOGIES-SALARY.', 'salary', 'ACME TECHNOLOGIES'),
      ('line breaks', 'VM-NEWBNK-S', 'Rs 85000.00 credited to A/c XX1234\non 01-11-26\nby ACH CR-ACME TECHNOLOGIES-SALARY\nAvl Bal Rs 120000.00', 'salary', '*'),
      ('tiny salary', 'VM-NEWBNK-S', 'Rs 0.50 credited to A/c XX1234 on 01-11-26 by ACH CR-ACME TECHNOLOGIES-SALARY.', 'salary', '*'),
      ('huge salary', 'VM-NEWBNK-S', 'Rs 1,00,00,000.00 credited to A/c XX1234 on 01-11-26 by ACH CR-ACME TECHNOLOGIES-SALARY.', 'salary', '*'),
      ('long employer name', 'VM-NEWBNK-S', '$pre by ACH CR-${'ACME ' * 20}TECHNOLOGIES-SALARY.', 'salary', '*'),
      ('mask 4 digits only', 'VM-NEWBNK-S', 'Rs 85000.00 credited to A/c ending 1234 on 01-11-26 by ACH CR-ACME TECHNOLOGIES-SALARY.', 'salary', '*'),
      // must NOT be salary
      ('salary reversed', 'VM-NEWBNK-S', '$pre by ACH CR-ACME TECHNOLOGIES-SALARY REVERSAL. Avl Bal Rs 120000.00', 'not-salary', null),
      ('salary advance repay debit', 'VM-NEWBNK-S', 'Rs 5000.00 debited from A/c XX1234 on 01-11-26 by ACH DR-ACME TECHNOLOGIES-SALARY ADVANCE. Avl Bal Rs 100000.00', 'not-salary', null),
      ('not credited', 'VM-NEWBNK-S', 'Rs 85000.00 not credited to A/c XX1234 on 01-11-26 by ACH CR-ACME TECHNOLOGIES-SALARY.', 'not-salary', null),
      ('will be credited', 'VM-NEWBNK-S', 'Rs 85000.00 will be credited to A/c XX1234 on 01-11-26 by ACH CR-ACME TECHNOLOGIES-SALARY.', 'not-salary', null),
      ('salary loan lure', 'VM-NEWBNK-S', 'Get a loan on your salary. Rs 85000.00 credited to A/c XX1234 on 01-11-26 if you apply today. Click http://x.in/abc', 'not-salary', null),
      ('salary account promo', 'VM-NEWBNK-S', 'Open a Salary Account today and get Rs 500 credited to your A/c XX1234. T&C apply', 'not-salary', null),
      ('job scam', 'VM-NEWBNK-S', 'Now hiring! Work from home, salary is Rs 30,000 per month. Apply https://x.example', 'not-salary', null),
      ('salary slip upcoming', 'VM-NEWBNK-S', 'Your salary slip for Oct 2026 is ready. Net pay Rs 85000.00 will be credited on 01-11-26', 'not-salary', null),
      ('card credited salary word', 'VM-NEWBNK-S', 'Rs 500.00 credited to your credit card ending 1234 on 01-11-26. Salary Day offer', 'not-salary', null),
      ('person named Sal', 'VM-NEWBNK-S', '$pre by UPI/CR/123456789012/SAL KUMAR/PAYMENT. Avl Bal Rs 120000.00', 'not-salary', null),
      ('salon payee', 'VM-NEWBNK-S', '$pre by UPI/CR/123456789012/SALON TRENDS/PAYMENT. Avl Bal Rs 120000.00', 'not-salary', null),
    ];
    final bad = <String>[];
    final out = StringBuffer();
    for (final (label, sender, body, want, payer) in cases) {
      final o = engine.interpretDetailed(
        SmsMessage(sender: sender, body: body, observedAt: DateTime.utc(2026, 11, 1, 7), sourceKey: 'k'),
        bundle,
        appVersion: 'test',
      );
      var purpose = '-', dir = '-';
      String? got;
      for (final f in o.result.facts) {
        final j = f.toJson();
        if (j['factType'] == 'movement') {
          final a = j['attrs'] as Map;
          purpose = '${a['purpose']}';
          dir = '${a['direction']}';
          final cp = j['counterparty'];
          got = cp is Map ? cp['name'] as String? : null;
        }
      }
      final isSalary = purpose == 'salary' && dir == 'credit';
      var ok = want == 'salary' ? isSalary : !isSalary;
      if (ok && want == 'salary' && payer != '*' && payer != got) ok = false;
      out.writeln('${ok ? 'ok  ' : 'FAIL'} ${label.padRight(28)} ${'${o.winnerId}'.padRight(30)} purpose=$purpose dir=$dir payer=$got');
      if (!ok) bad.add(label);
    }
    // ignore: avoid_print
    print(out);
    expect(bad, isEmpty);
  });
}
