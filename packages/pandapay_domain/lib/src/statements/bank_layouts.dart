import '../sms_v2/contract/enums.dart';
import '../sms_v2/ledger/statement_check.dart';

/// Readers for the two bank statement layouts the owner has: State Bank of India
/// (separate debit and credit columns, two dates per row) and ICICI Bank (one
/// amount column and a balance, no direction printed).
///
/// They take the text of a statement, one printed row per line, and give back
/// [StatementRow]s. Pure and tolerant of whitespace: amounts are read from the
/// right-hand end of each row, so the exact column spacing does not matter. They
/// read nothing they cannot prove: [BankStatementRead.check] runs the rows
/// against the statement's own running balance, so a misread digit or a dropped
/// row is caught before anything is imported.
///
/// Written from the layouts of real statements, tested only on invented text in
/// those layouts. How a given PDF library orders the words of a table is the
/// caller's concern; if it puts a row on several lines, the continuation lines
/// are appended to the row above.
final class BankStatementRead {
  const BankStatementRead({
    required this.issuerSlug,
    required this.rows,
    required this.skipped,
    this.accountMask,
    this.openingMinor,
    this.closingMinor,
    this.printedDebitMinor,
    this.printedCreditMinor,
    this.printedDebitCount,
    this.printedCreditCount,
  });

  /// `sbi` or `icici`.
  final String issuerSlug;

  /// The last digits of the account number as printed, when the statement
  /// prints one.
  final String? accountMask;

  /// In printed order.
  final List<StatementRow> rows;

  /// Lines that began like a row but could not be read. Never silently dropped:
  /// a caller shows them.
  final List<String> skipped;

  final int? openingMinor;
  final int? closingMinor;
  final int? printedDebitMinor;
  final int? printedCreditMinor;
  final int? printedDebitCount;
  final int? printedCreditCount;

  /// The rows checked against what the statement prints about itself.
  StatementCheck get check => verifyStatement(
    rows,
    openingMinor: openingMinor,
    closingMinor: closingMinor,
    printedDebitMinor: printedDebitMinor,
    printedCreditMinor: printedCreditMinor,
    printedDebitCount: printedDebitCount,
    printedCreditCount: printedCreditCount,
  );
}

final RegExp _sbiRowStart = RegExp(r'^\s*(\d{2})/(\d{2})/(\d{4})\s+(\d{2})/(\d{2})/(\d{4})\s+(.*)$');
final RegExp _iciciRowStart = RegExp(r'^\s*(\d{1,6})\s+(\d{2})\.(\d{2})\.(\d{4})\s*(.*)$');
final RegExp _amount = RegExp(r'^\d[\d,]*\.\d\d$');
final RegExp _amountAnywhere = RegExp(r'\d[\d,]*\.\d\d');

/// Which layout [text] is, or null when it is neither. Decided by how many lines
/// look like a row of each layout, not by a bank name, so a statement whose
/// header the extractor mangled still reads.
String? detectBankLayout(String text) {
  var sbi = 0, icici = 0;
  for (final line in text.split('\n')) {
    if (_sbiRowStart.hasMatch(line)) sbi++;
    final m = _iciciRowStart.firstMatch(line);
    if (m != null && _amountAnywhere.allMatches(m.group(5)!).length >= 2) icici++;
  }
  if (sbi >= 2 && sbi > icici) return 'sbi';
  if (icici >= 2 && icici > sbi) return 'icici';
  return null;
}

/// Reads [text] as an SBI or ICICI statement, or returns null when it is neither.
BankStatementRead? readBankStatement(String text) => switch (detectBankLayout(text)) {
  'sbi' => readSbiStatement(text),
  'icici' => readIciciStatement(text),
  _ => null,
};

int? _paise(String printed) {
  final clean = printed.replaceAll(',', '');
  if (!RegExp(r'^\d+\.\d\d$').hasMatch(clean)) return null;
  final parts = clean.split('.');
  return int.parse(parts[0]) * 100 + int.parse(parts[1]);
}

DateTime? _date(String d, String m, String y) {
  final day = int.parse(d), month = int.parse(m), year = int.parse(y);
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day ? date : null;
}

