// The phone's PDF reader on SBI-style and ICICI-style statements. The text is
// invented: names, numbers and amounts mean nothing; the layouts follow the
// real ones (see packages/pandapay_domain/test/sms_v2/ledger/statement_layouts_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/pdf_statement_parser.dart';

const sbi = '''
Account Number : 00000012345678648
Date Value Date Description Ref No./Cheque No. Debit Credit Balance
05/01/2026   05/01/2026   UPI/DR/116581668664/Sample Shop/YESB/shop@ybl/UPI   TRANSFER-1   706.82   -   4,12,536.51
06/01/2026   06/01/2026   NEFT*ABCD0123456*SBIN526123456789*Sample Co   TRANSFER-2   -   5,000.00   4,17,536.51
07/01/2026   07/01/2026   ATM WDL SAMPLE ROAD   WDL TFR   2,000.00   -   4,15,536.51
Statement Summary
Brought Forward 4,13,243.33
Closing Balance 4,15,536.51
''';

const icici = '''
Statement of Transactions in Savings Account Number: 123401004911
Opening Balance 4,13,243.33
S No. Transaction Date Transaction Remarks Withdrawal Amount (INR) Deposit Amount (INR) Balance (INR)
1 05.01.2026 UPI/116581668664/Sample Shop/shop@ybl/SBIN 706.82 4,12,536.51
2 06.01.2026 NEFT-SBIN526123456789-SAMPLE CO 5,000.00 4,17,536.51
3 07.01.2026 ATM CASH SAMPLE ROAD 2,000.00 4,15,536.51
''';

void main() {
  test('an SBI-style statement is read, with the right direction on every row', () {
    final r = parseStatementText(sbi);
    expect(r.transactions, hasLength(3));
    expect([for (final t in r.transactions) t.isCredit], [false, true, false]);
    expect([for (final t in r.transactions) t.amount.paise], [70682, 500000, 200000]);
    expect(r.transactions.first.date, DateTime(2026, 1, 5));
    expect(r.transactions.first.sourceAccount, 'SBI ••8648');
    expect(r.transactions.first.description, contains('Sample Shop'));
    expect(r.transactions.every((t) => t.reviewReasons.isEmpty), isTrue);
    expect(r.rejectedRows, isEmpty);
    expect(r.warnings, isEmpty);
    expect(r.closingBalance!.paise, 41553651);
    expect(r.reconciliation!.isBalanced, isTrue);
  });

  test('an ICICI-style statement is read; direction comes from the running balance', () {
    final r = parseStatementText(icici);
    expect(r.transactions, hasLength(3));
    expect([for (final t in r.transactions) t.isCredit], [false, true, false]);
    expect([for (final t in r.transactions) t.amount.paise], [70682, 500000, 200000]);
    expect(r.transactions.first.sourceAccount, 'ICICI ••4911');
    expect(r.transactions.every((t) => t.reviewReasons.isEmpty), isTrue);
    expect(r.warnings, isEmpty);
  });

  test('a misread amount is flagged, not trusted', () {
    final r = parseStatementText(icici.replaceFirst('5,000.00', '5,100.00'));
    expect(r.warnings, isNotEmpty);
    expect(r.transactions.any((t) => t.reviewReasons.isNotEmpty), isTrue);
  });

  test('without an opening balance the first ICICI row asks for a direction', () {
    final r = parseStatementText(icici.replaceFirst('Opening Balance 4,13,243.33\n', ''));
    expect(r.transactions.first.reviewReasons.join(' '), contains('money in or out'));
    expect(r.transactions.skip(1).every((t) => t.reviewReasons.isEmpty), isTrue);
  });

  test('a dated line that cannot be read is listed, not dropped', () {
    final r = parseStatementText('$sbi\n08/01/2026 08/01/2026 BOTH COLUMNS REF 10.00 20.00 100.00\n');
    expect(r.rejectedRows, hasLength(1));
    expect(r.transactions, hasLength(3));
  });

  test('a statement in another layout still goes to the generic reader', () {
    final r = parseStatementText('''
Statement Period 01/01/2026 to 31/01/2026
05/01/2026 Coffee shop 120.00 DR
''');
    expect(r.transactions, hasLength(1));
    expect(r.transactions.single.amount.paise, 12000);
    expect(r.transactions.single.sourceAccount, isNull);
  });
}
