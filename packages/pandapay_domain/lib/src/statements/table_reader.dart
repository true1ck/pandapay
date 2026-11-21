import '../sms_v2/contract/enums.dart';
import '../sms_v2/ledger/statement_check.dart';
import 'bank_layouts.dart';

/// One word of a PDF page and where it sits, in PDF points (y grows downwards).
///
/// This is all the table reader needs from a PDF library, so it stays pure Dart
/// and testable without a PDF. Words are given in the order the PDF draws them,
/// which for a bank statement is row by row.
final class PdfWord {
  const PdfWord({
    required this.page,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.text,
    this.fontSize = 0,
  });

  final int page;
  final double left, top, right, bottom;
  final String text;

  /// 0 when the library does not say.
  final double fontSize;

  double get height => bottom - top;
  double get midY => (top + bottom) / 2;

  PdfWord withText(String value) => PdfWord(
    page: page,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    text: value,
    fontSize: fontSize,
  );
}

/// Reads a bank statement table from positioned words.
///
/// A PDF library's plain text puts a table cell on a line of its own and forgets
/// which column an amount was in, so a row cannot be rebuilt from it and a
/// debit cannot be told from a credit. Positions can: the amounts of one column
/// line up at one edge, and the header above them names the column.
///
/// The reader works from the data. It finds the dates (a column of them at one
/// x position), the amounts (columns of them at one edge), names each column from
/// the header words over it, and starts a row at each date. Debit and credit come
/// from the column, the balance from its column, and [BankStatementRead.check]
/// then runs every row against the running balance, so a row it read wrongly is
/// flagged and never imported as if it were certain.
///
/// It answers null, and the caller tries something else, when the words are not a
/// table it can prove: no date column, no amount column, or no way to tell what a
/// column holds. It never guesses a column.
///
/// Dates are read day first (Indian banks) unless a date in the statement can only
/// be month first.
BankStatementRead? readStatementTable(List<PdfWord> input) {
  final words = <PdfWord>[
    for (final w in input)
      if (w.text.trim().isNotEmpty) w.withText(w.text.trim()),
  ];
  if (words.length < 12) return null;

  final byPage = <int, List<int>>{};
  for (var i = 0; i < words.length; i++) {
    byPage.putIfAbsent(words[i].page, () => []).add(i);
  }
  final pages = byPage.keys.toList()..sort();

  final consumed = <int>{};
  final unreadPages = <int>[];
  final accs = <_Acc>[];
  _Layout? previous;
  _Layout? firstLayout;

  // Calibrate the amount columns on the richest page first; short pages reuse
  // them when their amounts line up.
  _Layout? reference;
  for (final page in pages) {
    final own = _layoutPage(words, byPage[page]!, null);
    if (own != null &&
        (reference == null || own.amountCount > reference.amountCount)) {
      reference = own;
    }
  }

  for (final page in pages) {
    final idx = byPage[page]!;
    final layout =
        _layoutPage(words, idx, previous, reference: reference) ??
        (previous == null ? null : _carry(words, idx, previous));
    if (layout == null) {
      // No table on this page. If it prints a column of dates it is a table we
      // could not read, and the caller must say its transactions are missing.
      final dates = _findDates(words, idx);
      if (_clusters<_Date>(
        dates,
        (d) => d.left,
        3.0,
      ).any((c) => c.length >= 2)) {
        unreadPages.add(page + 1);
      }
      continue;
    }
    firstLayout ??= layout;
    previous = layout;
    _collectRows(words, idx, layout, accs, consumed);
  }
  if (firstLayout == null || accs.isEmpty) return null;

  // Day first unless some date can only be month first.
  var monthFirst = false, dayFirst = false;
  for (final a in accs) {
    if (a.date.fixed) continue;
    if (a.date.a > 12) dayFirst = true;
    if (a.date.b > 12) monthFirst = true;
  }
  final useMonthFirst = monthFirst && !dayFirst;

  final rows = <StatementRow>[];
  final skipped = <String>[];
  int? opening;
  // Who and which account: the first page's own text, wherever the PDF draws
  // it (a title can be drawn after the table), minus what the table consumed.
  final headLines = _lines(words, [
    for (final i in byPage[pages.first]!)
      if (!consumed.contains(i)) i,
  ]);
  final mask = _accountMask(headLines.join('\n'));
  final issuer = _issuerOf(headLines.join(' '));
  for (final a in accs) {
    final date = _resolveDate(a.date, useMonthFirst);
    final built = a.build();
    if (built.openingOnly) {
      opening ??= built.balance;
      continue;
    }
    if (date == null || built.amount == null || built.problem != null) {
      skipped.add(a.rawText(built.problem));
      continue;
    }
    if (built.amount == 0) continue;
    rows.add(
      StatementRow(
        index: rows.length,
        date: date,
        amountMinor: built.amount!,
        direction: built.direction,
        balanceMinor: built.balance,
        narration: _tidy(a.narration.map((w) => w.text).join(' ')),
        accountMask: mask,
        issuerSlug: issuer,
        accountId: '${issuer ?? 'bank'}:${mask ?? ''}',
      ),
    );
  }
  if (rows.isEmpty) return null;

  final tail = _lines(words, [
    for (var i = 0; i < words.length; i++)
      if (!consumed.contains(i)) i,
  ]);
  final s = _summaryLines(tail);
  return BankStatementRead(
    issuerSlug: issuer,
    accountMask: mask,
    rows: rows,
    skipped: skipped,
    unreadPages: unreadPages,
    openingMinor: opening ?? s.opening,
    closingMinor: s.closing,
    printedDebitMinor: s.debits,
    printedCreditMinor: s.credits,
  );
}