String _tidy(String s) {
  var out = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // A page footer can run into the last row: "... 50,021.34CR" is a balance
  // printed with its sign, never part of a narration.
  final footer = RegExp(r'\s[\d,]+\.\d\dCR\b|\s[\d,]+\.\d\dDR\b').firstMatch(out);
  if (footer != null) out = out.substring(0, footer.start).trim();
  return out;
}

/// The digits that end the account number printed near "Account Number".
String? _accountMask(String text) {
  final m = RegExp(
    r'(?:account|a/c)\s*(?:no\.?|number|#)?\s*[:\-]?\s*([0-9Xx*•]{6,})',
    caseSensitive: false,
  ).firstMatch(text);
  if (m == null) return null;
  final digits = m.group(1)!.replaceAll(RegExp(r'\D'), '');
  return digits.length >= 4 ? digits.substring(digits.length - 4) : null;
}

int? _labelled(String text, RegExp label) {
  final m = label.firstMatch(text);
  if (m == null) return null;
  final amount = RegExp(r'\d[\d,]*\.\d\d').firstMatch(text.substring(m.end, m.end + 60 > text.length ? text.length : m.end + 60));
  return amount == null ? null : _paise(amount.group(0)!);
}

/// Opening and closing balance and the printed totals, where a labelled line
/// gives them. Printed row counts are not read: no label is known well enough,
/// and a loose pattern finds the word "credit" inside a narration.
({int? opening, int? closing, int? debits, int? credits}) _summary(String text) => (
  opening: _labelled(text, RegExp(r'(?:brought\s+forward|opening\s+balance)[^0-9\n]{0,30}', caseSensitive: false)),
  closing: _labelled(text, RegExp(r'closing\s+balance[^0-9\n]{0,30}', caseSensitive: false)),
  debits: _labelled(text, RegExp(r'total\s+debits?[^0-9\n]{0,30}', caseSensitive: false)),
  credits: _labelled(text, RegExp(r'total\s+credits?[^0-9\n]{0,30}', caseSensitive: false)),
);

final RegExp _sbiNoise = RegExp(
  r'^\s*(?:balance|page\s*no\.?\s*\d+|wdl\s+tfr|dep\s+tfr|wdl\s+clg|dep\s+clg|date\s+value\s+date.*|txn\s+date.*)\s*$',
  caseSensitive: false,
);
final RegExp _sbiStop = RegExp(
  r'statement\s+summary|brought\s+forward|please\s+do\s+not\s+share|computer\s+generated|if\s+your\s+account|date\s+of\s+statement',
  caseSensitive: false,
);

/// SBI: `dd/mm/yyyy dd/mm/yyyy  narration  ref  debit  credit  balance`, a dash
/// in the empty one of debit and credit. The narration may run over several
/// lines. Direction is printed, so it is read, not inferred.
BankStatementRead readSbiStatement(String text) {
  final rows = <StatementRow>[];
  final skipped = <String>[];
  final mask = _accountMask(text);
  String? narration;
  late DateTime date;
  int? amount, balance;
  Direction? direction;

  void flush() {
    if (narration == null) return;
    rows.add(
      StatementRow(
        index: rows.length,
        date: date,
        amountMinor: amount!,
        direction: direction,
        balanceMinor: balance,
        narration: _tidy(narration!),
        accountMask: mask,
        issuerSlug: 'sbi',
        accountId: 'sbi:${mask ?? ''}',
      ),
    );
    narration = null;
  }

  for (final raw in text.split('\n')) {
    final m = _sbiRowStart.firstMatch(raw);
    if (m != null) {
      flush();
      final d = _date(m.group(1)!, m.group(2)!, m.group(3)!);
      // A page footer can run into the last row of a page: drop a balance
      // printed with its sign ("4,15,548.85CR") and whatever follows it.
      final rowText = m.group(7)!.replaceFirst(RegExp(r'\s+[\d,]+\.\d\d\s?(?:CR|DR)\b.*$'), '');
      final tokens = rowText.trim().split(RegExp(r'\s+'));
      if (d == null || tokens.length < 4) {
        skipped.add(raw.trim());
        continue;
      }
      final b = tokens[tokens.length - 1], c = tokens[tokens.length - 2], dr = tokens[tokens.length - 3];
      final bal = _amount.hasMatch(b) ? _paise(b) : null;
      final cr = _amount.hasMatch(c) ? _paise(c) : null;
      final de = _amount.hasMatch(dr) ? _paise(dr) : null;
      final emptyC = c == '-', emptyD = dr == '-';
      if (bal == null || !((cr != null && emptyD) || (de != null && emptyC))) {
        skipped.add(raw.trim());
        continue;
      }
      date = d;
      balance = bal;
      amount = cr ?? de;
      direction = cr != null ? Direction.credit : Direction.debit;
      narration = tokens.sublist(0, tokens.length - 3).join(' ');
    } else if (narration != null) {
      if (_sbiStop.hasMatch(raw)) {
        flush();
      } else if (raw.trim().isNotEmpty && !_sbiNoise.hasMatch(raw)) {
        narration = '$narration ${raw.trim()}';
      }
    }
  }
  flush();
  final s = _summary(text);
  return BankStatementRead(
    issuerSlug: 'sbi',
    accountMask: mask,
    rows: rows,
    skipped: skipped,
    openingMinor: s.opening,
    closingMinor: s.closing,
    printedDebitMinor: s.debits,
    printedCreditMinor: s.credits,
  );
}

