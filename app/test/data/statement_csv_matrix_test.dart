// CSV and XLSX bank statement import across the export shapes banks produce. The files
// are built from invented transactions (the same ones the PDF matrix uses) and
// pushed through the real ImportDocument pipeline. Every row must come back with
// the right date, amount, direction and narration; the lines around the table
// (account details, statement period, totals, disclaimers) must never become
// transactions.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/import_models.dart' show ParsedStatement;
import 'package:pandapay/data/transaction_import_pipeline.dart';

import '../support/statement_pdf_builder.dart';

typedef _Fmt = String Function(DateTime);

class _Csv {
  const _Csv({
    required this.name,
    required this.columns,
    required this.header,
    required this.date,
    required this.money,
    this.preamble = const [],
    this.footer = const [],
    this.delimiter = ',',
    this.emptyCell = '',
    this.quote = false,
    this.bom = false,
    this.markers = false,
    this.signed = false,
    this.newestFirst = false,
  });

  final String name;

  /// Column keys in file order: serial, date, valueDate, narration, ref, debit,
  /// credit, amount, drcr, balance, branch.
  final List<String> columns;
  final List<String> header;
  final _Fmt date;
  final String Function(int) money;
  final List<String> preamble, footer;
  final String delimiter, emptyCell;

  /// Quote every amount, as exports that print "1,00,000.00" must.
  final bool quote;
  final bool bom;

  /// Amount cells carry a Dr/Cr word after the number.
  final bool markers;

  /// One amount column, negative for money out.
  final bool signed;
  final bool newestFirst;
}