// ---------------------------------------------------------------- dates -----

final RegExp _numericDate = RegExp(
  r'^(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})$',
);
final RegExp _isoDate = RegExp(r'^(\d{4})[./-](\d{1,2})[./-](\d{1,2})$');
final RegExp _namedDate = RegExp(
  r'^(\d{1,2})[ -]([A-Za-z]{3,9})[ ,.-]+(\d{4}|\d{2})$',
);
final RegExp _namedDateUs = RegExp(
  r'^([A-Za-z]{3,9})[ -](\d{1,2}),?[ -](\d{4}|\d{2})$',
);

const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'sept': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

int? _monthNumber(String name) {
  final k = name.toLowerCase();
  return _months[k.length > 3 && k != 'sept' ? k.substring(0, 3) : k];
}

int _year(String y) {
  final v = int.parse(y);
  return y.length == 2 ? 2000 + v : v;
}

final class _Date {
  const _Date(
    this.first,
    this.last,
    this.a,
    this.b,
    this.y,
    this.fixed,
    this.left,
    this.right,
    this.top,
    this.bottom,
  );
  final int first, last;
  final int a, b, y;

  /// True when `a` is the day and `b` the month for certain.
  final bool fixed;
  final double left, right, top, bottom;
}

_Date? _matchDate(String text, int first, int last, PdfWord from, PdfWord to) {
  int? a, b, y;
  var fixed = false;
  var m = _isoDate.firstMatch(text);
  if (m != null) {
    y = int.parse(m.group(1)!);
    b = int.parse(m.group(2)!);
    a = int.parse(m.group(3)!);
    fixed = true;
  } else if ((m = _numericDate.firstMatch(text)) != null) {
    a = int.parse(m!.group(1)!);
    b = int.parse(m.group(2)!);
    y = _year(m.group(3)!);
  } else if ((m = _namedDate.firstMatch(text)) != null) {
    a = int.parse(m!.group(1)!);
    b = _monthNumber(m.group(2)!);
    y = _year(m.group(3)!);
    fixed = true;
  } else if ((m = _namedDateUs.firstMatch(text)) != null) {
    b = _monthNumber(m!.group(1)!);
    a = int.parse(m.group(2)!);
    y = _year(m.group(3)!);
    fixed = true;
  }
  if (a == null || b == null || y == null) return null;
  if (y < 1990 || y > 2100) return null;
  if (fixed) {
    if (a < 1 || a > 31 || b < 1 || b > 12) return null;
  } else {
    if (a < 1 || b < 1 || a > 31 || b > 31 || (a > 12 && b > 12)) return null;
  }
  return _Date(
    first,
    last,
    a,
    b,
    y,
    fixed,
    from.left,
    to.right,
    from.top,
    from.bottom > to.bottom ? from.bottom : to.bottom,
  );
}

DateTime? _resolveDate(_Date d, bool monthFirst) {
  final day = d.fixed || !monthFirst ? d.a : d.b;
  final month = d.fixed || !monthFirst ? d.b : d.a;
  final date = DateTime.utc(d.y, month, day);
  return date.year == d.y && date.month == month && date.day == day
      ? date
      : null;
}

bool _sameLine(PdfWord a, PdfWord b) =>
    (a.midY - b.midY).abs() <=
    (a.height < b.height ? a.height : b.height) * 0.5 + 0.5;

/// Dates in stream order, a date of several words ("01 Jan 2026") counted once.
List<_Date> _findDates(List<PdfWord> words, List<int> idx) {
  final out = <_Date>[];
  var p = 0;
  while (p < idx.length) {
    _Date? found;
    var used = 1;
    for (var k = 1; k <= 3 && p + k <= idx.length; k++) {
      if (k > 1) {
        final prev = words[idx[p + k - 2]], cur = words[idx[p + k - 1]];
        if (!_sameLine(prev, cur) ||
            cur.left - prev.right > 12 ||
            cur.left < prev.left) {
          break;
        }
      }
      final text = [
        for (var q = 0; q < k; q++) words[idx[p + q]].text,
      ].join(' ');
      final d = _matchDate(
        text,
        idx[p],
        idx[p + k - 1],
        words[idx[p]],
        words[idx[p + k - 1]],
      );
      if (d != null) {
        found = d;
        used = k;
        break;
      }
    }
    if (found != null) {
      out.add(found);
      p += used;
    } else {
      p++;
    }
  }
  return out;
}