/// Table headers repeated on every page: a line made only of header words.
final RegExp _iciciNoise = RegExp(
  r'^\s*(?:s\.?\s*no\.?|transaction|date|remarks|withdrawals?|deposits?|cheque|number|amount|balance|\(inr\)|statement\s+of\s+transactions|your\s+base\s+branch.*|page\s+\d+(?:\s+of\s+\d+)?|\d{1,3}|\s)*$',
  caseSensitive: false,
);
final RegExp _iciciStop = RegExp(r'legends\s+for\s+transactions|sincer[el]y', caseSensitive: false);

/// ICICI: `serial  dd.mm.yyyy  remarks  amount  balance`. No debit/credit is
/// printed, so direction is left null and [verifyStatement] reads it from the
/// change in the running balance (the first row needs the opening balance).
BankStatementRead readIciciStatement(String text) {
  final rows = <StatementRow>[];
  final skipped = <String>[];
  final mask = _accountMask(text);
  String? narration;
  var stopped = false;
  late DateTime date;
  int? amount, balance;

  void flush() {
    if (narration == null) return;
    rows.add(
      StatementRow(
        index: rows.length,
        date: date,
        amountMinor: amount!,
        balanceMinor: balance,
        narration: _tidy(narration!),
        accountMask: mask,
        issuerSlug: 'icici',
        accountId: 'icici:${mask ?? ''}',
      ),
    );
    narration = null;
  }

  for (final raw in text.split('\n')) {
    if (_iciciStop.hasMatch(raw)) {
      flush();
      stopped = true;
      continue;
    }
    if (stopped) continue;
    final m = _iciciRowStart.firstMatch(raw);
    final amounts = m == null ? const <RegExpMatch>[] : _amountAnywhere.allMatches(m.group(5)!).toList();
    if (m != null && amounts.length >= 2) {
      flush();
      final d = _date(m.group(2)!, m.group(3)!, m.group(4)!);
      final rest = m.group(5)!;
      final a = _paise(amounts[amounts.length - 2].group(0)!);
      final b = _paise(amounts.last.group(0)!);
      if (d == null || a == null || b == null || a <= 0) {
        skipped.add(raw.trim());
        continue;
      }
      date = d;
      amount = a;
      balance = b;
      narration = rest.substring(0, amounts[amounts.length - 2].start);
    } else if (m != null) {
      skipped.add(raw.trim());
    } else if (narration != null && raw.trim().isNotEmpty && !_iciciNoise.hasMatch(raw)) {
      narration = '$narration ${raw.trim()}';
    }
  }
  flush();
  final s = _summary(text);
  return BankStatementRead(
    issuerSlug: 'icici',
    accountMask: mask,
    rows: rows,
    skipped: skipped,
    openingMinor: s.opening,
    closingMinor: s.closing,
    printedDebitMinor: s.debits,
    printedCreditMinor: s.credits,
  );
}
