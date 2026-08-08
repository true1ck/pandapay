import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/pdf_statement_parser.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  group('parseStatementText', () {
    test('extracts a well-formed transaction line', () {
      final result = parseStatementText('12/05/2026  AMAZON PAY INDIA PVT LTD MUM   1,234.50');
      expect(result.transactions, hasLength(1));
      final line = result.transactions.single;
      expect(line.date, DateTime(2026, 5, 12));
      expect(line.description, 'AMAZON PAY INDIA PVT LTD MUM');
      expect(line.amount.paise, Money.fromRupees(1234.50).paise);
    });

    test('extracts multiple lines and skips non-transaction lines in between', () {
      final text = '''
Statement Period: 01 Apr 2026 to 30 Apr 2026
Card Number: XXXX XXXX XXXX 1234

01/04/2026  SWIGGY BANGALORE   550.00
05-04-2026  UBER TRIP   220.75 Dr
Some footer disclaimer text that is not a transaction.
''';
      final result = parseStatementText(text);
      expect(result.transactions, hasLength(2));
      expect(result.transactions[0].description, 'SWIGGY BANGALORE');
      expect(result.transactions[0].amount.paise, Money.fromRupees(550.00).paise);
      expect(result.transactions[1].date, DateTime(2026, 4, 5));
      expect(result.transactions[1].description, 'UBER TRIP');
      expect(result.transactions[1].amount.paise, Money.fromRupees(220.75).paise);
    });

    test('handles a Cr suffix the same as no suffix (debit/credit not yet distinguished)', () {
      final result = parseStatementText('10/06/2026  REFUND FROM MERCHANT   199.00 Cr');
      expect(result.transactions.single.amount.paise, Money.fromRupees(199.00).paise);
    });

    test('extracts the closing balance from a labeled line', () {
      final text = '''
12/05/2026  SOME MERCHANT   100.00
Closing Balance: 24,310.00
''';
      final result = parseStatementText(text);
      expect(result.closingBalance!.paise, Money.fromRupees(24310).paise);
    });

    test('closing balance is case-insensitive and tolerates a colon or spaces', () {
      expect(parseStatementText('CLOSING BALANCE   5,000.00').closingBalance!.paise, Money.fromRupees(5000).paise);
      expect(parseStatementText('closing balance: 5,000.00').closingBalance!.paise, Money.fromRupees(5000).paise);
    });

    test('returns no closing balance when the statement never mentions one', () {
      final result = parseStatementText('12/05/2026  SOME MERCHANT   100.00');
      expect(result.closingBalance, isNull);
    });

    test('an empty statement yields zero transactions, not an error', () {
      final result = parseStatementText('');
      expect(result.transactions, isEmpty);
      expect(result.closingBalance, isNull);
    });

    test('a two-digit year is normalized to 20xx', () {
      final result = parseStatementText('12/05/26  SOME MERCHANT   100.00');
      expect(result.transactions.single.date.year, 2026);
    });

    test('an invalid date (month 13) is skipped, not thrown', () {
      final result = parseStatementText('12/13/2026  SOME MERCHANT   100.00');
      expect(result.transactions, isEmpty);
    });

    test('a malformed amount is skipped, not thrown', () {
      final result = parseStatementText('12/05/2026  SOME MERCHANT   not-a-number');
      expect(result.transactions, isEmpty);
    });
  });

  group('PdfStatementReader (real syncfusion round-trip, no fixture file needed)', () {
    test('extracts text written into a freshly-created, unencrypted PDF', () {
      final document = PdfDocument();
      document.pages.add().graphics.drawString(
            '01/04/2026 TEST MERCHANT 100.00\nClosing Balance: 900.00',
            PdfStandardFont(PdfFontFamily.helvetica, 12),
          );
      final bytes = Uint8List.fromList(document.saveSync());
      document.dispose();

      final text = PdfStatementReader().extractText(bytes);
      final result = parseStatementText(text);

      expect(result.transactions, hasLength(1));
      expect(result.transactions.single.description, 'TEST MERCHANT');
      expect(result.closingBalance!.paise, Money.fromRupees(900).paise);
    });

    test('a wrong password throws StatementParseException with a plain-language message', () {
      final document = PdfDocument();
      document.pages.add().graphics.drawString('irrelevant', PdfStandardFont(PdfFontFamily.helvetica, 12));
      document.security.userPassword = 'correct-password';
      final bytes = Uint8List.fromList(document.saveSync());
      document.dispose();

      expect(
        () => PdfStatementReader().extractText(bytes, password: 'wrong-password'),
        throwsA(isA<StatementParseException>()),
      );
    });

    test('the correct password successfully decrypts and extracts text', () {
      final document = PdfDocument();
      document.pages.add().graphics.drawString(
            '01/04/2026 SECRET MERCHANT 50.00',
            PdfStandardFont(PdfFontFamily.helvetica, 12),
          );
      document.security.userPassword = 'my-password';
      final bytes = Uint8List.fromList(document.saveSync());
      document.dispose();

      final text = PdfStatementReader().extractText(bytes, password: 'my-password');
      expect(parseStatementText(text).transactions.single.description, 'SECRET MERCHANT');
    });
  });
}