// -------------------------------------------------------------- columns -----

enum _Col { date, valueDate, debit, credit, amount, balance, drcr, other }

/// What a column's header says it holds, from the words printed over it.
_Col _headerKind(String raw) {
  final t = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z/ ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return _Col.other;
  if (RegExp(r'\bbal(ance)?\b').hasMatch(t)) return _Col.balance;
  final hasDebit = RegExp(r'\b(withdrawals?|wdl|debits?|dr)\b').hasMatch(t);
  final hasCredit = RegExp(r'\b(deposits?|credits?|cr|dep)\b').hasMatch(t);
  if (hasDebit && hasCredit) {
    // One column for both ("Withdrawal (Dr) / Deposit (Cr)") holds the amount
    // and marks the side on each row; a bare "Dr / Cr" only marks the side.
    return RegExp(
          r'\b(withdrawals?|deposits?|debits?|credits?|amount|amt)\b',
        ).hasMatch(t)
        ? _Col.amount
        : _Col.drcr;
  }
  if (hasDebit) return _Col.debit;
  if (hasCredit) return _Col.credit;
  if (RegExp(r'\b(value|val)\b').hasMatch(t) &&
      RegExp(r'\b(date|dt)\b').hasMatch(t)) {
    return _Col.valueDate;
  }
  if (RegExp(r'\b(date|dt)\b').hasMatch(t)) return _Col.date;
  if (RegExp(r'\b(amount|amt)\b').hasMatch(t)) return _Col.amount;
  return _Col.other;
}

/// A word that can belong to a table header, so the words printed above the
/// first row can be told from a title or an address.
final RegExp _notHeaderChar = RegExp(r'[^a-z/₹]');

bool _isHeaderWord(String text) {
  final t = text.toLowerCase().replaceAll(_notHeaderChar, '');
  if (t.isEmpty) return false;
  const exact = {
    'no',
    'number',
    'inr',
    'rs',
    'type',
    'code',
    'branch',
    'mode',
    'id',
    's',
    'sl',
    'sr',
    'and',
    'of',
    '/',
    '₹',
    'dr',
    'cr',
    'closing',
    'bal',
    'running',
    'available',
  };
  if (exact.contains(t)) return true;
  const stems = [
    'date',
    'dt',
    'txn',
    'tran',
    'value',
    'narrat',
    'descrip',
    'particul',
    'remark',
    'detail',
    'chq',
    'cheq',
    'ref',
    'withdraw',
    'deposit',
    'debit',
    'credit',
    'balanc',
    'amount',
    'amt',
    'utr',
    'instrument',
  ];
  return stems.any(t.contains);
}

final RegExp _amountRe = RegExp(
  r'^\(?-?(\d[\d,]*\.\d{2})\)?(?:\(?(cr|dr)\)?)?$',
  caseSensitive: false,
);

/// An amount as a PDF prints it, with its sign marker split off.
({int paise, String? flag, int suffixChars, bool negative})? _readAmount(
  String text,
) {
  final m = _amountRe.firstMatch(text);
  if (m == null) return null;
  final parts = m.group(1)!.replaceAll(',', '').split('.');
  final flag = m.group(2)?.toLowerCase();
  return (
    paise: int.parse(parts[0]) * 100 + int.parse(parts[1]),
    flag: flag,
    suffixChars: text.length - (text.indexOf(m.group(1)!) + m.group(1)!.length),
    negative:
        text.contains('-') || (text.startsWith('(') && text.endsWith(')')),
  );
}

final RegExp _markerRe = RegExp(r'^(cr|dr|c|d)\.?$', caseSensitive: false);
final RegExp _timeRe = RegExp(
  r'^\d{1,2}:\d{2}(:\d{2})?$|^(am|pm)$',
  caseSensitive: false,
);

double _effRight(PdfWord w, int suffixChars) {
  if (suffixChars == 0 || w.text.isEmpty) return w.right;
  return w.right - (w.right - w.left) / w.text.length * suffixChars;
}

List<List<T>> _clusters<T>(List<T> items, double Function(T) key, double tol) {
  final sorted = [...items]..sort((a, b) => key(a).compareTo(key(b)));
  final out = <List<T>>[];
  for (final it in sorted) {
    if (out.isNotEmpty && key(it) - key(out.last.last) <= tol) {
      out.last.add(it);
    } else {
      out.add([it]);
    }
  }
  return out;
}

