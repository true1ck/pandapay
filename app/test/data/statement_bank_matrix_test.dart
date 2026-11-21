// Bank statement import across bank layouts: real PDFs are drawn from invented
// transactions in the layout each bank commonly prints, then read back through
// the same extractor and parser the app uses. Every row must come back with the
// right date, amount, direction and narration, with nothing flagged, rejected or
// warned about. See ../support/statement_pdf_builder.dart for what a profile is
// (and is not) evidence of.
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/pdf_statement_parser.dart';

import '../support/statement_pdf_builder.dart';

const _ar = CellAlign.right;

final _icici = BankProfile(
  name: 'ICICI savings',
  titleLines: const [
    'ICICI BANK LIMITED',
    'Statement of Transactions in Saving Account no. 912345670011 in INR for the period January 1, 2026 - November 11, 2026',
  ],
  columns: const [
    PdfColumn('serial', ['S No.'], 24, 20),
    PdfColumn('date', ['Transaction', 'Date'], 60, 55),
    PdfColumn('ref', ['Cheque Number'], 122, 65),
    PdfColumn('narration', ['Transaction Remarks'], 192, 200),
    PdfColumn('debit', ['Withdrawal', 'Amount (INR)'], 395, 58, align: _ar),
    PdfColumn('credit', ['Deposit', 'Amount (INR)'], 462, 57, align: _ar),
    PdfColumn('balance', ['Balance', '(INR)'], 520, 51, align: _ar),
  ],
  dateFormat: dmyDots,
  money: plainMoney,
  dateOffset: 5,
  narrationChars: 44,
  footerLines: const ['Page {n}'],
);

BankProfile _sbi({String empty = '', bool headerEveryPage = true}) =>
    BankProfile(
      name: 'SBI style (empty cells "$empty")',
      titleLines: const [
        'State Bank of India',
        'Account Number : 00000091234567',
        'Account Statement from 1 Jan 2026 to 11 Nov 2026',
      ],
      columns: const [
        PdfColumn('date', ['Txn', 'Date'], 30, 60),
        PdfColumn('valueDate', ['Value', 'Date'], 95, 60),
        PdfColumn('narration', ['Description'], 160, 165),
        PdfColumn('ref', ['Ref No./', 'Cheque No.'], 330, 60),
        PdfColumn('debit', ['Debit'], 395, 55, align: _ar),
        PdfColumn('credit', ['Credit'], 455, 55, align: _ar),
        PdfColumn('balance', ['Balance'], 515, 60, align: _ar),
      ],
      dateFormat: dMonY,
      money: indianMoney,
      emptyCell: empty,
      headerEveryPage: headerEveryPage,
      narrationChars: 36,
      footerLines: const [
        'Please do not share your ATM, Debit/Credit card number, PIN, OTP.',
        'Page {n}',
      ],
    );

BankProfile _hdfc({
  bool newestFirst = false,
  bool centered = false,
  double? narrationFontSize,
  bool framed = false,
  int? narrationChars,
}) => BankProfile(
  name:
      'HDFC style${newestFirst ? ', newest first' : ''}${centered ? ', cells centred on the narration' : ''}${narrationFontSize != null ? ', smaller narration font' : ''}${framed ? ', opening row + totals row + summary above the header' : ''}',
  centered: centered,
  narrationChars: narrationChars ?? 38,
  narrationFontSize: narrationFontSize,
  openingLabel: framed ? 'Opening Balance' : null,
  totalsLabel: framed ? 'Total' : null,
  summaryAbove: framed,
  titleLines: const [
    'HDFC BANK LIMITED',
    'Account No : 50100123456789',
    'Statement From : 01/01/2026 To : 11/11/2026',
  ],
  columns: const [
    PdfColumn('date', ['Date'], 30, 45),
    PdfColumn('narration', ['Narration'], 78, 185),
    PdfColumn('ref', ['Chq./Ref.No.'], 266, 70),
    PdfColumn('valueDate', ['Value Dt'], 340, 45),
    PdfColumn('debit', ['Withdrawal', 'Amt.'], 390, 58, align: _ar),
    PdfColumn('credit', ['Deposit', 'Amt.'], 452, 58, align: _ar),
    PdfColumn('balance', ['Closing', 'Balance'], 514, 60, align: _ar),
  ],
  dateFormat: dmySlash2,
  money: indianMoney,
  newestFirst: newestFirst,
  footerLines: const ['Page No .: {n}'],
);

final _axis = BankProfile(
  name: 'Axis style',
  titleLines: const [
    'AXIS BANK',
    'Statement of Account No - 915010012345678 for the period (From : 01-01-2026 To : 11-11-2026)',
  ],
  columns: const [
    PdfColumn('date', ['Tran Date'], 30, 55),
    PdfColumn('ref', ['CHQNO'], 92, 45),
    PdfColumn('narration', ['PARTICULARS'], 142, 195),
    PdfColumn('debit', ['DR'], 340, 62, align: _ar),
    PdfColumn('credit', ['CR'], 406, 62, align: _ar),
    PdfColumn('balance', ['BAL'], 472, 70, align: _ar),
    PdfColumn('branch', ['SOL'], 548, 28),
  ],
  dateFormat: dmyDash,
  money: indianMoney,
  narrationChars: 42,
  footerLines: const ['Page {n}'],
);

