import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2_solver.dart';
import 'package:test/test.dart';

const _packPath = '../../rules/sms/solver/pack.json';

/// (path, least number of counted movements it must get right)
const _corpora = [
  ('../../tools/sms_golden/solver/held_out.jsonl', 10),
  ('../../tools/sms_golden/solver/blind_1.jsonl', 10),
  ('../../tools/sms_golden/solver/blind_2.jsonl', 10),
  ('../../tools/sms_golden/solver/bills_subs_dev.jsonl', 1),
  ('../../tools/sms_golden/solver/non_financial.jsonl', 0),
];

SolverPack _pack() => SolverPack.fromJson(
  jsonDecode(File(_packPath).readAsStringSync()) as Map<String, dynamic>,
);

Map<String, dynamic> _packJson() =>
    jsonDecode(File(_packPath).readAsStringSync()) as Map<String, dynamic>;

void main() {
  group('text layer', () {
    test('finds amounts, masks, dates and VPAs as typed tokens', () {
      final t = SolverText.parse(
        'Rs.1,250.00 debited from A/c XX4521 on 03-11-26 to rahul.s@exampleupi',
      ).toks;
      expect(t.where((x) => x.kind == TokKind.amt).single.minor, 125000);
      expect(t.where((x) => x.kind == TokKind.mask).single.digits, '4521');
      expect(t.where((x) => x.kind == TokKind.date), hasLength(1));
      expect(t.where((x) => x.kind == TokKind.vpa), hasLength(1));
    });

    test('reads Indian digit grouping, foreign currency and paise', () {
      final t = SolverText.parse(
        'INR 2,50,000 then USD 12.99 then Rs 5000/- then Rs.0.5',
      ).toks;
      final a = t.where((x) => x.kind == TokKind.amt).toList();
      expect(a.map((x) => x.minor), [25000000, 1299, 500000, 50]);
      expect(a.map((x) => x.unit), ['INR', 'USD', 'INR', 'INR']);
    });

    test('an account number after "a/c" becomes a mask', () {
      final t = SolverText.parse('credited to A/c no. 1234567890 today').toks;
      expect(t.where((x) => x.kind == TokKind.mask).single.digits, '7890');
    });

    test('an abbreviation dot is not a sentence boundary', () {
      final t = SolverText.parse('Avl. Bal Rs 100. Thank you').toks;
      final avl = t.firstWhere((x) => x.lower == 'avl');
      final bal = t.firstWhere((x) => x.lower == 'bal');
      final thank = t.firstWhere((x) => x.lower == 'thank');
      expect(avl.sentence, bal.sentence);
      expect(thank.sentence, isNot(bal.sentence));
    });
  });

  group('phrases', () {
    final toks = SolverText.parse(
      'Rs 500 has been debited from your account XX1234 on 05-11-26',
    ).toks;

    test('alternatives, optional slots and typed placeholders', () {
      expect(
        Phrase.parse('has been debited|credited').findAll(toks),
        hasLength(1),
      );
      expect(
        Phrase.parse('from your? account <mask>').findAll(toks),
        hasLength(1),
      );
      expect(Phrase.parse('from account <mask>').findAll(toks), isEmpty);
    });

    test('* skips at most three tokens', () {
      expect(Phrase.parse('rs|<amt> * debited').findAll(toks), isNotEmpty);
      expect(Phrase.parse('has * xx').findAll(toks), isEmpty);
    });

    test('a phrase must anchor on a real token at both ends', () {
      expect(() => Phrase.parse('* debited'), throwsFormatException);
      expect(() => Phrase.parse('debited *'), throwsFormatException);
      expect(() => Phrase.parse('?'), throwsFormatException);
    });
  });

  group('pack validation', () {
    test('the shipped pack loads', () {
      expect(_pack().version, greaterThan(0));
    });

    test('a missing lexicon is refused', () {
      final j = _packJson();
      (j['lexicons'] as Map).remove('debit');
      expect(() => SolverPack.fromJson(j), throwsFormatException);
    });

    test('an unknown lexicon is refused', () {
      final j = _packJson();
      (j['lexicons'] as Map)['mystery'] = ['x'];
      expect(() => SolverPack.fromJson(j), throwsFormatException);
    });

    test('a wrong schema id is refused', () {
      final j = _packJson()..['schema'] = 'other/1';
      expect(() => SolverPack.fromJson(j), throwsFormatException);
    });
  });

  group('safety properties (generic wording, no bank names)', () {
    final solver = EvidenceSolver(_pack());

    void notCounted(String body) {
      final d = solver.solve(body);
      expect(d.countsInTotals, isFalse, reason: '$body -> $d');
    }

    test('future or conditional debits are not spends', () {
      notCounted('Rs 1,000 will be debited from your A/c XX4521 on 10-Nov.');
      notCounted('Your a/c XX4521 shall be debited Rs 400 if you do not pay.');
    });

    test('failed and declined attempts are not spends', () {
      notCounted(
        'Your UPI payment of Rs 500 to Kiran failed. Amount not debited.',
      );
      notCounted('Transaction of Rs 900 on card ending 4410 was declined.');
    });

    test('offers that quote amounts are not money', () {
      notCounted(
        'Get flat Rs 200 cashback on your first transaction. Use code NEW.',
      );
      notCounted('You have won Rs 50,000 in our lucky draw! Claim now.');
    });

    test('balances and limits are never the paid amount', () {
      final d = solver.solve(
        'Rs 90 spent on Card XX9921 at SHOP. Avl Lmt INR 87,000.00',
      );
      expect(d.minor, 9000);
      expect(d.read, SolverRead.debit);
    });

    test('a card bill payment is not a purchase', () {
      final d = solver.solve(
        'We have received Rs 8,420.00 on 10-Nov-26 towards your card XX1188 bill.',
      );
      expect(d.countsInTotals, isFalse);
    });

    test('a move between two of the user\'s own accounts is not a spend', () {
      final d = solver.solve(
        'Rs 5,000 transferred from your A/c XX1111 to your savings A/c XX2222.',
      );
      expect(d.read, SolverRead.ownTransfer);
      expect(d.countsInTotals, isFalse);
    });

    test(
      'a debit with a competing credit word at the same distance goes to review',
      () {
        final d = solver.solve('Rs 100 debited credited Rs 100 A/c XX1111');
        expect(d.accepted && d.countsInTotals, isFalse);
      },
    );

    test('foreign currency without a printed INR amount is never guessed', () {
      final d = solver.solve(
        'USD 12.99 spent on your card ending 4412 at SHOP',
      );
      expect(d.countsInTotals, isFalse);
    });

    test('foreign currency with a printed INR amount counts the INR amount', () {
      final d = solver.solve(
        'USD 12.99 spent on your card ending 4412 at SHOP on 05-Nov-2026 (Rs. 1,082.12).',
      );
      expect(d.minor, 108212);
      expect(d.originalMinor, 1299);
      expect(d.originalUnit, 'USD');
    });

    test('an amount with no cue we know is never dropped silently', () {
      final d = solver.solve('Quantum flux of Rs 4,321 noted on A/c XX1111');
      expect(d.accepted, isFalse);
      expect(d.read, SolverRead.unclear);
    });

    test(
      'a completed cue with no instrument, payee or channel is only a candidate',
      () {
        final d = solver.solve('Rs 300 debited.');
        expect(d.accepted, isFalse);
      },
    );

    test('a security message is never review material', () {
      final d = solver.solve(
        'Your OTP for the Rs 4,500 payment is 123456. Do not share it.',
      );
      expect(d.countsInTotals, isFalse);
    });
  });

  group('hostile input', () {
    final solver = EvidenceSolver(_pack());

    test('empty and junk messages return a decision without throwing', () {
      for (final body in [
        '',
        ' ',
        '\n\n',
        '₹',
        'Rs',
        'Rs.',
        '@@@',
        '....',
        'A/c',
        '9' * 40,
      ]) {
        expect(() => solver.solve(body), returnsNormally, reason: body);
      }
    });

    test('very long messages finish quickly (read is capped)', () {
      final sw = Stopwatch()..start();
      solver.solve('a' * 200000);
      solver.solve('Rs 1 ' * 40000);
      solver.solve('a.' * 100000);
      solver.solve('x@' * 100000);
      solver.solve(('debited ' * 50000));
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('the same input always gives the same decision', () {
      const body =
          'Rs 1,250.00 debited from A/c XX4521 on 03-11-26 to rahul@upi';
      expect(solver.solve(body).toString(), solver.solve(body).toString());
    });
  });

  group('labelled corpora', () {
    final solver = EvidenceSolver(_pack());

    for (final (path, minRight) in _corpora) {
      test('$path: no false counts and no silent misses', () {
        final rows = File(path)
            .readAsLinesSync()
            .where((l) => l.trim().isNotEmpty)
            .map((l) => jsonDecode(l) as Map<String, dynamic>);
        final bad = <String>[];
        var right = 0;
        for (final row in rows) {
          final expect_ = row['expect'] as Map<String, dynamic>;
          final d = solver.solve(row['body'] as String);
          if (d.countsInTotals) {
            final okDir = d.read.name == expect_['read'];
            if (expect_['counts'] != true ||
                !okDir ||
                d.minor != expect_['amount']) {
              bad.add('FALSE COUNT ${row['id']}: ${row['body']} -> $d');
            } else {
              right++;
            }
          }
        }
        expect(bad, isEmpty, reason: bad.join('\n'));
        expect(right, greaterThanOrEqualTo(minRight));
      });
    }
  });
}