String _cell(String v, String delimiter, {bool force = false}) {
  if (force || v.contains(delimiter) || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

Uint8List _build(_Csv c, List<Txn> txns, int opening) {
  final balances = balancesFor(txns, opening);
  final order = [for (var i = 0; i < txns.length; i++) i];
  if (c.newestFirst) order.sort((a, b) => b.compareTo(a));
  final lines = <String>[
    ...c.preamble,
    c.header.map((h) => _cell(h, c.delimiter)).join(c.delimiter),
  ];
  var serial = 0;
  for (final i in order) {
    final t = txns[i];
    serial++;
    final cells = <String>[];
    for (final key in c.columns) {
      switch (key) {
        case 'serial':
          cells.add('$serial');
        case 'date':
        case 'valueDate':
          cells.add(c.date(t.date));
        case 'narration':
          cells.add(_cell(t.narration, c.delimiter));
        case 'ref':
          cells.add('');
        case 'debit':
          cells.add(
            _cell(
              t.isCredit ? c.emptyCell : c.money(t.debit!),
              c.delimiter,
              force: c.quote && !t.isCredit,
            ),
          );
        case 'credit':
          cells.add(
            _cell(
              t.isCredit ? c.money(t.credit!) : c.emptyCell,
              c.delimiter,
              force: c.quote && t.isCredit,
            ),
          );
        case 'amount':
          final base = c.signed
              ? '${t.isCredit ? '' : '-'}${c.money(t.amount)}'
              : c.money(t.amount);
          final text = c.markers ? '$base ${t.isCredit ? 'Cr' : 'Dr'}' : base;
          cells.add(_cell(text, c.delimiter, force: c.quote));
        case 'drcr':
          cells.add(t.isCredit ? 'CR' : 'DR');
        case 'balance':
          cells.add(_cell(c.money(balances[i]), c.delimiter, force: c.quote));
        case 'branch':
          cells.add('4821');
      }
    }
    lines.add(cells.join(c.delimiter));
  }
  lines.addAll(c.footer);
  final text = '${c.bom ? '﻿' : ''}${lines.join('\r\n')}\r\n';
  return Uint8List.fromList(utf8.encode(text));
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

final _cases = <_Csv>[
  _Csv(
    name: 'HDFC net banking (dd/mm/yy, plain numbers, Closing Balance)',
    columns: const [
      'date',
      'narration',
      'ref',
      'valueDate',
      'debit',
      'credit',
      'balance',
    ],
    header: const [
      'Date',
      'Narration',
      'Chq./Ref.No.',
      'Value Dt',
      'Withdrawal Amt.',
      'Deposit Amt.',
      'Closing Balance',
    ],
    date: dmySlash2,
    money: plainMoney,
    emptyCell: '',
  ),
  _Csv(
    name: 'ICICI iMobile (serial, value date, transaction date, preamble)',
    columns: const [
      'serial',
      'valueDate',
      'date',
      'ref',
      'narration',
      'debit',
      'credit',
      'balance',
    ],
    header: const [
      'S No.',
      'Value Date',
      'Transaction Date',
      'Cheque Number',
      'Transaction Remarks',
      'Withdrawal Amount (INR )',
      'Deposit Amount (INR )',
      'Balance (INR )',
    ],
    preamble: const [
      'Transactions List - ASHA N - 912345670011 (INR) - Saving Account,,,,,,,',
      ',,,,,,,',
      'Transaction Period:,01/01/2026 - 11/11/2026,,,,,,',
      ',,,,,,,',
    ],
    date: dmySlash,
    money: plainMoney,
  ),
  _Csv(
    name: 'SBI net banking (quoted Indian amounts, "dd Mon yyyy", preamble)',
    columns: const [
      'date',
      'valueDate',
      'narration',
      'ref',
      'debit',
      'credit',
      'balance',
    ],
    header: const [
      'Txn Date',
      'Value Date',
      'Description',
      'Ref No./Cheque No.',
      'Debit',
      'Credit',
      'Balance',
    ],
    preamble: const [
      'Account Name :,MS ASHA N,,,,,',
      'Address :,SALEM,,,,,',
      'Account Number :,00000091234567,,,,,',
      'Account Statement from 1 Jan 2026 to 11 Nov 2026,,,,,,',
      ',,,,,,',
    ],
    footer: const [
      ',,,,,,',
      'Computer generated statement. Please do not share your OTP.,,,,,,',
    ],
    date: dMonY,
    money: indianMoney,
    quote: true,
  ),
  _Csv(
    name: 'SBI with "-" in the empty column',
    columns: const [
      'date',
      'valueDate',
      'narration',
      'ref',
      'debit',
      'credit',
      'balance',
    ],
    header: const [
      'Txn Date',
      'Value Date',
      'Description',
      'Ref No./Cheque No.',
      'Debit',
      'Credit',
      'Balance',
    ],
    date: dMonY,
    money: indianMoney,
    emptyCell: '-',
    quote: true,
  ),
  _Csv(
    name: 'Axis (SRL NO, Tran Date dd-mm-yyyy, DR, CR, BAL, SOL)',
    columns: const [
      'serial',
      'date',
      'ref',
      'narration',
      'debit',
      'credit',
      'balance',
      'branch',
    ],
    header: const [
      'SRL NO',
      'Tran Date',
      'CHQNO',
      'PARTICULARS',
      'DR',
      'CR',
      'BAL',
      'SOL',
    ],
    date: dmyDash,
    money: plainMoney,
  ),
  _Csv(
    name: 'Kotak (Debit, Credit, Balance and a Dr/Cr column)',
    columns: const [
      'serial',
      'date',
      'valueDate',
      'narration',
      'ref',
      'debit',
      'credit',
      'balance',
      'drcr',
    ],
    header: const [
      'Sl. No.',
      'Transaction Date',
      'Value Date',
      'Description',
      'Chq / Ref No.',
      'Debit',
      'Credit',
      'Balance',
      'Dr / Cr',
    ],
    date: dmyDash,
    money: indianMoney,
    quote: true,
  ),
  _Csv(
    name: 'one Amount column with a Dr/Cr column',
    columns: const ['date', 'narration', 'amount', 'drcr', 'balance'],
    header: const ['Date', 'Description', 'Amount', 'Dr/Cr', 'Balance'],
    date: ddMonDashY,
    money: plainMoney,
  ),
  _Csv(
    name: 'one signed Amount column (negative is money out)',
    columns: const ['date', 'narration', 'amount', 'balance'],
    header: const ['Date', 'Narration', 'Amount', 'Balance'],
    date: dmySlash,
    money: plainMoney,
    signed: true,
  ),
  _Csv(
    name: 'Yes Bank (0.00 in the empty column, running balance)',
    columns: const [
      'date',
      'valueDate',
      'narration',
      'debit',
      'credit',
      'balance',
    ],
    header: const [
      'Transaction Date',
      'Value Date',
      'Description',
      'Withdrawals',
      'Deposits',
      'Running Balance',
    ],
    date: dmySlash,
    money: plainMoney,
    emptyCell: '0.00',
  ),
  _Csv(
    name: 'semicolon-separated with a byte-order mark',
    columns: const ['date', 'narration', 'debit', 'credit', 'balance'],
    header: const ['Date', 'Particulars', 'Withdrawals', 'Deposits', 'Balance'],
    date: dmySlash,
    money: plainMoney,
    delimiter: ';',
    bom: true,
  ),
  _Csv(
    name: 'tab-separated export',
    columns: const ['date', 'narration', 'debit', 'credit', 'balance'],
    header: const ['Date', 'Narration', 'Debit', 'Credit', 'Balance'],
    date: dmyDash,
    money: plainMoney,
    delimiter: '\t',
  ),
  _Csv(
    name: 'newest first',
    columns: const ['date', 'narration', 'debit', 'credit', 'balance'],
    header: const ['Date', 'Narration', 'Debit', 'Credit', 'Balance'],
    date: dmySlash,
    money: plainMoney,
    newestFirst: true,
  ),
  _Csv(
    name: 'amounts with a Cr/Dr word after the number',
    columns: const ['date', 'narration', 'amount', 'balance'],
    header: const ['Date', 'Narration', 'Amount', 'Balance'],
    date: dMonY,
    money: indianMoney,
    markers: true,
    quote: true,
  ),
];

/// A workbook from raw cells. A DateTime is written as the real Excel date
/// serial a bank's workbook holds; a number as a number; text as text.
Uint8List _xlsx(List<List<Object?>> rows) {
  final archive = Archive();
  void add(String path, String value) {
    final bytes = utf8.encode(value);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final sheet = StringBuffer('<worksheet><sheetData>');
  for (var r = 0; r < rows.length; r++) {
    sheet.write('<row>');
    for (var c = 0; c < rows[r].length; c++) {
      final v = rows[r][c];
      final ref = '${letters[c]}${r + 1}';
      if (v == null || (v is String && v.isEmpty)) continue;
      if (v is DateTime) {
        final serial = DateTime.utc(
          v.year,
          v.month,
          v.day,
        ).difference(DateTime.utc(1899, 12, 30)).inDays;
        sheet.write('<c r="$ref" s="1"><v>$serial</v></c>');
      } else if (v is num) {
        sheet.write('<c r="$ref"><v>$v</v></c>');
      } else {
        sheet.write(
          '<c r="$ref" t="inlineStr"><is><t>${esc('$v')}</t></is></c>',
        );
      }
    }
    sheet.write('</row>');
  }
  sheet.write('</sheetData></worksheet>');
  add('xl/workbook.xml', '<workbook><workbookPr/></workbook>');
  add(
    'xl/styles.xml',
    '<styleSheet><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>',
  );
  add('xl/worksheets/sheet1.xml', sheet.toString());
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void _expectExact(ParsedStatement parsed, List<Txn> expected) {
  expect(
    parsed.rejectedRows,
    isEmpty,
    reason:
        'rows left unread (${parsed.rejectedRows.length}): ${parsed.rejectedRows.take(3).map((r) => r.cells.join('|')).toList()}',
  );
  expect(parsed.transactions, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    final got = parsed.transactions[i], want = expected[i];
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
  }
}

void main() {
  final txns = sampleTransactions();

  group('CSV bank statements, every row exact', () {
    for (final c in _cases) {
      test(c.name, () {
        final bytes = _build(c, txns, 50000000);
        final parsed = ImportDocument.open(bytes, 'statement.csv').parse();
        // A statement printed newest first comes back in the order it was read.
        _expectExact(parsed, c.newestFirst ? txns.reversed.toList() : txns);
      });
    }
  });

  group('XLSX bank statements, every row exact', () {
    final balances = balancesFor(txns, 50000000);

    test(
      'ICICI workbook: real dates, numeric amounts, rows above the table',
      () {
        final bytes = _xlsx([
          ['Transactions List - ASHA N - 912345670011 (INR)'],
          [],
          ['Transaction Period:', '01/01/2026 - 11/11/2026'],
          [],
          [
            'S No.',
            'Value Date',
            'Transaction Date',
            'Cheque Number',
            'Transaction Remarks',
            'Withdrawal Amount (INR )',
            'Deposit Amount (INR )',
            'Balance (INR )',
          ],
          for (var i = 0; i < txns.length; i++)
            [
              i + 1,
              txns[i].date,
              txns[i].date,
              null,
              txns[i].narration,
              txns[i].isCredit ? null : txns[i].debit! / 100,
              txns[i].isCredit ? txns[i].credit! / 100 : null,
              balances[i] / 100,
            ],
        ]);
        final parsed = ImportDocument.open(bytes, 'statement.xlsx').parse();
        _expectExact(parsed, txns);
      },
    );

    test('SBI workbook: amounts and dates stored as text', () {
      final bytes = _xlsx([
        ['Account Name :', 'MS ASHA N'],
        [],
        [
          'Txn Date',
          'Value Date',
          'Description',
          'Ref No./Cheque No.',
          'Debit',
          'Credit',
          'Balance',
        ],
        for (var i = 0; i < txns.length; i++)
          [
            dMonY(txns[i].date),
            dMonY(txns[i].date),
            txns[i].narration,
            null,
            txns[i].isCredit ? null : indianMoney(txns[i].debit!),
            txns[i].isCredit ? indianMoney(txns[i].credit!) : null,
            indianMoney(balances[i]),
          ],
        [],
        ['Computer generated statement. Please do not share your OTP.'],
      ]);
      final parsed = ImportDocument.open(bytes, 'statement.xlsx').parse();
      _expectExact(parsed, txns);
    });
  });

  group('duplicates', () {
    test('identical rows inside one statement are both kept', () {
      // Two real payments of the same amount to the same place on the same day.
      // They are two transactions; neither is a duplicate of the other.
      final parsed = ImportDocument.open(
        Uint8List.fromList(
          utf8.encode(
            [
              'Date,Narration,Debit,Credit,Balance',
              '02/01/2026,UPI/TEA STALL/stall@ybl/UPI,20.00,,980.00',
              '02/01/2026,UPI/TEA STALL/stall@ybl/UPI,20.00,,960.00',
              '03/01/2026,NEFT SALARY ACME,,5000.00,5960.00',
            ].join('\r\n'),
          ),
        ),
        'statement.csv',
      ).parse();
      expect(parsed.transactions, hasLength(3));
      // Only the standing question about day/month order may be asked.
      expect(
        parsed.transactions.expand(
          (t) => t.reviewReasons.where((r) => !r.contains('day/month order')),
        ),
        isEmpty,
      );
      final session = TransactionImportSession(
        fileDigest: 'file',
        importSource: 'csv',
        statement: parsed,
      );
      expect(session.rowKey(0), isNot(session.rowKey(1)));
    });

    test(
      'the same file read twice has the same keys, so it is not imported twice',
      () {
        final bytes = _build(_cases.first, txns, 50000000);
        ParsedStatement read() =>
            ImportDocument.open(bytes, 'statement.csv').parse();
        final a = TransactionImportSession(
          fileDigest: ImportDocument.open(bytes, 'statement.csv').digest,
          importSource: 'csv',
          statement: read(),
        );
        final b = TransactionImportSession(
          fileDigest: ImportDocument.open(bytes, 'statement.csv').digest,
          importSource: 'csv',
          statement: read(),
        );
        expect(
          [for (var i = 0; i < a.rows.length; i++) a.rowKey(i)],
          [for (var i = 0; i < b.rows.length; i++) b.rowKey(i)],
        );
        expect({
          for (var i = 0; i < a.rows.length; i++) a.rowKey(i),
        }, hasLength(txns.length));
      },
    );
  });

  group('a table that cannot be proven is never imported as certain', () {
    final hdfc = _cases.first;
    List<String> lines(Uint8List b) => utf8.decode(b).trimRight().split('\r\n');
    Uint8List join(List<String> l) =>
        Uint8List.fromList(utf8.encode('${l.join('\r\n')}\r\n'));

    test('a row missing from the file is flagged on the row after the gap', () {
      final l = lines(_build(hdfc, txns, 50000000))..removeAt(1 + 10);
      final parsed = ImportDocument.open(join(l), 'statement.csv').parse();
      expect(parsed.transactions, hasLength(txns.length - 1));
      final flagged = [
        for (final t in parsed.transactions)
          if (t.reviewReasons.any((r) => r.contains('running balance'))) t,
      ];
      expect(flagged, hasLength(1));
      expect(parsed.warnings.join(' '), contains('running balance'));
    });

    test(
      'a balance that no longer follows is flagged, and so is one that cannot be read',
      () {
        for (final damage in <String Function(String)>[
          (b) => (double.parse(b) + 1).toStringAsFixed(2),
          (b) => '${b}1',
        ]) {
          final l = lines(_build(hdfc, txns, 50000000));
          final cells = l[1 + 6].split(',');
          cells[cells.length - 1] = damage(cells.last);
          l[1 + 6] = cells.join(',');
          final parsed = ImportDocument.open(join(l), 'statement.csv').parse();
          expect(
            parsed.transactions.where(
              (t) => t.reviewReasons.any((r) => r.contains('balance')),
            ),
            isNotEmpty,
          );
          expect(parsed.warnings.join(' '), contains('running balance'));
        }
      },
    );

    test('totals and closing-balance lines are not transactions', () {
      final l = lines(_build(hdfc, txns, 50000000))
        ..add('Total,,,,1470828.10,2025734.50,')
        ..add('Closing Balance,,,,,,902013.99')
        ..add('Statement generated on 11/11/2026');
      final parsed = ImportDocument.open(join(l), 'statement.csv').parse();
      _expectExact(parsed, txns);
      expect(parsed.warnings, isEmpty);
    });

    test('a signed amount with no balance to prove it says so', () {
      final parsed = ImportDocument.open(
        join(const [
          'Date,Description,Amount',
          '02/01/2026,UPI/ZOMATO/shop,-250.00',
          '03/01/2026,NEFT SALARY ACME,50000.00',
          '04/01/2026,UPI/IRCTC/shop,-1200.00',
        ]),
        'statement.csv',
      ).parse();
      expect(parsed.transactions, hasLength(3));
      expect(parsed.warnings.join(' '), contains('sign of the Amount'));
    });
  });
}
