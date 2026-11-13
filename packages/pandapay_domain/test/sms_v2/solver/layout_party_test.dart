import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2_solver.dart';
import 'package:test/test.dart';

/// The solver reads a payee from the layout of a card alert (no cue word), and
/// never reports a name from a footer sentence as the payee.
const _packPath = '../../rules/sms/solver/pack.json';
final _observed = DateTime.utc(2026, 11, 9, 6);

EvidenceSolver _solver() => EvidenceSolver(
  SolverPack.fromJson(
    jsonDecode(File(_packPath).readAsStringSync()) as Map<String, dynamic>,
  ),
);

SolverDecision _solve(String body) =>
    _solver().solve(body, observedAt: _observed);

void main() {
  group('a merchant printed by layout', () {
    test('after the clock and a zone label, up to the limit wording', () {
      final d = _solve(
        'Spent INR 500 Card no. XX1234 01-10-26 10:15:30 IST SOME SHOP Avl Limit: INR 80000 Not you? SMS BLOCK 1234 to 919900000000',
      );
      expect(d.accepted, isTrue);
      expect(d.party, 'SOME SHOP');
    });

    test('a name that carries a bill word is kept whole', () {
      final d = _solve(
        'Spent INR 48 Card no. XX1234 03-10-26 09:05:10 IST CITY Bill Pay Avl Limit: INR 79500 Not you? SMS BLOCK 1234 to 919900000000',
      );
      expect(d.party, 'CITY Bill Pay');
    });

    test('a credit never takes a layout name', () {
      final d = _solve(
        'Received INR 500 Card no. XX1234 01-10-26 10:15:30 IST SOME SHOP Avl Limit: INR 80000',
      );
      expect(d.party, isNull);
    });
  });

  group('a footer sentence is not a payee', () {
    test('"To report misuse call ..." is not reported as the payee', () {
      final d = _solve(
        'Thank you for availing credit of Rs799 using Pay Later. For detailed info click https://example.com/x To report misuse call 1800000000',
      );
      expect(d.party, isNull);
    });

    test('a payee named in the sentence BEFORE the amount is kept', () {
      final d = _solve(
        'Your subscription to SOME SERVICE has been renewed. Rs 119.00 charged to your card ending 4410 on 02-Aug-26.',
      );
      expect(d.party, 'SOME SERVICE');
    });

    test('a payee in the amount sentence is still reported', () {
      final d = _solve(
        'Rs 500.00 debited from A/c XX1234 on 01-11-26 towards SOME SHOP. Not you? Call 1800 to report fraud.',
      );
      expect(d.party, 'SOME SHOP');
    });

    test('the footer name still counts as evidence: acceptance is unchanged', () {
      // Accepted before the guard because a name was found; it must stay so.
      final d = _solve(
        'Thank you for availing credit of Rs799 using Pay Later. For detailed info click https://example.com/x To report misuse call 1800000000',
      );
      expect(d.accepted, isTrue);
    });
  });

  group('a clock is a layout cue only with a time-zone label', () {
    test('"12:30 PM" and "12:30 hrs" never become a payee', () {
      for (final body in [
        'Rs 200.00 debited from A/c XX1234 on 01-11-26 12:30 PM. Avl Bal Rs 500.00',
        'Rs 200.00 debited from A/c XX1234 on 01-11-26 12:30 hrs Info: UPI txn',
        'Rs 200.00 spent on card XX1234 01-11-26 12:30:45 SOME SHOP Avl Limit Rs 5000',
      ]) {
        expect(_solve(body).party, isNull, reason: body);
      }
    });

    test('a merchant of three or four capital letters keeps its first word', () {
      final d = _solve(
        'Rs 200.00 spent on card XX1234 01-11-26 12:30:45 IST SOME SHOP Avl Limit Rs 5000',
      );
      expect(d.party, 'SOME SHOP');
    });

    test('the layout name never makes a thin message acceptable', () {
      // No account, no cue-named payee, no rail: it stays a candidate for review.
      final d = _solve(
        'Rs 200.00 debited on 01-11-26 12:30:45 IST SOME SHOP Thank you for banking with us',
      );
      expect(d.verdict, SolverVerdict.candidate);
    });
  });
}
