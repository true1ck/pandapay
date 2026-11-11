// E1: reading an SBI-style and an ICICI-style statement into rows, and proving
// the rows. Every statement here is invented: names, numbers and amounts mean
// nothing. The layouts (columns, dates, dashes for empty, no direction column)
// follow the real ones.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:pandapay_domain/statement_layouts.dart';
import 'package:test/test.dart';

const sbi = '''
Account Name : SAMPLE PERSON
Account Number : 00000012345678648
Statement Period 01/01/2026 to 08/01/2026
Date Value Date Description Ref No./Cheque No. Debit Credit Balance
05/01/2026   05/01/2026   UPI/DR/116581668664/Sample Shop/YESB/shop@ybl/UPI   TRANSFER-1   706.82   -   4,12,536.51
06/01/2026   06/01/2026   NEFT*ABCD0123456*SBIN526123456789*Sample Co   TRANSFER-2   -   5,000.00   4,17,536.51
PVT LTD
07/01/2026   07/01/2026   ATM WDL SAMPLE ROAD   WDL TFR   2,000.00   -   4,15,536.51
WDL TFR
Page no 1
Date Value Date Description Ref No./Cheque No. Debit Credit Balance
08/01/2026   08/01/2026   CREDIT INTEREST   TRANSFER-3   -   12.34   4,15,548.85 4,15,548.85CR
Statement Summary
Brought Forward 4,13,243.33
Total Debits 2,706.82
Total Credits 5,012.34
Closing Balance 4,15,548.85
Please do not share your password
''';

const icici = '''
Statement of Transactions in Savings Account Number: 123401004911 for the period 01.01.2026 to 08.01.2026
Your Base Branch: SAMPLE BRANCH
Opening Balance 4,13,243.33
S No. Transaction Date Transaction Remarks Withdrawal Amount (INR) Deposit Amount (INR) Balance (INR)
1 05.01.2026 UPI/116581668664/Sample Shop/shop@ybl/SBIN 706.82 4,12,536.51
2 06.01.2026 NEFT-SBIN526123456789-SAMPLE CO 5,000.00 4,17,536.51
PVT LTD
3 07.01.2026 ATM CASH SAMPLE ROAD 2,000.00 4,15,536.51
Page 1 of 2
S No. Transaction Date Transaction Remarks Withdrawal Amount (INR) Deposit Amount (INR) Balance (INR)
4 08.01.2026 CREDIT INTEREST 12.34 4,15,548.85
Legends for transactions
Sincerly
''';