final class _NumCol {
  _NumCol(this.kind, this.edge, this.rightAligned, this.minLeft, this.maxRight);
  final _Col kind;
  final double edge;
  final bool rightAligned;
  final double minLeft, maxRight;
}

final class _Layout {
  _Layout({
    required this.dateLeft,
    required this.dateRight,
    required this.valueLeft,
    required this.numeric,
    required this.amountCount,
    required this.firstAnchorWord,
    required this.headerWords,
    required this.anchorFirsts,
    required this.otherDateWords,
    required this.dates,
    required this.carried,
  });
  final double dateLeft, dateRight;

  /// Where the value-date column starts, when the table has one.
  final double? valueLeft;
  final List<_NumCol> numeric;

  /// How many amount-like words the page calibrated on.
  final int amountCount;
  final int firstAnchorWord;
  final Set<int> headerWords;

  /// First-word index of every row-starting date.
  final Set<int> anchorFirsts;

  /// Every word of a date that does not start a row (a value date).
  final Set<int> otherDateWords;
  final Map<int, _Date> dates;
  final bool carried;
}

/// Builds the layout of one page from its own header and data, or null when the
/// page does not hold a table that can be proven.
_Layout? _layoutPage(
  List<PdfWord> words,
  List<int> idx,
  _Layout? previous, {
  _Layout? reference,
}) {
  final dates = _findDates(words, idx);
  if (dates.length < 2 && previous == null) return null;

  // Dates of the table sit in a column: one x position.
  final dateClusters =
      _clusters<_Date>(
          dates,
          (d) => d.left,
          3.0,
        ).where((c) => c.length >= (previous == null ? 2 : 1)).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  if (dateClusters.isEmpty) return null;
  final top = dateClusters.first.length;
  final dateCols =
      dateClusters.where((c) => c.length * 2 >= top).take(2).toList()
        ..sort((a, b) => a.first.left.compareTo(b.first.left));

  // The first row: the earliest-drawn date of the main column.
  List<_Date> pick(List<_Date> c) =>
      [...c]..sort((a, b) => a.first.compareTo(b.first));
  final main = pick(dateCols.first);
  final firstAnchor = main.first;

  // Header words: those that look like a header, drawn before the first row
  // and not far above it.
  final candidates = <int>[
    for (final i in idx)
      if (i < firstAnchor.first &&
          words[i].top >= firstAnchor.top - 90 &&
          _isHeaderWord(words[i].text))
        i,
  ];
  // Only the band of lines nearest the first row. A block above it (a summary of
  // totals, a title) is a different table and must not rename the columns.
  final lineTops = {for (final i in candidates) words[i].top.round()}.toList()
    ..sort((a, b) => b.compareTo(a));
  final keepTops = <int>{};
  int? lastTop;
  for (final t in lineTops) {
    if (lastTop != null && lastTop - t > 14) break;
    keepTops.add(t);
    lastTop = t;
  }
  final header = [
    for (final i in candidates)
      if (keepTops.contains(words[i].top.round())) i,
  ];

  // Amount-like words below the header, outside the dates.
  final dateWords = <int>{
    for (final d in dates)
      for (var i = d.first; i <= d.last; i++) i,
  };
  final amounts = <int>[
    for (final i in idx)
      if (i >= firstAnchor.first &&
          !dateWords.contains(i) &&
          _readAmount(words[i].text) != null)
        i,
  ];
  if (amounts.length < 2) return null;

  double effRight(int i) =>
      _effRight(words[i], _readAmount(words[i].text)!.suffixChars);

  // The columns calibrated on the richest page, when this page's amounts line up
  // with them. A short page has too few amounts to tell the alignment on its own
  // (two credits and five debits look as much like left-aligned as right-aligned
  // columns), so it takes its columns from the page that can tell.
  List<_NumCol>? reused;
  if (reference != null && reference.numeric.isNotEmpty) {
    final right = reference.numeric.first.rightAligned;
    var fit = 0;
    for (final i in amounts) {
      final e = right ? effRight(i) : words[i].left;
      if (reference.numeric.any((c) => (e - c.edge).abs() <= 5.0)) fit++;
    }
    if (fit >= amounts.length * 0.9) reused = reference.numeric;
  }

  var rightAligned = true;
  var chosen = <List<int>>[];
  if (reused == null) {
    final rightClusters = _clusters<int>(amounts, effRight, 3.0);
    final leftClusters = _clusters<int>(amounts, (i) => words[i].left, 3.0);
    // A column of amounts has at least two in it; a lone number in a narration
    // is not a column. A single amount still is one when a Debit, Credit,
    // Balance or Amount header sits right over it (a short statement with one
    // debit among its rows).
    bool headed(List<int> cluster) {
      final minL = cluster
          .map((i) => words[i].left)
          .reduce((a, b) => a < b ? a : b);
      final maxR = cluster
          .map((i) => words[i].right)
          .reduce((a, b) => a > b ? a : b);
      final text = [
        for (final h in header)
          if (words[h].right >= minL - 2 && words[h].left <= maxR + 2)
            words[h].text,
      ].join(' ');
      return const {
        _Col.debit,
        _Col.credit,
        _Col.balance,
        _Col.amount,
      }.contains(_headerKind(text));
    }

    List<List<int>> sig(List<List<int>> cs) =>
        cs.where((c) => c.length >= 2 || headed(c)).toList();
    final rs = sig(rightClusters), ls = sig(leftClusters);
    rightAligned = rs.isNotEmpty && (ls.isEmpty || rs.length <= ls.length);
    chosen = rightAligned ? rs : ls;
    if (chosen.isEmpty) return null;
  }

  // Name every column from the header words over it.
  final pieces = <List<_Piece>>[for (final _ in chosen) <_Piece>[]];
  final datePieces = <List<_Piece>>[for (final _ in dateCols) <_Piece>[]];
  for (final h in header) {
    final w = words[h];
    var best = -1;
    var bestOverlap = 0.0;
    for (var c = 0; c < chosen.length; c++) {
      final minL = chosen[c]
          .map((i) => words[i].left)
          .reduce((a, b) => a < b ? a : b);
      final maxR = chosen[c]
          .map((i) => words[i].right)
          .reduce((a, b) => a > b ? a : b);
      final o =
          (w.right < maxR ? w.right : maxR) - (w.left > minL ? w.left : minL);
      if (o > bestOverlap) {
        bestOverlap = o;
        best = c;
      }
    }
    var bestDate = -1;
    var dateOverlap = 0.0;
    for (var c = 0; c < dateCols.length; c++) {
      final minL = dateCols[c]
          .map((d) => d.left)
          .reduce((a, b) => a < b ? a : b);
      final maxR = dateCols[c]
          .map((d) => d.right)
          .reduce((a, b) => a > b ? a : b);
      final o =
          (w.right < maxR ? w.right : maxR) - (w.left > minL ? w.left : minL);
      if (o > dateOverlap) {
        dateOverlap = o;
        bestDate = c;
      }
    }
    if (best < 0 && bestDate < 0) {
      // Nearest column by centre, when close.
      double nearest = 45;
      final cx = (w.left + w.right) / 2;
      for (var c = 0; c < chosen.length; c++) {
        final mid =
            chosen[c]
                .map((i) => (words[i].left + words[i].right) / 2)
                .reduce((a, b) => a + b) /
            chosen[c].length;
        if ((mid - cx).abs() < nearest) {
          nearest = (mid - cx).abs();
          best = c;
        }
      }
    }
    if (best >= 0 && (bestDate < 0 || bestOverlap >= dateOverlap)) {
      pieces[best].add(_Piece(w.text, w.top, w.left));
    } else if (bestDate >= 0) {
      datePieces[bestDate].add(_Piece(w.text, w.top, w.left));
    }
  }
  String textOf(List<_Piece> ps) =>
      (ps..sort(
            (a, b) => a.top == b.top
                ? a.left.compareTo(b.left)
                : a.top.compareTo(b.top),
          ))
          .map((p) => p.text)
          .join(' ');

  final numeric = <_NumCol>[];
  if (reused != null) numeric.addAll(reused);
  for (var c = 0; c < chosen.length; c++) {
    final kind = _headerKind(textOf(pieces[c]));
    final minL = chosen[c]
        .map((i) => words[i].left)
        .reduce((a, b) => a < b ? a : b);
    final maxR = chosen[c]
        .map((i) => words[i].right)
        .reduce((a, b) => a > b ? a : b);
    final edge = rightAligned
        ? chosen[c].map(effRight).reduce((a, b) => a + b) / chosen[c].length
        : chosen[c].map((i) => words[i].left).reduce((a, b) => a + b) /
              chosen[c].length;
    numeric.add(_NumCol(kind, edge, rightAligned, minL, maxR));
  }
  // A column with no recognisable header could be anything: refuse rather than
  // guess which of the amounts is the money moved.
  if (reused == null) {
    final kinds = [for (final n in numeric) n.kind];
    final hasMoney =
        kinds.contains(_Col.debit) ||
        kinds.contains(_Col.credit) ||
        kinds.contains(_Col.amount);
    final hasBalance = kinds.contains(_Col.balance);
    if (!hasMoney) return null;
    if (!hasBalance &&
        !(kinds.contains(_Col.debit) && kinds.contains(_Col.credit))) {
      return null;
    }
    for (final k in [_Col.debit, _Col.credit, _Col.amount, _Col.balance]) {
      if (kinds.where((x) => x == k).length > 1) return null;
    }
  }

  // Which date column is the transaction date: not the one headed "value date".
  var txn = 0;
  if (dateCols.length == 2) {
    final names = [for (final p in datePieces) _headerKind(textOf(p))];
    if (names[0] == _Col.valueDate && names[1] != _Col.valueDate) txn = 1;
  }
  final txnCol = dateCols[txn];
  final anchors = pick(txnCol);
  // Only a second date column (a value date) is set aside. A date inside a
  // narration ("interest paid to 29-03-2026") is part of the narration.
  final valueCol = dateCols.length == 2 ? dateCols[1 - txn] : null;
  final otherDates = <int>{
    if (valueCol != null)
      for (final d in valueCol)
        for (var i = d.first; i <= d.last; i++) i,
  };
  return _Layout(
    dateLeft: txnCol.map((d) => d.left).reduce((a, b) => a < b ? a : b),
    dateRight: txnCol.map((d) => d.right).reduce((a, b) => a > b ? a : b),
    valueLeft: valueCol?.first.left,
    numeric: numeric,
    amountCount: amounts.length,
    firstAnchorWord: anchors.first.first,
    headerWords: header.toSet(),
    anchorFirsts: {for (final d in txnCol) d.first},
    otherDateWords: otherDates,
    dates: {for (final d in dates) d.first: d},
    carried: false,
  );
}

