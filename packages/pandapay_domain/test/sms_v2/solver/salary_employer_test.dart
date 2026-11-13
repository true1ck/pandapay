// The employer of a salary credit is found by where the name sits next to the
// salary word, not by the layout around it (`EvidenceSolver.salaryNote`). These
// cases are about what must NOT be taken for an employer as much as what must.
// Every message is synthetic.
import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2_solver.dart';
import 'package:test/test.dart';

const _packPath = '../../rules/sms/solver/pack.json';

void main() {
  late EvidenceSolver solver;
  setUpAll(() {
    solver = EvidenceSolver(
      SolverPack.fromJson(
        (jsonDecode(File(_packPath).readAsStringSync()) as Map).cast<String, dynamic>(),
      ),
    );
  });

  String? employer(String body) => solver.salaryNote(body).employer;

  const pre = 'Rs 85000.00 credited to A/c XX1234 on 01-11-26';

  group('the same employer, whatever the layout', () {
    final layouts = <String, String>{
      'reference, employer, then the salary word':
          'Update! INR 45,000.00 deposited in Example Bank A/c XX1234 on 30-OCT-26 for A2AINT01-ACME TECHNOLOGIES PVT LTD-Salary-Salary Oct 2026.Avl bal INR 1,38,743.58.',
      'rail words before the employer': '$pre by ACH CR-ACME TECHNOLOGIES-SALARY. Avl Bal Rs 120000.00',
      'upi narration': '$pre by UPI/CR/123456789012/ACME TECHNOLOGIES/SALARY. Avl Bal Rs 120000.00',
      'salary word first': '$pre. SALARY CREDIT ACME TECHNOLOGIES. Avl Bal Rs 120000.00',
      'salary for a month, from': '$pre - Salary for Oct 2026 from ACME TECHNOLOGIES. Avl Bal Rs 120000.00',
      'employer then salary': '$pre ACME TECHNOLOGIES SALARY. Avl Bal Rs 120000.00',
      'shouting': 'RS 85000.00 CREDITED TO A/C XX1234 ON 01-11-26 BY UPI/CR/123456789012/ACME TECHNOLOGIES/SALARY.',
      'line breaks': 'Rs 85000.00 credited to A/c XX1234\non 01-11-26\nby ACH CR-ACME TECHNOLOGIES-SALARY\nAvl Bal Rs 120000.00',
      'rupee sign, extra spaces': '₹85,000.00   credited  to  A/c   XX1234  on 01-11-26   by ACH CR-ACME TECHNOLOGIES-SALARY.',
    };
    layouts.forEach((name, body) {
      test(name, () => expect(employer(body)?.toUpperCase(), startsWith('ACME TECHNOLOGIES')));
    });
  });

  group('no employer is better than a wrong one', () {
    test('no name in the alert', () {
      expect(employer('$pre. SALARY. Avl Bal Rs 120000.00'), isNull);
      expect(employer('$pre by Salary. Available Bal is Rs 223456.50.'), isNull);
    });
    test('the bank beside the account number is not the employer', () {
      expect(employer('Rs 85000.00 credited to Example Bank A/c XX1234 on 01-11-26. SALARY. Avl Bal Rs 1000'), isNull);
      expect(employer('Example Bank: Rs 85000.00 credited to A/c XX1234 on 01-11-26 SALARY'), isNull);
    });
    test('a greeting is not the employer', () {
      expect(employer('Dear Customer, your salary Rs 85000.00 is credited to A/c XX1234 on 01-11-26.'), isNull);
    });
    test('a name in another sentence is not the employer', () {
      expect(employer('$pre as SALARY. Thank you for banking with Example Cooperative Society.'), isNull);
    });
    test('a name that carries on across a bracket is a fragment, so it is dropped', () {
      expect(employer('$pre by ACH CR-ACME (INDIA) PVT LTD-SALARY. Avl Bal Rs 120000.00'), isNull);
    });
    test('a very long run is prose, not a name', () {
      expect(employer('$pre by ACH CR-${'ACME ' * 20}TECHNOLOGIES-SALARY.'), isNull);
    });
    test('a month and a year are the salary period, not an employer', () {
      expect(employer('Your A/C XXXXX123456 has credit for SALARY OCT 2026 of Rs 85,000.00 on 01/11/26.'), isNull);
    });
  });

  group('money handed back is not a month of pay', () {
    test('reversed, refunded, returned beside the salary word', () {
      for (final w in ['REVERSAL', 'REVERSED', 'REFUNDED', 'RETURNED']) {
        expect(solver.salaryNote('$pre by NEFT-ACME TECHNOLOGIES-SALARY $w.').givenBack, isTrue, reason: w);
      }
    });
    test('an ordinary salary is not', () {
      expect(solver.salaryNote('$pre by NEFT-ACME TECHNOLOGIES-SALARY NOV.').givenBack, isFalse);
    });
    test('a reversal in some other sentence is not', () {
      expect(
        solver.salaryNote('$pre by NEFT-ACME TECHNOLOGIES-SALARY NOV. A fee reversal was posted separately on your card.').givenBack,
        isFalse,
      );
    });
  });

  group('the solver itself reports the employer on a salary credit it reads', () {
    final observed = DateTime.utc(2026, 11, 1);
    test('a layout with no cue word', () {
      final d = solver.solve('$pre. SALARY CREDIT ACME TECHNOLOGIES. Avl Bal Rs 120000.00', observedAt: observed);
      expect(d.purpose, 'salary');
      expect(d.party, 'ACME TECHNOLOGIES');
    });
    test('a messy cue-word party is replaced by the cleaner name', () {
      final d = solver.solve('$pre by ACH CR-ACME TECHNOLOGIES-SALARY. Avl Bal Rs 120000.00', observedAt: observed);
      expect(d.party, 'ACME TECHNOLOGIES');
    });
    test('a debit never gets an employer', () {
      final d = solver.solve('Rs 5000.00 debited from A/c XX1234 on 01-11-26 NEFT/ACME TECHNOLOGIES/SALARY ADVANCE.', observedAt: observed);
      // The word "salary" can tag a debit's raw purpose, but the employer step
      // only runs on credits, and the fact builder drops a salary purpose on a
      // debit.
      expect(d.debitDirection, isTrue);
      expect(d.party, isNot('ACME TECHNOLOGIES'));
    });
  });
}