void main() {
  group('SBI-style', () {
    final read = readSbiStatement(sbi);

    test('reads every row with its printed direction, amount, balance and narration', () {
      expect(read.rows, hasLength(4));
      expect([for (final r in read.rows) r.direction], [Direction.debit, Direction.credit, Direction.debit, Direction.credit]);
      expect([for (final r in read.rows) r.amountMinor], [70682, 500000, 200000, 1234]);
      expect([for (final r in read.rows) r.balanceMinor], [41253651, 41753651, 41553651, 41554885]);
      expect(read.rows.first.date, DateTime.utc(2026, 1, 5));
      expect(read.rows.first.narration, contains('116581668664'));
      expect(read.rows[1].narration, contains('SBIN526123456789'));
      expect(read.rows[1].narration, endsWith('PVT LTD')); // the line that wrapped
      expect(read.rows[2].narration, isNot(contains('WDL TFR WDL TFR')));
    });

    test('reads the account and the statement summary', () {
      expect(read.issuerSlug, 'sbi');
      expect(read.accountMask, '8648');
      expect(read.openingMinor, 41324333);
      expect(read.closingMinor, 41554885);
      expect(read.printedDebitMinor, 270682);
      expect(read.printedCreditMinor, 501234);
    });

    test('a footer balance does not stick to the last narration', () {
      expect(read.rows.last.narration, 'CREDIT INTEREST TRANSFER-3');
    });

    test('the rows prove themselves against the statement', () {
      final check = read.check;
      expect(check.problems, isEmpty);
      expect(check.trusted, isTrue);
    });

    test('a misread digit is caught by the running balance', () {
      final bad = sbi.replaceFirst('5,000.00', '5,100.00');
      final check = readSbiStatement(bad).check;
      expect(check.trusted, isFalse);
      expect(check.suspectRows, isNotEmpty);
    });

    test('a row with both a debit and a credit, or neither, is kept aside, not guessed', () {
      final text = '''
05/01/2026 05/01/2026 BOTH COLUMNS REF 10.00 20.00 100.00
06/01/2026 06/01/2026 NEITHER COLUMN REF - - 100.00
07/01/2026 07/01/2026 FINE ROW REF 5.00 - 95.00
08/01/2026 08/01/2026 FINE TWO REF - 5.00 100.00
''';
      final r = readSbiStatement(text);
      expect(r.rows, hasLength(2));
      expect(r.skipped, hasLength(2));
    });
  });

  group('ICICI-style', () {
    final read = readIciciStatement(icici);

    test('reads every row; the page header between rows is not part of any narration', () {
      expect(read.rows, hasLength(4));
      expect([for (final r in read.rows) r.amountMinor], [70682, 500000, 200000, 1234]);
      expect([for (final r in read.rows) r.balanceMinor], [41253651, 41753651, 41553651, 41554885]);
      expect(read.rows[0].narration, 'UPI/116581668664/Sample Shop/shop@ybl/SBIN');
      expect(read.rows[1].narration, 'NEFT-SBIN526123456789-SAMPLE CO PVT LTD');
      expect(read.rows[2].narration, 'ATM CASH SAMPLE ROAD'); // the page header after it is not appended
      expect(read.rows[3].narration, 'CREDIT INTEREST');
      expect(read.rows.first.date, DateTime.utc(2026, 1, 5));
    });

    test('reads the account number and the opening balance', () {
      expect(read.issuerSlug, 'icici');
      expect(read.accountMask, '4911');
      expect(read.openingMinor, 41324333);
    });

    test('direction is printed nowhere; the running balance gives it', () {
      expect(read.rows.every((r) => r.direction == null), isTrue);
      final check = read.check;
      expect(check.trusted, isTrue, reason: check.problems.toString());
      expect([for (final r in check.rows) r.direction], [Direction.debit, Direction.credit, Direction.debit, Direction.credit]);
    });

    test('without an opening balance only the first row cannot be settled', () {
      final r = readIciciStatement(icici.replaceFirst('Opening Balance 4,13,243.33', ''));
      final check = r.check;
      expect(check.directionUnknown, [0]);
      expect(check.chainBreaks, isEmpty);
      expect(check.trusted, isFalse);
      expect(check.rows.skip(1).every((x) => x.direction != null), isTrue);
    });

    test('a misread digit is caught', () {
      final check = readIciciStatement(icici.replaceFirst('2,000.00', '2,100.00')).check;
      expect(check.trusted, isFalse);
      expect(check.suspectRows, isNotEmpty);
    });

    test('a dated line with no amounts is kept aside', () {
      final r = readIciciStatement('${icici.split('\n').take(6).join('\n')}\n9 09.01.2026 SOMETHING WITHOUT AMOUNTS\n');
      expect(r.skipped, hasLength(1));
    });
  });

  group('which layout', () {
    test('is decided by the rows, not by a bank name', () {
      expect(detectBankLayout(sbi), 'sbi');
      expect(detectBankLayout(icici), 'icici');
      expect(detectBankLayout(sbi.replaceAll('Account Name : SAMPLE PERSON\n', '')), 'sbi');
    });

    test('text that is neither layout is not read', () {
      expect(detectBankLayout('Hello\nThis is not a statement 12.34'), isNull);
      expect(detectBankLayout('05/01/2026 05/01/2026 ONLY ONE ROW 1.00 - 2.00'), isNull);
      expect(readBankStatement('nothing here'), isNull);
    });

    test('readBankStatement picks the reader', () {
      expect(readBankStatement(sbi)!.issuerSlug, 'sbi');
      expect(readBankStatement(icici)!.issuerSlug, 'icici');
    });

    test('spacing between columns does not matter', () {
      final tight = sbi.replaceAll(RegExp(r' {2,}'), ' ');
      expect(readSbiStatement(tight).rows, hasLength(4));
      expect(readSbiStatement(tight).check.trusted, isTrue);
    });
  });

  test('a read statement can be matched to SMS straight away', () {
    final read = readSbiStatement(sbi);
    final r = reconcileWithSms(
      read.check.rows,
      [
        StatementCandidate(
          id: 's1',
          at: DateTime.utc(2026, 1, 5, 6),
          amountsMinor: const [70682],
          primaryAmountMinor: 70682,
          direction: Direction.debit,
          accountMask: '8648',
          issuerSlug: 'sbi',
        ),
      ],
    );
    expect(r.summary.withSms, 1);
    expect(r.summary.withoutSms, 3);
    expect(r.summary.addedInMinor, 500000 + 1234);
    expect(r.summary.addedOutMinor, 200000);
  });
}
