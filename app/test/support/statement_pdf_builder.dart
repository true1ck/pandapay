// Draws bank-statement-style PDFs from invented transactions, so the whole
// import path (real PDF text layer, word positions, table reader, balance
// proof) can be tested across the layouts banks print, without keeping a real
// person's statement in the repository.
//
// A profile is modelled on how a bank's statement is commonly laid out (column
// order, header wording, date and money style, how empty cells print). Real
// statements vary by channel and year; a profile that passes here is evidence
// the reader copes with that kind of layout, not that a specific bank's file
// from last month will. The ICICI profile is modelled on a real statement that
// was checked by hand.
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:syncfusion_flutter_pdf/pdf.dart';

enum CellAlign { left, right }

class PdfColumn {
  const PdfColumn(
    this.key,
    this.header,
    this.x,
    this.width, {
    this.align = CellAlign.left,
  });

  /// serial, date, valueDate, ref, narration, debit, credit, amount, balance,
  /// branch.
  final String key;
  final List<String> header;
  final double x, width;
  final CellAlign align;
}

class Txn {
  const Txn(this.date, this.narration, {this.debit, this.credit});
  final DateTime date;
  final String narration;

  /// Paise. Exactly one of debit and credit is set.
  final int? debit, credit;
  int get amount => debit ?? credit!;
  bool get isCredit => credit != null;
}

class BankProfile {
  const BankProfile({
    required this.name,
    required this.titleLines,
    required this.columns,
    required this.dateFormat,
    required this.money,
    this.emptyCell = '',
    this.dateOffset = 0,
    this.headerEveryPage = true,
    this.newestFirst = false,
    this.fontSize = 8,
    this.lineHeight = 10,
    this.narrationChars = 38,
    this.rowGap = 0,
    this.balanceMoney,
    this.amountMarker,
    this.footerLines = const [],
    this.top = 40,
    this.centered = false,
    this.narrationFontSize,
    this.openingLabel,
    this.totalsLabel,
    this.summaryAbove = false,
  });

  final String name;
  final List<String> titleLines;
  final List<PdfColumn> columns;
  final String Function(DateTime) dateFormat;

  /// Paise to the text printed in an amount cell.
  final String Function(int paise) money;
  final String Function(int paise, bool credit)? balanceMoney;

  /// What an empty debit or credit cell prints ("", "-", "0.00").
  final String emptyCell;

  /// Points the date and amounts sit below a row's first narration line.
  final double dateOffset;
  final bool headerEveryPage;
  final bool newestFirst;
  final double fontSize, lineHeight, rowGap, top;
  final int narrationChars;

  /// For a single amount column: the marker printed after an amount.
  final String Function(bool credit)? amountMarker;
  final List<String> footerLines;

  /// Dates and amounts sit in the middle of a multi-line narration, not at its
  /// first line.
  final bool centered;

  /// A narration font smaller than the one the dates and amounts use.
  final double? narrationFontSize;

  /// A first row that is only the opening balance, as some banks print.
  final String? openingLabel;

  /// A last line of column totals with no date.
  final String? totalsLabel;

  /// A small summary (totals and closing balance) printed just above the table
  /// header, over the same columns.
  final bool summaryAbove;
}

String _indian(int paise) {
  final rupees = paise ~/ 100, p = (paise % 100).toString().padLeft(2, '0');
  final s = rupees.toString();
  if (s.length <= 3) return '$s.$p';
  final head = s.substring(0, s.length - 3), tail = s.substring(s.length - 3);
  final groups = <String>[];
  var h = head;
  while (h.length > 2) {
    groups.insert(0, h.substring(h.length - 2));
    h = h.substring(0, h.length - 2);
  }
  if (h.isNotEmpty) groups.insert(0, h);
  return '${groups.join(',')},$tail.$p';
}

String indianMoney(int paise) => _indian(paise);
String plainMoney(int paise) =>
    '${paise ~/ 100}.${(paise % 100).toString().padLeft(2, '0')}';

