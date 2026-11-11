// E2: which statement rows does an SMS already explain, and which are the two
// legs of a transfer between the person's own accounts? Every statement, SMS and
// name here is invented.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import '../linker/helpers.dart' as h;

DateTime d(String ymd) => DateTime.parse('${ymd}T00:00:00Z');
DateTime at(String iso) => DateTime.parse(iso);

const dr = Direction.debit, cr = Direction.credit;

StatementRow row(
  int i,
  String date,
  int amount,
  Direction dir, {
  String narration = '',
  String? mask,
  String? issuer,
  String account = 'A',
}) => StatementRow(
  index: i,
  date: d(date),
  amountMinor: amount,
  direction: dir,
  narration: narration,
  accountMask: mask,
  issuerSlug: issuer,
  accountId: account,
);

StatementCandidate cand(
  String id,
  String when,
  int amount,
  Direction dir, {
  Set<String> refs = const {},
  String? mask,
  String? issuer,
  int? primary,
}) => StatementCandidate(
  id: id,
  at: at(when),
  amountsMinor: [amount],
  primaryAmountMinor: primary ?? amount,
  direction: dir,
  references: refs,
  accountMask: mask,
  issuerSlug: issuer,
);

SmsMatch only(SmsReconciliation r) => r.matches.single;

