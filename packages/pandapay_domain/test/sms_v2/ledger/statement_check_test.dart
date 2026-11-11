// E2: can the rows of a parsed bank statement be believed? Every statement here
// is invented: amounts, dates and names mean nothing.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

DateTime d(String ymd) => DateTime.parse('${ymd}T00:00:00Z');

StatementRow row(int i, String date, int amount, {Direction? dir, int? bal}) =>
    StatementRow(index: i, date: d(date), amountMinor: amount, direction: dir, balanceMinor: bal);

const dr = Direction.debit, cr = Direction.credit;

/// Opening 1,000.00. +500.00, -200.00, -30.50, +1.00.
List<StatementRow> clean({bool withDirections = true}) => [
  row(0, '2026-03-02', 50000, dir: withDirections ? cr : null, bal: 150000),
  row(1, '2026-03-03', 20000, dir: withDirections ? dr : null, bal: 130000),
  row(2, '2026-03-03', 3050, dir: withDirections ? dr : null, bal: 126950),
  row(3, '2026-03-05', 100, dir: withDirections ? cr : null, bal: 127050),
];

void main() {
  test('a statement whose balance, totals and counts all agree is trusted', () {
    final check = verifyStatement(
      clean(),
      openingMinor: 100000,
      closingMinor: 127050,
      printedDebitMinor: 23050,
      printedCreditMinor: 50100,
      printedDebitCount: 2,
      printedCreditCount: 2,
    );
    expect(check.problems, isEmpty);
    expect(check.trusted, isTrue);
    expect(check.chainBreaks, isEmpty);
    expect(check.openingMatches, isTrue);
    expect(check.closingMatches, isTrue);
  });

  test('a layout with no debit/credit column has its directions read from the balance', () {
    final check = verifyStatement(clean(withDirections: false), openingMinor: 100000, closingMinor: 127050);
    expect(check.trusted, isTrue, reason: check.problems.toString());
    expect([for (final r in check.rows) r.direction], [cr, dr, dr, cr]);
  });

  test('one misread amount marks that row and no other', () {
    final rows = clean();
    rows[2] = row(2, '2026-03-03', 3500, dir: dr, bal: 126950); // 30.50 read as 35.00
    final check = verifyStatement(rows, openingMinor: 100000, closingMinor: 127050);
    expect(check.chainBreaks, [2]);
    expect(check.suspectRows, {2});
    expect(check.trusted, isFalse);
  });

  test('a dropped row marks the row after the gap, and the totals say so too', () {
    final rows = [...clean()]..removeAt(1); // the 200.00 debit is missing
    final check = verifyStatement(
      rows,
      openingMinor: 100000,
      closingMinor: 127050,
      printedDebitMinor: 23050,
      printedCreditMinor: 50100,
    );
    expect(check.chainBreaks, [2]);
    expect(check.debitTotalMatches, isFalse);
    expect(check.closingMatches, isTrue); // the closing balance alone would not have caught it
    expect(check.trusted, isFalse);
  });

  test('a statement printed newest first is turned around', () {
    final check = verifyStatement(clean().reversed.toList(), openingMinor: 100000, closingMinor: 127050);
    expect(check.reversed, isTrue);
    expect(check.trusted, isTrue, reason: check.problems.toString());
    expect(check.rows.first.index, 0); // the oldest row keeps its own index
  });

  test('without an opening balance the first row is not checked but the rest are', () {
    final check = verifyStatement(clean(), closingMinor: 127050);
    expect(check.chainBreaks, isEmpty);
    expect(check.trusted, isTrue, reason: check.problems.toString());
    final bad = clean()..[3] = row(3, '2026-03-05', 150, dir: cr, bal: 127050);
    expect(verifyStatement(bad, closingMinor: 127050).chainBreaks, [3]);
  });

  test('a first row with no direction and no opening balance cannot be settled', () {
    final check = verifyStatement(clean(withDirections: false), closingMinor: 127050);
    expect(check.directionUnknown, [0]);
    expect(check.trusted, isFalse);
  });

  test('a statement that prints nothing to check against is never trusted', () {
    final check = verifyStatement([row(0, '2026-03-02', 50000, dir: cr), row(1, '2026-03-03', 100, dir: dr)]);
    expect(check.verifiedSomething, isFalse);
    expect(check.trusted, isFalse);
  });

  test('printed totals alone can vouch for a statement with no balance column', () {
    final check = verifyStatement(
      [row(0, '2026-03-02', 50000, dir: cr), row(1, '2026-03-03', 100, dir: dr)],
      printedCreditMinor: 50000,
      printedDebitMinor: 100,
    );
    expect(check.trusted, isTrue, reason: check.problems.toString());
  });

  test('a wrong closing balance or a wrong count is reported', () {
    expect(verifyStatement(clean(), openingMinor: 100000, closingMinor: 127000).closingMatches, isFalse);
    expect(verifyStatement(clean(), openingMinor: 100000, printedDebitCount: 3).debitCountMatches, isFalse);
    expect(verifyStatement(clean(), openingMinor: 99999).openingMatches, isFalse);
  });

  test('an empty statement has nothing to trust', () {
    final check = verifyStatement(const []);
    expect(check.trusted, isFalse);
    expect(check.problems, isNotEmpty);
  });
}