final class _Piece {
  _Piece(this.text, this.top, this.left);
  final String text;
  final double top, left;
}

/// A page with no header of its own (some banks print it once) reuses the
/// columns of the page before, when its dates sit in the same column.
_Layout? _carry(List<PdfWord> words, List<int> idx, _Layout previous) {
  final dates = _findDates(words, idx);
  final inColumn = [
    for (final d in dates)
      if ((d.left - previous.dateLeft).abs() <= 4) d,
  ]..sort((a, b) => a.first.compareTo(b.first));
  if (inColumn.isEmpty) return null;
  final inCol = {for (final d in inColumn) d.first};
  final valueLeft = previous.valueLeft;
  return _Layout(
    dateLeft: previous.dateLeft,
    dateRight: previous.dateRight,
    valueLeft: valueLeft,
    numeric: previous.numeric,
    amountCount: previous.amountCount,
    firstAnchorWord: inColumn.first.first,
    headerWords: const {},
    anchorFirsts: inCol,
    otherDateWords: {
      if (valueLeft != null)
        for (final d in dates)
          if ((d.left - valueLeft).abs() <= 4)
            for (var i = d.first; i <= d.last; i++) i,
    },
    dates: {for (final d in dates) d.first: d},
    carried: true,
  );
}

// ----------------------------------------------------------------- rows -----