final _kotak = BankProfile(
  name: 'Kotak style (one amount column with Dr/Cr markers)',
  titleLines: const [
    'Kotak Mahindra Bank',
    'Account No. 7712345678',
    'Period 01 Jan 2026 - 11 Nov 2026',
  ],
  columns: const [
    PdfColumn('date', ['Date'], 30, 60),
    PdfColumn('narration', ['Narration'], 95, 165),
    PdfColumn('ref', ['Chq/Ref No'], 265, 65),
    PdfColumn(
      'amount',
      ['Withdrawal (Dr)/', 'Deposit (Cr)'],
      335,
      85,
      align: _ar,
    ),
    PdfColumn('balance', ['Balance'], 430, 95, align: _ar),
  ],
  dateFormat: ddMonY,
  money: indianMoney,
  amountMarker: (credit) => credit ? '(Cr)' : '(Dr)',
  balanceMoney: (paise, positive) =>
      '${indianMoney(paise)}${positive ? '(Cr)' : '(Dr)'}',
  narrationChars: 36,
  footerLines: const ['Page {n}'],
);

final _idfc = BankProfile(
  name: 'IDFC First style (dd-Mon-yyyy)',
  titleLines: const [
    'IDFC FIRST Bank',
    'Account Number: 10012345678',
    'Statement Period: 01-Jan-2026 to 11-Nov-2026',
  ],
  columns: const [
    PdfColumn('date', ['Transaction Date'], 30, 62),
    PdfColumn('valueDate', ['Value Date'], 96, 55),
    PdfColumn('narration', ['Particulars'], 156, 175),
    PdfColumn('ref', ['Cheque No.'], 335, 50),
    PdfColumn('debit', ['Debit'], 390, 58, align: _ar),
    PdfColumn('credit', ['Credit'], 452, 58, align: _ar),
    PdfColumn('balance', ['Balance'], 514, 60, align: _ar),
  ],
  dateFormat: ddMonDashY,
  money: indianMoney,
  narrationChars: 38,
  footerLines: const ['Page {n}'],
);

final _yesZeros = BankProfile(
  name: 'Yes Bank style (0.00 in the empty column)',
  titleLines: const [
    'YES BANK',
    'Account Number 002345678901',
    'Statement of Account',
  ],
  columns: const [
    PdfColumn('date', ['Transaction', 'Date'], 30, 58),
    PdfColumn('valueDate', ['Value', 'Date'], 92, 55),
    PdfColumn('narration', ['Description'], 152, 190),
    PdfColumn('debit', ['Withdrawals'], 345, 58, align: _ar),
    PdfColumn('credit', ['Deposits'], 408, 58, align: _ar),
    PdfColumn('balance', ['Running', 'Balance'], 472, 70, align: _ar),
  ],
  dateFormat: dmySlash,
  money: indianMoney,
  emptyCell: '0.00',
  narrationChars: 42,
  footerLines: const ['Page {n}'],
);

final _leftAligned = BankProfile(
  name: 'Federal style (amounts left-aligned)',
  titleLines: const [
    'The Federal Bank Ltd',
    'Account Number 12345678901234',
    'Statement of Account',
  ],
  columns: const [
    PdfColumn('date', ['Date'], 30, 58),
    PdfColumn('narration', ['Particulars'], 92, 210),
    PdfColumn('debit', ['Withdrawals'], 310, 60),
    PdfColumn('credit', ['Deposits'], 376, 60),
    PdfColumn('balance', ['Balance'], 442, 70),
  ],
  dateFormat: ddMonDashY,
  money: indianMoney,
  narrationChars: 46,
  footerLines: const ['Page {n}'],
);

final _pnb = BankProfile(
  name: 'PNB style (balance with a separate Cr word)',
  titleLines: const [
    'Punjab National Bank',
    'Account No. 0123000100123456',
    'Statement of Account',
  ],
  columns: const [
    PdfColumn('date', ['Date'], 30, 50),
    PdfColumn('narration', ['Particulars'], 84, 200),
    PdfColumn('debit', ['Withdrawals'], 290, 65, align: _ar),
    PdfColumn('credit', ['Deposits'], 360, 65, align: _ar),
    PdfColumn('balance', ['Balance'], 430, 80, align: _ar),
  ],
  dateFormat: dmySlash,
  money: indianMoney,
  balanceMoney: (paise, positive) =>
      '${indianMoney(paise)} ${positive ? 'Cr' : 'Dr'}',
  narrationChars: 44,
  footerLines: const ['Page {n}'],
);