const _mon = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
String two(int v) => v.toString().padLeft(2, '0');
String dmyDots(DateTime d) => '${two(d.day)}.${two(d.month)}.${d.year}';
String dmySlash(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';
String dmySlash2(DateTime d) =>
    '${two(d.day)}/${two(d.month)}/${two(d.year % 100)}';
String dmyDash(DateTime d) => '${two(d.day)}-${two(d.month)}-${d.year}';
String dMonY(DateTime d) => '${d.day} ${_mon[d.month - 1]} ${d.year}';
String ddMonY(DateTime d) => '${two(d.day)} ${_mon[d.month - 1]} ${d.year}';
String ddMonDashY(DateTime d) => '${two(d.day)}-${_mon[d.month - 1]}-${d.year}';

/// Running balances for [txns] in the order given, from [opening].
List<int> balancesFor(List<Txn> txns, int opening) {
  var b = opening;
  return [for (final t in txns) b += t.isCredit ? t.credit! : -t.debit!];
}

List<String> _wrap(String text, int chars) {
  final out = <String>[];
  var line = '';
  for (var word in text.split(' ')) {
    while (word.length > chars) {
      // A long reference breaks mid-token, as banks' narrations do.
      if (line.isNotEmpty) {
        out.add(line);
        line = '';
      }
      out.add(word.substring(0, chars));
      word = word.substring(chars);
    }
    if (line.isEmpty) {
      line = word;
    } else if (line.length + 1 + word.length <= chars) {
      line = '$line $word';
    } else {
      out.add(line);
      line = word;
    }
  }
  if (line.isNotEmpty) out.add(line);
  return out.isEmpty ? [''] : out;
}

/// Invented transactions with narrations in the shapes Indian banks print.
List<Txn> sampleTransactions({int count = 40, int seed = 7, int year = 2026}) {
  final r = Random(seed);
  const people = [
    'ASHA VERMA',
    'RAHUL NAIR',
    'MEERA IYER',
    'KABIR SHAH',
    'LATA DESAI',
  ];
  const shops = [
    'BIGBASKET',
    'SWIGGY',
    'ZOMATO',
    'AMAZON PAY',
    'IRCTC',
    'UBER INDIA',
  ];
  String digits(int n) => List.generate(n, (_) => r.nextInt(10)).join();
  String hash(int n) {
    const c = 'abcdef0123456789';
    return List.generate(n, (_) => c[r.nextInt(c.length)]).join();
  }

  final out = <Txn>[];
  var day = DateTime(year, 1, 2);
  for (var i = 0; i < count; i++) {
    day = day.add(Duration(days: r.nextInt(5)));
    switch (i % 8) {
      case 0:
        out.add(
          Txn(
            day,
            'UPI/${people[r.nextInt(5)]}/user${r.nextInt(99)}@okhdfc/UPI/HDFC BANK/${digits(12)}/HDF${hash(28)}',
            credit: (r.nextInt(900) + 100) * 100,
          ),
        );
      case 1:
        out.add(
          Txn(
            day,
            'UPI/${shops[r.nextInt(6)]}/shop@ybl/UPI Paymen/Yes Bank/${digits(12)}/YBL${hash(28)}',
            debit: (r.nextInt(2400) + 60) * 100 + r.nextInt(100),
          ),
        );
      case 2:
        out.add(
          Txn(
            day,
            'NEFT-${hash(10).toUpperCase()}-ACME TECHNOLOGIES-SALARY',
            credit: (r.nextInt(40) + 40) * 100000,
          ),
        );
      case 3:
        out.add(
          Txn(
            day,
            'IMPS/P2A/${digits(12)}/${people[r.nextInt(5)]}',
            debit: (r.nextInt(300) + 5) * 100 * 5,
          ),
        );
      case 4:
        out.add(
          Txn(
            day,
            'ATM WDL/CASH ${digits(6)} BICHOLIM',
            debit: (r.nextInt(8) + 1) * 100000,
          ),
        );
      case 5:
        out.add(
          Txn(
            day,
            'Int on FD/RD XXX${digits(4)} Tds:0. Int:${r.nextInt(400) + 50}',
            credit: (r.nextInt(400) + 50) * 100,
          ),
        );
      case 6:
        out.add(
          Txn(
            day,
            'BIL/INFT/${digits(12)}/CC BillPay-${digits(4)}/Self',
            debit: (r.nextInt(9000) + 500) * 100 + r.nextInt(100),
          ),
        );
      default:
        out.add(
          Txn(
            day,
            'ACH D- BAJAJ FINANCE-${digits(8)} EMI',
            debit: (r.nextInt(70) + 10) * 10000,
          ),
        );
    }
  }
  return out;
}

/// Builds the PDF. [omit] leaves rows out of the drawing but keeps their effect
/// on the printed balances, which is what a dropped row looks like.
Uint8List buildStatementPdf(
  BankProfile p,
  List<Txn> txns, {
  required int opening,
  Set<int> omit = const {},
}) {
  final balances = balancesFor(txns, opening);
  final order = [for (var i = 0; i < txns.length; i++) i];
  if (p.newestFirst) order.sort((a, b) => b.compareTo(a));
  final doc = PdfDocument();
  doc.pageSettings.size = PdfPageSize.a4;
  doc.pageSettings.margins.all = 0;
  final font = PdfStandardFont(PdfFontFamily.helvetica, p.fontSize);
  final bold = PdfStandardFont(
    PdfFontFamily.helvetica,
    p.fontSize,
    style: PdfFontStyle.bold,
  );

  void text(
    PdfPage page,
    String s,
    double x,
    double y,
    double w, {
    CellAlign align = CellAlign.left,
    PdfFont? f,
  }) {
    if (s.isEmpty) return;
    page.graphics.drawString(
      s,
      f ?? font,
      bounds: Rect.fromLTWH(x, y, w, p.lineHeight + 2),
      format: PdfStringFormat(
        alignment: align == CellAlign.right
            ? PdfTextAlignment.right
            : PdfTextAlignment.left,
        wordWrap: PdfWordWrapType.none,
      ),
    );
  }

  var page = doc.pages.add();
  var pageNo = 1;
  var y = p.top;
  for (final line in p.titleLines) {
    text(page, line, 30, y, 520, f: bold);
    y += p.lineHeight + 2;
  }
  if (p.summaryAbove) {
    final deb = p.columns.where((c) => c.key == 'debit' || c.key == 'amount');
    final bal = p.columns.firstWhere((c) => c.key == 'balance');
    final totalDebit = txns
        .where((t) => !t.isCredit)
        .fold(0, (a, t) => a + t.debit!);
    final totalCredit = txns
        .where((t) => t.isCredit)
        .fold(0, (a, t) => a + t.credit!);
    if (deb.isNotEmpty) {
      text(
        page,
        'Total Debits',
        deb.first.x,
        y,
        deb.first.width,
        align: deb.first.align,
        f: bold,
      );
      text(
        page,
        p.money(totalDebit),
        deb.first.x,
        y + p.lineHeight,
        deb.first.width,
        align: deb.first.align,
      );
    }
    final cred = p.columns.where((c) => c.key == 'credit');
    if (cred.isNotEmpty) {
      text(
        page,
        'Total Credits',
        cred.first.x,
        y,
        cred.first.width,
        align: cred.first.align,
        f: bold,
      );
      text(
        page,
        p.money(totalCredit),
        cred.first.x,
        y + p.lineHeight,
        cred.first.width,
        align: cred.first.align,
      );
    }
    text(
      page,
      'Closing Balance',
      bal.x,
      y,
      bal.width,
      align: bal.align,
      f: bold,
    );
    text(
      page,
      p.money(balances.last),
      bal.x,
      y + p.lineHeight,
      bal.width,
      align: bal.align,
    );
    y += p.lineHeight * 2 + 6;
  } else {
    y += 12;
  }

  double drawHeader(PdfPage pg, double top) {
    final maxLines = p.columns.map((c) => c.header.length).reduce(max);
    for (final c in p.columns) {
      for (var i = 0; i < c.header.length; i++) {
        text(
          pg,
          c.header[i],
          c.x,
          top + i * p.lineHeight,
          c.width,
          align: c.align,
          f: bold,
        );
      }
    }
    return top + maxLines * p.lineHeight + 6;
  }

  y = drawHeader(page, y);
  const bottom = 770.0;

  if (p.openingLabel != null && txns.isNotEmpty) {
    final dateCol = p.columns.firstWhere((c) => c.key == 'date');
    final narr = p.columns.firstWhere((c) => c.key == 'narration');
    final bal = p.columns.firstWhere((c) => c.key == 'balance');
    text(
      page,
      p.dateFormat(txns.first.date),
      dateCol.x,
      y + p.dateOffset,
      dateCol.width,
    );
    text(page, p.openingLabel!, narr.x, y, narr.width);
    text(
      page,
      p.balanceMoney != null
          ? p.balanceMoney!(opening, true)
          : p.money(opening),
      bal.x,
      y + p.dateOffset,
      bal.width,
      align: bal.align,
    );
    y += p.lineHeight;
  }

  for (final i in order) {
    if (omit.contains(i)) continue;
    final t = txns[i];
    // Wrap by what fits the column (capitals are about 0.62 em wide): a line
    // longer than its column is clipped by the PDF library, and a word that
    // is not in the file cannot be read back.
    final narrationCol = p.columns.firstWhere((c) => c.key == 'narration');
    final fits = (narrationCol.width / (p.fontSize * 0.62)).floor();
    final lines = _wrap(
      t.narration,
      p.narrationChars < fits ? p.narrationChars : fits,
    );
    final height = lines.length * p.lineHeight + p.rowGap;
    if (y + height > bottom) {
      for (final f in p.footerLines) {
        text(page, f.replaceAll('{n}', '$pageNo'), 30, 800, 500);
      }
      page = doc.pages.add();
      pageNo++;
      y = p.top;
      if (p.headerEveryPage) y = drawHeader(page, y);
    }
    final amountY =
        y + (p.centered ? (lines.length - 1) * p.lineHeight / 2 : p.dateOffset);
    for (final c in p.columns) {
      switch (c.key) {
        case 'serial':
          text(page, '${i + 1}', c.x, amountY, c.width, align: c.align);
        case 'date':
          text(page, p.dateFormat(t.date), c.x, amountY, c.width);
        case 'valueDate':
          text(page, p.dateFormat(t.date), c.x, amountY, c.width);
        case 'ref':
          break;
        case 'narration':
          for (var k = 0; k < lines.length; k++) {
            text(
              page,
              lines[k],
              c.x,
              y + k * p.lineHeight,
              c.width,
              f: p.narrationFontSize == null
                  ? null
                  : PdfStandardFont(
                      PdfFontFamily.helvetica,
                      p.narrationFontSize!,
                    ),
            );
          }
        case 'debit':
          text(
            page,
            t.isCredit ? p.emptyCell : p.money(t.debit!),
            c.x,
            amountY,
            c.width,
            align: c.align,
          );
        case 'credit':
          text(
            page,
            t.isCredit ? p.money(t.credit!) : p.emptyCell,
            c.x,
            amountY,
            c.width,
            align: c.align,
          );
        case 'amount':
          text(
            page,
            '${p.money(t.amount)}${p.amountMarker?.call(t.isCredit) ?? ''}',
            c.x,
            amountY,
            c.width,
            align: c.align,
          );
        case 'balance':
          final b = balances[i];
          text(
            page,
            p.balanceMoney != null
                ? p.balanceMoney!(b.abs(), b >= 0)
                : p.money(b),
            c.x,
            amountY,
            c.width,
            align: c.align,
          );
        case 'branch':
          text(page, '4821', c.x, amountY, c.width);
      }
    }
    y += height;
  }
  if (p.totalsLabel != null) {
    final narr = p.columns.firstWhere((c) => c.key == 'narration');
    text(page, p.totalsLabel!, narr.x, y + 4, narr.width, f: bold);
    for (final c in p.columns) {
      if (c.key == 'debit') {
        text(
          page,
          p.money(
            txns.where((t) => !t.isCredit).fold(0, (a, t) => a + t.debit!),
          ),
          c.x,
          y + 4,
          c.width,
          align: c.align,
          f: bold,
        );
      }
      if (c.key == 'credit') {
        text(
          page,
          p.money(
            txns.where((t) => t.isCredit).fold(0, (a, t) => a + t.credit!),
          ),
          c.x,
          y + 4,
          c.width,
          align: c.align,
          f: bold,
        );
      }
    }
  }
  for (final f in p.footerLines) {
    text(page, f.replaceAll('{n}', '$pageNo'), 30, 800, 500);
  }
  final bytes = Uint8List.fromList(doc.saveSync());
  doc.dispose();
  return bytes;
}