final class _Amt {
  _Amt(this.paise, this.flag, this.negative, this.word);
  final int paise;
  String? flag;
  final bool negative;
  final PdfWord word;
}

final class _Built {
  const _Built({
    this.amount,
    this.direction,
    this.balance,
    this.problem,
    this.openingOnly = false,
  });
  final int? amount;
  final Direction? direction;
  final int? balance;
  final String? problem;
  final bool openingOnly;
}

final RegExp _openingRe = RegExp(
  r'opening\s+balance|brought\s+forward|\bb/?f\b|balance\s+b/?f',
  caseSensitive: false,
);

final class _Acc {
  _Acc(this.date, this.anchor);
  final _Date date;
  final PdfWord anchor;
  final List<PdfWord> narration = [];
  final Map<_Col, List<_Amt>> nums = {};
  double maxBottom = 0;

  void addNum(_Col kind, _Amt a) => nums.putIfAbsent(kind, () => []).add(a);

  /// Distinct non-empty values in a column, or the one value.
  ({int? value, bool clash}) one(_Col kind) {
    final list = nums[kind];
    if (list == null || list.isEmpty) return (value: null, clash: false);
    final values = {for (final a in list) a.paise};
    if (values.length > 1) return (value: null, clash: true);
    return (value: list.first.paise, clash: false);
  }

  _Amt? first(_Col kind) {
    final list = nums[kind];
    return list == null || list.isEmpty ? null : list.first;
  }