/// No running balance to prove rows against: the table reader declines and the
/// text reader takes it. Its amounts must still be right; it may only ask the
/// person to confirm the day/month order.
final _card = BankProfile(
  name: 'credit card style (no balance column, Cr marker)',
  titleLines: const [
    'HDFC Bank Credit Card Statement',
    'Card No: 4012 XXXX XXXX 1234',
    'Statement Date 11/11/2026',
  ],
  columns: const [
    PdfColumn('date', ['Date'], 30, 60),
    PdfColumn('narration', ['Transaction Description'], 100, 290),
    PdfColumn('amount', ['Amount (in Rs.)'], 420, 100, align: _ar),
  ],
  dateFormat: dmySlash,
  money: indianMoney,
  narrationChars: 60,
  amountMarker: (credit) => credit ? ' Cr' : '',
);

typedef _Case = ({BankProfile profile, String label, String mask});

final List<_Case> _cases = [
  (profile: _icici, label: 'ICICI', mask: '0011'),
  (profile: _sbi(), label: 'SBI', mask: '4567'),
  (profile: _sbi(empty: '-'), label: 'SBI', mask: '4567'),
  (profile: _sbi(headerEveryPage: false), label: 'SBI', mask: '4567'),
  (profile: _hdfc(), label: 'HDFC', mask: '6789'),
  (profile: _hdfc(newestFirst: true), label: 'HDFC', mask: '6789'),
  (profile: _hdfc(centered: true), label: 'HDFC', mask: '6789'),
  (
    profile: _hdfc(centered: true, narrationChars: 16),
    label: 'HDFC',
    mask: '6789',
  ),
  (profile: _hdfc(narrationFontSize: 6.5), label: 'HDFC', mask: '6789'),
  (profile: _hdfc(framed: true), label: 'HDFC', mask: '6789'),
  (profile: _axis, label: 'Axis', mask: '5678'),
  (profile: _kotak, label: 'Kotak', mask: '5678'),
  (profile: _idfc, label: 'IDFC First', mask: '5678'),
  (profile: _yesZeros, label: 'Yes Bank', mask: '8901'),
  (profile: _leftAligned, label: 'Federal Bank', mask: '1234'),
  (profile: _pnb, label: 'PNB', mask: '3456'),
];

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

ParsedStatement _import(BankProfile p, List<Txn> txns, {Set<int>? omit}) {
  final bytes = buildStatementPdf(
    p,
    txns,
    opening: 50000000,
    omit: omit ?? const {},
  );
  final x = PdfStatementReader().extract(bytes);
  return parseStatementPdf(x.pages.join('\n'), words: x.words);
}

void main() {
  final txns = sampleTransactions();

  group('PDF bank statements, every row exact', () {
    for (final c in _cases) {
      test(c.profile.name, () {
        final parsed = _import(c.profile, txns);
        expect(parsed.rejectedRows, isEmpty, reason: 'rows left unread');
        expect(parsed.warnings, isEmpty);
        expect(parsed.transactions, hasLength(txns.length));
        for (var i = 0; i < txns.length; i++) {
          final got = parsed.transactions[i], want = txns[i];
          final at = 'row ${i + 1}: ${want.narration}';
          expect(
            (got.date.year, got.date.month, got.date.day),
            (want.date.year, want.date.month, want.date.day),
            reason: 'date, $at',
          );
          expect(got.amount.paise, want.amount, reason: 'amount, $at');
          expect(got.isCredit, want.isCredit, reason: 'direction, $at');
          expect(
            _norm(got.description),
            _norm(want.narration),
            reason: 'narration, $at',
          );
          expect(got.reviewReasons, isEmpty, reason: 'flags, $at');
          expect(got.sourceAccount, '${c.label} ••${c.mask}');
        }
      });
    }
  });

  group('what the import review relies on', () {
    test(
      'a card bill paid through net banking is a transfer, not spending',
      () {
        final parsed = _import(_icici, txns);
        final billRows = [
          for (var i = 0; i < txns.length; i++)
            if (txns[i].narration.contains('CC BillPay')) i,
        ];
        expect(billRows, isNotEmpty);
        for (final i in billRows) {
          expect(
            parsed.transactions[i].isTransfer,
            isTrue,
            reason: txns[i].narration,
          );
        }
        // The only other transfers are the loan EMIs, which the rules already
        // treat as repayments.
        expect(
          [
            for (var i = 0; i < txns.length; i++)
              if (parsed.transactions[i].isTransfer) i,
          ],
          [
            for (var i = 0; i < txns.length; i++)
              if (txns[i].narration.contains('CC BillPay') ||
                  txns[i].narration.endsWith(' EMI'))
                i,
          ],
        );
      },
    );
  });

  group('a statement that cannot be proven is never imported as certain', () {
    test('a row missing from the PDF is flagged on the row after the gap', () {
      final parsed = _import(_sbi(), txns, omit: {10});
      expect(parsed.transactions, hasLength(txns.length - 1));
      final flagged = [
        for (final t in parsed.transactions)
          if (t.reviewReasons.isNotEmpty) t,
      ];
      expect(flagged, hasLength(1));
      expect(flagged.single.reviewReasons.single, contains('running balance'));
      expect(parsed.warnings, isNotEmpty);
    });

    test('a PDF with no table in it reads nothing as a table', () {
      final parsed = parseStatementPdf('hello world', words: const []);
      expect(parsed.transactions, isEmpty);
    });
  });
}
