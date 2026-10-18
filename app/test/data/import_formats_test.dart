import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/csv_statement_parser.dart';
import 'package:pandapay/data/pdf_statement_parser.dart';
import 'package:pandapay/data/spreadsheet_statement_parser.dart';

void main() {
  test(
    'bank references survive parsing and manual review without using app row IDs',
    () {
      final result = parseFlexibleCsvStatement(
        'Date,Description,Amount,Bank Reference,ID\n2026-10-02,Shop,100,ABC123456789,local-1',
      );
      expect(result.transactions.single.bankReference, 'ABC123456789');
      expect(
        result.transactions.single
            .reviewed(description: 'Corrected')
            .bankReference,
        'ABC123456789',
      );
      final localOnly = parseFlexibleCsvStatement(
        'Date,Description,Amount,ID\n2026-10-02,Shop,100,local-1',
      );
      expect(localOnly.transactions.single.bankReference, isNull);
    },
  );

  test(
    'UTF-16 TSV and credit-card account names do not turn spends into credits',
    () {
      const text =
          'Date\tDescription\tAmount\tAccount\n2026-10-02\tCoffee\t100\tExample credit 1234';
      final bytes = Uint8List.fromList([
        0xff,
        0xfe,
        for (final unit in text.codeUnits) ...[unit & 255, unit >> 8],
      ]);
      final result = parseDelimitedStatementBytes(bytes);
      expect(result.transactions.single.isCredit, isFalse);
      expect(result.transactions.single.amount.rupees, 100);
    },
  );

  test('invalid dates and unsupported currencies produce review warnings', () {
    final result = parseFlexibleCsvStatement(
      'Date,Description,Amount,Currency\n2026-02-30,Shop,100,INR\n2026-10-02,Shop,10,USD',
    );
    expect(result.transactions, isEmpty);
    expect(result.warnings.single, contains('2 nonempty rows'));
  });
  test(
    'Axio cell-per-line extraction preserves direction, account and expense flag',
    () {
      final result = parseStatementText('''
FROM:
2026-10-01
TO:
2026-10-31
TOTAL AMOUNT SPENT:
INR 1.0 K
TOP MERCHANTS
SHOP (1)
1.0 K
DATE
PLACE
AMOUNT
DR/CR
ACCOUNT
EXPENSE
INCOME
CATEGORY
2026-10-02 08:32
PM

SHOP NUMBER 42

1,000

DR

Example credit 1234

Yes

-

SHOPPING
PAGE 1
2026-10-03 12:39
PM
CARD BILL PAYMENT
1,000
CR
Example credit 1234
-
No
BILL PAYMENT
2026-10-03 12:43
PM
TRANSFER TO SAVINGS
300
DR
Example bank 5678
No
-
TRANSFER
''');
      expect(result.transactions, hasLength(3));
      final spend = result.transactions.first;
      expect(spend.description, 'SHOP NUMBER 42');
      expect(spend.date, DateTime(2026, 10, 2, 20, 32));
      expect(spend.amount.rupees, 1000);
      expect(
        spend.isCredit,
        isFalse,
      ); // "credit" in the account is not direction.
      expect(spend.sourceAccount, 'Example credit 1234');
      expect(result.transactions[1].isCredit, isTrue);
      expect(result.transactions[2].isTransfer, isTrue);
    },
  );

  test(
    'CSV ignores zero debit when credit is populated and rejects numeric narration',
    () {
      final result = parseFlexibleCsvStatement('''
Date,Description,Debit,Credit,Balance
2026-10-02,Refund,0,100,2000
2026-10-03,Coffee,30,0,1970
2026-10-04,Reference ABC123,,,2000
''');
      expect(result.transactions, hasLength(2));
      expect(result.transactions.first.isCredit, isTrue);
      expect(result.transactions.first.amount.rupees, 100);
    },
  );

  test('CSV Axio columns preserve account, DR/CR and transfer flags', () {
    final result = parseFlexibleCsvStatement('''
DATE,PLACE,AMOUNT,DR/CR,ACCOUNT,EXPENSE,INCOME,CATEGORY
2026-10-02,Coffee,100,DR,Example credit 1234,Yes,-,Food
2026-10-03,Refund,50,CR,Example credit 1234,-,Yes,Other
2026-10-04,Savings,200,DR,Example bank 5678,No,-,TRANSFER
''');
    expect(result.transactions, hasLength(3));
    expect(result.transactions.first.description, 'Coffee');
    expect(result.transactions.first.sourceAccount, 'Example credit 1234');
    expect(result.transactions.first.isCredit, isFalse);
    expect(result.transactions[1].isCredit, isTrue);
    expect(result.transactions.last.isTransfer, isTrue);
  });

  test(
    'XLSX reads sparse columns, shared strings, dates and multiple worksheets',
    () {
      final archive = Archive();
      void add(String path, String value) {
        final bytes = utf8.encode(value);
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
      }

      add('xl/workbook.xml', '<workbook><workbookPr/></workbook>');
      add('xl/sharedStrings.xml', '<sst><si><t>Coffee</t></si></sst>');
      add(
        'xl/styles.xml',
        '<styleSheet><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>',
      );
      add('xl/worksheets/sheet1.xml', '''<worksheet><sheetData>
<row><c r="A1" t="inlineStr"><is><t>Date</t></is></c><c r="C1" t="inlineStr"><is><t>Description</t></is></c><c r="D1" t="inlineStr"><is><t>Amount</t></is></c></row>
<row><c r="A2" s="1"><v>46300</v></c><c r="C2" t="s"><v>0</v></c><c r="D2"><v>125.50</v></c></row>
</sheetData></worksheet>''');
      add('xl/worksheets/sheet2.xml', '''<worksheet><sheetData>
<row><c r="A1" t="inlineStr"><is><t>Date</t></is></c><c r="B1" t="inlineStr"><is><t>Merchant</t></is></c><c r="C1" t="inlineStr"><is><t>Amount</t></is></c></row>
<row><c r="A2" t="inlineStr"><is><t>2026-10-07</t></is></c><c r="B2" t="inlineStr"><is><t>Fuel</t></is></c><c r="C2"><v>500</v></c></row>
</sheetData></worksheet>''');
      final result = parseSpreadsheetStatement(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
      expect(result.transactions, hasLength(2));
      expect(result.transactions.first.date, DateTime(2026, 10, 5));
      expect(result.transactions.first.description, 'Coffee');
      expect(result.transactions.first.amount.rupees, 125.5);
      expect(result.transactions.last.description, 'Fuel');
    },
  );
}