  _Built build() {
    final bal = one(_Col.balance);
    final deb = one(_Col.debit);
    final cre = one(_Col.credit);
    final amt = one(_Col.amount);
    if (bal.clash || deb.clash || cre.clash || amt.clash) {
      return const _Built(problem: 'two different numbers in one column');
    }
    final balAmt = first(_Col.balance);
    int? balance = bal.value;
    if (balance != null &&
        balAmt != null &&
        (balAmt.negative || balAmt.flag == 'dr')) {
      balance = -balance;
    }

    final hasMoneyCols =
        deb.value != null || cre.value != null || amt.value != null;
    if (!hasMoneyCols) {
      final text = narration.map((w) => w.text).join(' ');
      if (balance != null && _openingRe.hasMatch(text)) {
        return _Built(balance: balance, openingOnly: true);
      }
      return const _Built(problem: 'no amount');
    }
    if (deb.value != null || cre.value != null) {
      final d = deb.value ?? 0, c = cre.value ?? 0;
      if (d != 0 && c != 0) {
        return const _Built(problem: 'both a debit and a credit');
      }
      if (d == 0 && c == 0) return _Built(amount: 0, balance: balance);
      return _Built(
        amount: d != 0 ? d : c,
        direction: d != 0 ? Direction.debit : Direction.credit,
        balance: balance,
      );
    }
    final a = first(_Col.amount)!;
    Direction? dir;
    if (a.flag == 'cr' || a.flag == 'c') dir = Direction.credit;
    if (a.flag == 'dr' || a.flag == 'd') dir = Direction.debit;
    if (dir == null && a.negative) dir = Direction.debit;
    return _Built(amount: a.paise, direction: dir, balance: balance);
  }

  String rawText(String? problem) {
    final nums = this.nums.values
        .expand((l) => l)
        .map((a) => a.word.text)
        .join(' ');
    final base =
        '${date.a}/${date.b}/${date.y} ${narration.map((w) => w.text).join(' ')} $nums'
            .trim();
    return problem == null ? base : '$base ($problem)';
  }
}

final RegExp _stopLine = RegExp(
  r'^(legends?|sincerely|summary|disclaimer|notes?:?|page|total|closing|opening|brought|carried|\*+|end)$',
  caseSensitive: false,
);

void _collectRows(
  List<PdfWord> words,
  List<int> idx,
  _Layout layout,
  List<_Acc> accs,
  Set<int> consumed,
) {
  _Acc? open;
  _Amt? lastAmt;
  PdfWord? lastNarr;
  for (final i in idx) {
    if (i < layout.firstAnchorWord) continue;
    final w = words[i];
    if (layout.anchorFirsts.contains(i)) {
      final d = layout.dates[i]!;
      open = _Acc(d, w);
      accs.add(open);
      lastAmt = null;
      lastNarr = null;
      for (var k = d.first; k <= d.last; k++) {
        consumed.add(k);
      }
      continue;
    }
    if (layout.otherDateWords.contains(i)) {
      if (open != null) consumed.add(i);
      continue;
    }
    if (consumed.contains(i)) continue;
    if (open == null) continue;
    final anchor = open.anchor;
    // The page's serial-number column, left of the dates.
    if (w.right <= layout.dateLeft + 1) {
      consumed.add(i);
      continue;
    }
    // A time printed under the date.
    if (_timeRe.hasMatch(w.text) &&
        w.left < layout.dateRight + 30 &&
        w.right > layout.dateLeft - 5) {
      consumed.add(i);
      continue;
    }
    final amount = _readAmount(w.text);
    if (amount != null) {
      final eff = _effRight(w, amount.suffixChars);
      _NumCol? hit;
      for (final c in layout.numeric) {
        final e = c.rightAligned ? eff : w.left;
        if ((e - c.edge).abs() <= 5.0) {
          hit = c;
          break;
        }
      }
      if (hit != null) {
        if (w.top < anchor.top - 30 ||
            w.top > open.maxBottom.clamp(anchor.bottom, double.infinity) + 90) {
          // Far from this row: not its amount.
          continue;
        }
        final a = _Amt(amount.paise, amount.flag, amount.negative, w);
        open.addNum(hit.kind, a);
        lastAmt = a;
        consumed.add(i);
        continue;
      }
    }
    if (_markerRe.hasMatch(w.text) &&
        lastAmt != null &&
        _sameLine(lastAmt.word, w) &&
        w.left - lastAmt.word.right <= 14 &&
        w.left >= lastAmt.word.right - 1) {
      lastAmt.flag ??= w.text.toLowerCase().replaceAll('.', '');
      consumed.add(i);
      continue;
    }
    // Right of the last amount column: a branch code or a balance sign, not a
    // narration.
    if (layout.numeric.isNotEmpty) {
      final rightMost = layout.numeric
          .map((c) => c.maxRight)
          .reduce((a, b) => a > b ? a : b);
      if (w.left >= rightMost + 2) {
        consumed.add(i);
        continue;
      }
      final leftMost = layout.numeric
          .map((c) => c.minLeft)
          .reduce((a, b) => a < b ? a : b);
      if (w.left >= leftMost - 1) {
        consumed.add(i);
        continue;
      }
    }
    // Narration: keep it with the row only while it still looks like part of it.
    final ref = open.maxBottom == 0 ? anchor.bottom : open.maxBottom;
    // A narration keeps one font, which need not be the date's. Text in another
    // font, or set apart from the lines above it, is a footer, not narration.
    final narrationFont = open.narration.isEmpty
        ? w.fontSize
        : open.narration.first.fontSize;
    final sameFont =
        w.fontSize == 0 ||
        narrationFont == 0 ||
        (w.fontSize - narrationFont).abs() <= 1.0;
    final lineHeight = w.height > 0 ? w.height : 8.0;
    final gap = w.top - ref;
    final startsLine = lastNarr == null || (w.top - lastNarr.top).abs() > 2;
    final tooFar = gap > lineHeight * 2.2;
    // Cells centred on a long narration put the date below its first lines.
    final aboveRow = w.top < anchor.top - lineHeight * 6;
    // A line that opens like a footer, after a visible gap. Without the gap it
    // is a wrapped narration that happens to begin with such a word.
    final stop =
        startsLine &&
        gap > 3 &&
        _stopLine.hasMatch(w.text) &&
        open.narration.isNotEmpty;
    if (!sameFont || tooFar || aboveRow || stop) {
      open = null;
      lastAmt = null;
      continue;
    }
    open.narration.add(w);
    if (w.bottom > open.maxBottom) open.maxBottom = w.bottom;
    lastNarr = w;
    consumed.add(i);
  }
}