void main() {
  group('amounts in SMS text', () {
    test('a decimal, or a number after a currency or movement word, counts', () {
      expect(movementAmountsInText('Rs.12345.00 debited from A/c XX1234 on 05-Jan-26'), [1234500]);
      expect(movementAmountsInText('Rs 5,000 credited to your account'), [500000]);
      expect(movementAmountsInText('INR 500 sent to Ravi'), [50000]);
      expect(movementAmountsInText('An amount of INR 206.2 received on your card'), [20620]);
      expect(movementAmountsInText('payment of Rs 1,00,000.50 received'), [10000050]);
    });

    test('a date, a reference, a phone number or a balance is not an amount', () {
      expect(movementAmountsInText('Due on 15 Jan, call 1800123456'), isEmpty);
      expect(movementAmountsInText('Info: UPI/DR/123456789012/Shop'), isEmpty);
      expect(movementAmountsInText('Rs 500 debited. Avl Bal Rs 22,000.00'), [50000]);
      expect(movementAmountsInText('Total of Rs 50,625.32 or minimum of Rs 2,540.00 is due'), isEmpty);
      expect(movementAmountsInText('Credit limit INR 3,00,000.00'), isEmpty);
    });
  });

  test('a direction is read only when the text states one', () {
    expect(directionInText('Rs 5 debited from your account'), Direction.debit);
    expect(directionInText('Rs 5 credited to your account'), Direction.credit);
    expect(directionInText('Payment of Rs 5 received for your card'), isNull); // both words
    expect(directionInText('Your statement is ready'), isNull);
  });

  group('references', () {
    test('long digit runs and mixed UTRs count; an IFSC code and short numbers do not', () {
      expect(extractReferences('UPI/DR/116581668664/Shop Name/YESB/paytm-8057/UPI'), {'116581668664'});
      expect(extractReferences('NEFT*ABCD0123456*SBIN526123456789*Sample Ltd'), {'SBIN526123456789'});
      expect(extractReferences('ATD/Auto Debit CC0xx1724 SAMPLE CO'), isEmpty);
    });
  });

  group('amount, direction, account and day', () {
    test('the same amount on the same day is explained', () {
      final r = reconcileWithSms(
        [row(0, '2026-03-05', 500000, cr)],
        [cand('s1', '2026-03-05T04:00:00Z', 500000, cr)],
      );
      expect(only(r).hasSms, isTrue);
      expect(only(r).basis, MatchBasis.amountDate);
      expect(only(r).dayOffset, 0);
    });

    test('the day is the Indian day: a late-evening UTC message belongs to the next day', () {
      final r = reconcileWithSms(
        [row(0, '2026-03-05', 500000, cr)],
        [cand('s1', '2026-03-04T19:00:00Z', 500000, cr)], // 00:30 IST on the 5th
      );
      expect(only(r).dayOffset, 0);
    });

    test('two days either way match; three do not', () {
      for (final (gap, matched) in [(2, true), (-2, true), (3, false), (-3, false)]) {
        final day = DateTime.utc(2026, 3, 10 - gap, 6);
        final r = reconcileWithSms(
          [row(0, '2026-03-10', 12345, dr)],
          [cand('s1', day.toIso8601String(), 12345, dr)],
        );
        expect(only(r).hasSms, matched, reason: 'gap $gap');
      }
    });

    test('the other direction, or another amount, is not an explanation', () {
      final r = reconcileWithSms(
        [row(0, '2026-03-05', 500000, cr)],
        [cand('s1', '2026-03-05T04:00:00Z', 500000, dr), cand('s2', '2026-03-05T04:00:00Z', 500001, cr)],
      );
      expect(only(r).hasSms, isFalse);
      expect(r.unmatchedCandidates, hasLength(2));
    });

    test('one SMS explains one row', () {
      final r = reconcileWithSms(
        [row(0, '2026-03-05', 20000, dr), row(1, '2026-03-05', 20000, dr)],
        [cand('s1', '2026-03-05T04:00:00Z', 20000, dr)],
      );
      expect(r.matches.where((m) => m.hasSms), hasLength(1));
      expect(r.summary.withoutSms, 1);
    });

    test('the closest pairs go first, so one row never takes the SMS another needs', () {
      // Row 0 (5th) can use either SMS, two days from each. Row 1 (2nd) can use
      // only the SMS of the 3rd. Taking rows in order gives row 0 the SMS of the
      // 3rd, because it is the earlier of the two, and leaves row 1 with nothing.
      // Closest first gives row 1 that SMS (one day) and row 0 the other.
      final r = reconcileWithSms(
        [row(0, '2026-03-05', 7777, dr), row(1, '2026-03-02', 7777, dr)],
        [cand('early', '2026-03-03T06:00:00Z', 7777, dr), cand('late', '2026-03-07T06:00:00Z', 7777, dr)],
      );
      expect(r.matches.map((m) => m.hasSms), [true, true]);
      expect(r.matches[1].candidate!.id, 'early');
      expect(r.matches[0].candidate!.id, 'late');
    });

    test('an SMS from another account is not an explanation', () {
      final other = reconcileWithSms(
        [row(0, '2026-03-05', 5000, dr, mask: '8648', issuer: 'alphabank')],
        [cand('s1', '2026-03-05T04:00:00Z', 5000, dr, mask: '4911', issuer: 'betabank')],
      );
      expect(only(other).hasSms, isFalse);
      final sameIssuerOtherNumber = reconcileWithSms(
        [row(0, '2026-03-05', 5000, dr, mask: '8648', issuer: 'alphabank')],
        [cand('s1', '2026-03-05T04:00:00Z', 5000, dr, mask: '1111', issuer: 'alphabank')],
      );
      expect(only(sameIssuerOtherNumber).hasSms, isFalse);
    });

    test('a short ending and the full number are the same account; an unknown account fits any', () {
      final shortEnding = reconcileWithSms(
        [row(0, '2026-03-05', 5000, dr, mask: '4911')],
        [cand('s1', '2026-03-05T04:00:00Z', 5000, dr, mask: '911')],
      );
      expect(only(shortEnding).hasSms, isTrue);
      final unknown = reconcileWithSms(
        [row(0, '2026-03-05', 5000, dr, mask: '4911')],
        [cand('s1', '2026-03-05T04:00:00Z', 5000, dr)],
      );
      expect(only(unknown).hasSms, isTrue);
    });
  });

  group('a shared reference', () {
    test('links a row to an SMS days away, and an amount disagreement is flagged', () {
      final r = reconcileWithSms(
        [row(0, '2026-03-10', 25000, dr, narration: 'UPI/DR/116581668664/Shop/YESB/x/UPI')],
        [cand('s1', '2026-03-06T06:00:00Z', 25000, dr, refs: {'116581668664'})],
      );
      expect(only(r).basis, MatchBasis.reference);
      expect(only(r).amountConflict, isFalse);

      final disagree = reconcileWithSms(
        [row(0, '2026-03-10', 25000, dr, narration: 'UPI/DR/116581668664/Shop/YESB/x/UPI')],
        [cand('s1', '2026-03-09T06:00:00Z', 24900, dr, refs: {'116581668664'})],
      );
      expect(only(disagree).hasSms, isTrue);
      expect(only(disagree).amountConflict, isTrue);
      expect(disagree.summary.amountConflicts, 1);
    });

    test('a reference never links the other direction or another account', () {
      final opposite = reconcileWithSms(
        [row(0, '2026-03-10', 25000, dr, narration: 'UPI/DR/116581668664/Shop')],
        [cand('s1', '2026-03-10T06:00:00Z', 25000, cr, refs: {'116581668664'})],
      );
      expect(only(opposite).hasSms, isFalse);
    });

    test('a reference match takes priority over an amount match for another row', () {
      final r = reconcileWithSms(
        [
          row(0, '2026-03-10', 9000, dr, narration: 'UPI/DR/111111111111/A'),
          row(1, '2026-03-10', 9000, dr, narration: 'UPI/DR/222222222222/B'),
        ],
        [
          cand('s1', '2026-03-10T06:00:00Z', 9000, dr, refs: {'222222222222'}),
          cand('s2', '2026-03-10T07:00:00Z', 9000, dr, refs: {'111111111111'}),
        ],
      );
      expect(r.matches[0].candidate!.id, 's2');
      expect(r.matches[1].candidate!.id, 's1');
    });
  });

  group('transfers between the person\'s own accounts', () {
    test('a debit in one statement and a credit in another are one transfer', () {
      final r = reconcileWithSms(
        [
          row(0, '2026-03-05', 6900000, dr, account: 'A'),
          row(1, '2026-03-05', 6900000, cr, account: 'B'),
          row(2, '2026-03-06', 1500, dr, account: 'A'),
        ],
        const [],
      );
      expect(r.ownTransfers, hasLength(1));
      expect(r.matches[0].ownTransfer, same(r.matches[1].ownTransfer));
      expect(r.matches[2].ownTransfer, isNull);
      // The transfer is not money added to the person's picture; the plain debit is.
      expect(r.summary.ownTransferRows, 2);
      expect(r.summary.addedInMinor, 0);
      expect(r.summary.addedOutMinor, 1500);
    });

    test('rows of one statement never pair with each other', () {
      final r = reconcileWithSms(
        [row(0, '2026-03-05', 5000, dr), row(1, '2026-03-05', 5000, cr)],
        const [],
      );
      expect(r.ownTransfers, isEmpty);
    });

    test('several possible partners are not guessed between, unless a narration names the owner', () {
      final rows = [
        row(0, '2026-03-05', 1000000, dr, account: 'A'),
        row(1, '2026-03-05', 1000000, dr, account: 'A', narration: 'NEFT TO ASHA KULKARNI'),
        row(2, '2026-03-05', 1000000, cr, account: 'B'),
      ];
      final unnamed = reconcileWithSms(rows, const []);
      expect(unnamed.ownTransfers, isEmpty);
      expect(unnamed.ambiguousTransferRows.toSet(), {0, 1, 2});

      final named = reconcileWithSms(rows, const [], ownerNames: ['Asha Rao Kulkarni']);
      expect(named.ownTransfers, hasLength(1));
      expect(named.ownTransfers.single.named, isTrue);
      expect(named.ownTransfers.single.debit.index, 1);
    });

    test('a transfer two days apart is two separate movements', () {
      final r = reconcileWithSms(
        [row(0, '2026-03-05', 5000, dr, account: 'A'), row(1, '2026-03-07', 5000, cr, account: 'B')],
        const [],
      );
      expect(r.ownTransfers, isEmpty);
    });
  });

  test('the summary counts what an import would add', () {
    final r = reconcileWithSms(
      [
        row(0, '2026-03-01', 120000, cr), // no SMS: salary-like credit
        row(1, '2026-03-02', 30050, dr), // no SMS
        row(2, '2026-03-03', 5000, dr), // has an SMS
      ],
      [
        cand('s1', '2026-03-03T05:00:00Z', 5000, dr),
        cand('s2', '2026-03-20T05:00:00Z', 777, dr), // an SMS no row explains
      ],
    );
    expect(r.summary.rows, 3);
    expect(r.summary.withSms, 1);
    expect(r.summary.withoutSms, 2);
    expect(r.summary.addedInMinor, 120000);
    expect(r.summary.addedOutMinor, 30050);
    expect(r.unmatchedCandidates.map((c) => c.id), ['s2']);
  });

  test('an SMS the phone could not parse can still explain a row, by its amount', () {
    final r = reconcileWithSms(
      [row(0, '2026-03-05', 1234500, dr)],
      [
        StatementCandidate.fromText(id: 't1', at: at('2026-03-05T05:00:00Z'), body: 'Rs.12345.00 debited from A/c XX1234 on 05-Mar-26'),
        StatementCandidate.fromText(id: 't2', at: at('2026-03-05T05:00:00Z'), body: 'Avl Bal Rs 12,345.00 as on 05-Mar'),
      ],
    );
    expect(only(r).candidate!.id, 't1');
    expect(r.unmatchedCandidates.map((c) => c.id), ['t2']);
  });

  group('candidates from parsed facts', () {
    test('a movement on a bank account becomes a candidate with its account and references', () {
      final fact = h.move(
        'debit',
        'purchase',
        50000,
        at: '2026-03-05T06:00:00Z',
        inst: h.hdfcAcct,
        references: {'upiRef': '116581668664'},
      );
      final c = StatementCandidate.fromFact(fact, instrumentsById: h.allInstruments)!;
      expect(c.amountsMinor, [50000]);
      expect(c.direction, Direction.debit);
      expect(c.accountMask, '1234');
      expect(c.issuerSlug, 'hdfc');
      expect(c.references, {'116581668664'});
    });

    test('a card spend, a receipt, a wallet or a foreign amount is not on a bank statement', () {
      expect(
        StatementCandidate.fromFact(h.move('debit', 'purchase', 50000, at: '2026-03-05T06:00:00Z', inst: h.hdfcCard), instrumentsById: h.allInstruments),
        isNull,
      );
      expect(
        StatementCandidate.fromFact(h.move('debit', 'purchase', 50000, at: '2026-03-05T06:00:00Z', inst: h.hdfcAcct, evidenceOnly: true), instrumentsById: h.allInstruments),
        isNull,
      );
      expect(
        StatementCandidate.fromFact(h.move('debit', 'purchase', 50000, at: '2026-03-05T06:00:00Z', inst: h.paytmWallet), instrumentsById: h.allInstruments),
        isNull,
      );
      expect(
        StatementCandidate.fromFact(h.move('debit', 'purchase', 2000, at: '2026-03-05T06:00:00Z', inst: h.hdfcAcct, unit: 'USD'), instrumentsById: h.allInstruments),
        isNull,
      );
    });
  });

  test('a thousand statement rows against twenty thousand messages is fast', () {
    var seed = 7;
    int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    final candidates = [
      for (var i = 0; i < 20000; i++)
        cand('c$i', DateTime.utc(2026, 1, 1).add(Duration(hours: next() % (24 * 330))).toIso8601String(), 100 + next() % 400000, next() % 2 == 0 ? dr : cr),
    ];
    final rows = [
      for (var i = 0; i < 1000; i++)
        row(i, DateTime.utc(2026, 1, 1).add(Duration(days: next() % 330)).toIso8601String().substring(0, 10), 100 + next() % 400000, next() % 2 == 0 ? dr : cr),
    ];
    final watch = Stopwatch()..start();
    final r = reconcileWithSms(rows, candidates);
    watch.stop();
    expect(r.matches, hasLength(1000));
    expect(watch.elapsedMilliseconds, lessThan(3000));
  });
}