// ------------------------------------------------------------- summary -----

List<String> _lines(List<PdfWord> words, List<int> idx) {
  final out = <String>[];
  final cur = <PdfWord>[];
  void flush() {
    if (cur.isEmpty) return;
    out.add(cur.map((w) => w.text).join(' '));
    cur.clear();
  }

  for (final i in idx) {
    final w = words[i];
    if (cur.isNotEmpty &&
        (w.page != cur.last.page || (w.midY - cur.last.midY).abs() > 3)) {
      flush();
    }
    cur.add(w);
  }
  flush();
  return out;
}

final RegExp _spaces = RegExp(r'\s+');
String _tidy(String s) => s.replaceAll(_spaces, ' ').trim();

String? _accountMask(String text) {
  final m = RegExp(
    r'(?:account|a/c)\s*(?:no\.?|number|#)?\s*[:\-]?\s*([0-9Xx*•]{6,})',
    caseSensitive: false,
  ).firstMatch(text);
  if (m == null) return null;
  final digits = m.group(1)!.replaceAll(RegExp(r'\D'), '');
  return digits.length >= 4 ? digits.substring(digits.length - 4) : null;
}

int? _money(String s) {
  final m = RegExp(r'\d[\d,]*\.\d\d').firstMatch(s);
  if (m == null) return null;
  final parts = m.group(0)!.replaceAll(',', '').split('.');
  return int.parse(parts[0]) * 100 + int.parse(parts[1]);
}

/// Opening and closing balance and the totals, from a line that names the figure
/// and gives it ("Closing Balance: 1,234.00"). A header that only names a column
/// never counts: the figure must be on the same line.
({int? opening, int? closing, int? debits, int? credits}) _summaryLines(
  List<String> lines,
) {
  int? find(RegExp label) {
    for (final l in lines) {
      final m = label.firstMatch(l);
      if (m == null) continue;
      final v = _money(l.substring(m.end));
      if (v != null) return v;
    }
    return null;
  }

  return (
    opening: find(
      RegExp(
        r'(?:brought\s+forward|opening\s+balance)[^0-9]{0,30}',
        caseSensitive: false,
      ),
    ),
    closing: find(
      RegExp(r'closing\s+balance[^0-9]{0,30}', caseSensitive: false),
    ),
    debits: find(
      RegExp(
        r'total\s+(?:debits?|withdrawals?)[^0-9]{0,30}',
        caseSensitive: false,
      ),
    ),
    credits: find(
      RegExp(
        r'total\s+(?:credits?|deposits?)[^0-9]{0,30}',
        caseSensitive: false,
      ),
    ),
  );
}

/// The issuer printed above the table, by the name the statement shows most.
String? _issuerOf(String head) {
  const names = <String, List<String>>{
    'icici': ['icici'],
    'sbi': ['state bank of india', 'sbi'],
    'hdfc': ['hdfc'],
    'axis': ['axis bank'],
    'kotak': ['kotak'],
    'yes': ['yes bank'],
    'idfc': ['idfc'],
    'federal': ['federal bank'],
    'pnb': ['punjab national'],
    'bob': ['bank of baroda'],
    'canara': ['canara'],
    'union': ['union bank'],
    'indusind': ['indusind'],
    'rbl': ['rbl bank'],
    'bandhan': ['bandhan'],
  };
  final text = head.toLowerCase();
  String? best;
  var bestCount = 0, tie = false;
  names.forEach((slug, keys) {
    var n = 0;
    for (final k in keys) {
      n += RegExp(RegExp.escape(k)).allMatches(text).length;
    }
    if (n > bestCount) {
      best = slug;
      bestCount = n;
      tie = false;
    } else if (n == bestCount && n > 0) {
      tie = true;
    }
  });
  return tie ? null : best;
}
