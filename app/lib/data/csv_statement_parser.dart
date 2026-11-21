import 'dart:convert';
import 'dart:typed_data';

import 'package:pandapay_domain/pandapay_domain.dart';

import 'investment_classifier.dart';
import 'pdf_statement_parser.dart';
import 'user_cards_repository.dart' show TxnInstrument;

/// Excel commonly exports UTF-16 tab-separated text, while other apps use UTF-8.
ParsedStatement parseDelimitedStatementBytes(
  Uint8List bytes, {
  StatementTableOptions options = const StatementTableOptions(),
}) => parseFlexibleCsvStatement(decodeStatementBytes(bytes), options: options);

String decodeStatementBytes(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Incomplete UTF-16 file');
    }
    final little = bytes[0] == 0xff;
    final units = <int>[];
    for (var i = 2; i < bytes.length; i += 2) {
      units.add(
        little
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(units);
  }
  return utf8.decode(bytes);
}

/// Parses transaction exports without depending on one bank's column names.
///
/// Real-world CSV exports differ in delimiter, header spelling, column order,
/// date notation, and whether debit/credit are separate columns. This parser
/// scores headers and values instead of requiring one exact schema. Rows that
/// do not have a credible date, amount, and description are skipped so a
/// metadata row can never become a made-up transaction.
ParsedStatement parseFlexibleCsvStatement(
  String input, {
  StatementTableOptions options = const StatementTableOptions(),
}) {
  return parseStatementRows(readDelimitedRows(input), options: options);
}

/// Shared column inference for delimited files and Excel worksheets.
ParsedStatement parseStatementRows(
  List<List<String>> rows, {
  StatementTableOptions options = const StatementTableOptions(),
  String sourceId = 'table',
}) {
  if (rows.isEmpty) return const ParsedStatement(transactions: []);

  final selectedHeader = options.headerRow ?? detectStatementHeader(rows);
  final headerIndex =
      selectedHeader != null &&
          selectedHeader >= 0 &&
          selectedHeader < rows.length
      ? selectedHeader
      : null;
  final headers = headerIndex == null
      ? const <String>[]
      : rows[headerIndex].map(_normalise).toList(growable: false);
  final firstDataRow = headerIndex == null ? 0 : headerIndex + 1;
  final rejected = <ImportRejectedRow>[];
  final transactions = <ParsedStatementLine>[];
  final acceptedCells = <List<String>>[];
  final signDerived = <bool>[];
  var inferredYear = const SystemClock().now().year;
  var skippedRows = 0;

  for (var rowIndex = firstDataRow; rowIndex < rows.length; rowIndex++) {
    final row = rows[rowIndex];
    if (row.every((cell) => cell.trim().isEmpty)) continue;
    final meta = _RowMeta();
    final parsed = _parseRow(
      row,
      headers,
      inferredYear,
      options,
      '$sourceId:row:${rowIndex + 1}',
      meta,
    );
    if (parsed == null) {
      // A title, a disclaimer or a totals line is not a transaction and not a
      // lost one: it is not reported as an unrecognised row.
      if (_isMetadataRow(row)) continue;
      skippedRows++;
      rejected.add(
        ImportRejectedRow(
          '$sourceId:row:${rowIndex + 1}',
          List.unmodifiable(row),
          'Missing or ambiguous date, amount, or description; unsupported currency; or a summary/header row. Adjust columns and formats or correct this row.',
        ),
      );
      continue;
    }
    inferredYear = parsed.date.year;
    transactions.add(parsed);
    acceptedCells.add(row);
    signDerived.add(meta.signDerived);
  }

  // A statement that prints a running balance proves its own rows: every row
  // must move the balance by exactly its amount, in the direction it says.
  final proof = _proveAgainstBalance(
    lines: transactions,
    cells: acceptedCells,
    signDerived: signDerived,
    headers: headers,
    options: options,
  );

  return ParsedStatement(
    transactions: proof.lines,
    rejectedRows: rejected,
    warnings: [
      if (skippedRows > 0)
        '$skippedRows nonempty rows were not recognized. Check the original export before importing. Only INR amounts are supported.',
      ...proof.warnings,
    ],
  );
}

final RegExp _summaryLabel = RegExp(
  r'^(?:total|grand total|closing balance|opening balance|balance (?:b/f|c/f|brought forward|carried forward)|statement\b|generated on|account (?:no|number|name|type|statement)|period|page\b|\*+|end of statement|this is a computer|computer generated|please do not share|disclaimer|note\b)',
  caseSensitive: false,
);
final RegExp _datelike = RegExp(
  r'\d{1,4}[./-]\d{1,2}[./-]\d{1,4}|\d{1,2}[\s./-]+[A-Za-z]{3,9}[\s,./-]+\d{2,4}',
);

/// Lines around a table that are not transactions: a title, a note, a footer, a
/// totals or balance line. A line with a date or an amount that still could not
/// be read is not one of these: it may be a transaction, and is reported.
bool _isMetadataRow(List<String> row) {
  final cells = [
    for (final c in row)
      if (c.trim().isNotEmpty) c.trim(),
  ];
  if (cells.isEmpty) return true;
  if (_summaryLabel.hasMatch(cells.first)) return true;
  final hasDate = cells.any(_datelike.hasMatch);
  final hasNumber = cells.any((c) => _number(c) != null);
  return !hasDate && !hasNumber;
}

const _chainBreak =
    "This row does not follow the statement's running balance, so its date, amount or direction may be misread. Check it before importing.";

/// Proves rows against the running balance column, when there is one.
///
/// Each row's balance must equal the row before it plus or minus its amount. A
/// row that does not is flagged. Where a row's direction was only the sign of one
/// amount column (a convention that differs between card and bank exports), the
/// balance decides it. A table with no usable balance column is left as it was,
/// with a note when its directions rest on a sign alone.
({List<ParsedStatementLine> lines, List<String> warnings})
_proveAgainstBalance({
  required List<ParsedStatementLine> lines,
  required List<List<String>> cells,
  required List<bool> signDerived,
  required List<String> headers,
  required StatementTableOptions options,
}) {
  const signNote =
      'Money in and out was read from the sign of the Amount column, with no balance to check it against. If incoming and outgoing look swapped, change the sign setting in Formats.';
  final anySign = signDerived.any((s) => s);
  var balanceIndex = -1;
  for (var i = 0; i < headers.length; i++) {
    final h = headers[i];
    if (RegExp(r'\b(?:balance|bal)\b').hasMatch(h) &&
        !RegExp(r'\b(?:opening|limit|available)\b').hasMatch(h)) {
      balanceIndex = i;
      if (RegExp(r'closing|running').hasMatch(h)) break;
    }
  }
  if (balanceIndex < 0 || lines.length < 3) {
    return (lines: lines, warnings: [if (anySign) signNote]);
  }
  final balances = <int?>[
    for (final row in cells)
      balanceIndex < row.length
          ? _balancePaise(row[balanceIndex], options)
          : null,
  ];
  // A balance that is printed but cannot be read is not a missing balance: the
  // row cannot be checked, and the person is told so.
  final unreadable = [
    for (var j = 0; j < cells.length; j++)
      balanceIndex < cells[j].length &&
          cells[j][balanceIndex].trim().isNotEmpty &&
          balances[j] == null,
  ];
  if (balances.where((b) => b != null).length < lines.length * 0.6) {
    return (lines: lines, warnings: [if (anySign) signNote]);
  }

  final n = lines.length;
  final reversed = lines.first.date.isAfter(lines.last.date);
  final order = [for (var i = 0; i < n; i++) reversed ? n - 1 - i : i];

  // What the balance says each row did: credit, debit, or neither (a break).
  final said = List<bool?>.filled(n, null);
  final compared = List<bool>.filled(n, false);
  for (var k = 1; k < n; k++) {
    final j = order[k], before = order[k - 1];
    final b = balances[j], a = balances[before];
    if (b == null || a == null) continue;
    compared[j] = true;
    final amount = lines[j].amount.paise;
    if (b - a == amount) {
      said[j] = true;
    } else if (b - a == -amount) {
      said[j] = false;
    }
  }

  // A sign convention the balance contradicts is the convention to flip.
  var agree = 0, disagree = 0;
  for (var j = 0; j < n; j++) {
    if (signDerived[j] && said[j] != null) {
      said[j] == lines[j].isCredit ? agree++ : disagree++;
    }
  }
  final flip = disagree > agree;

  final out = <ParsedStatementLine>[];
  var broken = 0;
  for (var j = 0; j < n; j++) {
    var credit = lines[j].isCredit;
    if (signDerived[j]) credit = said[j] ?? (flip ? !credit : credit);
    final reasons = <String>[];
    if (compared[j] && (said[j] == null || said[j] != credit)) {
      reasons.add(_chainBreak);
      broken++;
    } else if (unreadable[j]) {
      reasons.add(
        'The balance printed on this row could not be read, so the row could not be checked against the running balance.',
      );
      broken++;
    }
    out.add(
      reasons.isEmpty && credit == lines[j].isCredit
          ? lines[j]
          : lines[j].withReview(reasons, isCredit: credit),
    );
  }
  return (
    lines: out,
    warnings: [
      if (flip)
        'The balance column shows money out as the positive amounts in this file, so the Amount sign was read the other way round.',
      if (broken > 0)
        '$broken row(s) do not follow the running balance. Check them before importing.',
    ],
  );
}

final RegExp _debitWord = RegExp(r'\bdr\b', caseSensitive: false);

int? _balancePaise(String raw, StatementTableOptions options) {
  final value = _number(raw, options.numberFormat);
  if (value == null) return null;
  final paise = (value * 100).round();
  return _debitWord.hasMatch(raw) ? -paise.abs() : paise;
}

List<List<String>> readDelimitedRows(String input) {
  final text = input
      .replaceFirst('\ufeff', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  if (text.trim().isEmpty) return const [];
  final sample = text.split('\n').take(200).join('\n');
  final delimiter = _delimiter(sample);
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '"') {
      if (quoted && i + 1 < text.length && text[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (char == delimiter && !quoted) {
      row.add(field.toString().trim());
      field = StringBuffer();
    } else if (char == '\n' && !quoted) {
      row.add(field.toString().trim());
      if (row.any((cell) => cell.isNotEmpty)) rows.add(row);
      row = <String>[];
      field = StringBuffer();
    } else {
      field.write(char);
    }
  }
  if (quoted) {
    throw const StatementParseException(
      'A quoted field is incomplete. Export the file again or close the missing quote.',
    );
  }
  row.add(field.toString().trim());
  if (row.any((cell) => cell.isNotEmpty)) rows.add(row);
  return rows;
}

String _delimiter(String sample) {
  final counts = <String, int>{
    ',': _countOutsideQuotes(sample, ','),
    ';': _countOutsideQuotes(sample, ';'),
    '\t': _countOutsideQuotes(sample, '\t'),
    '|': _countOutsideQuotes(sample, '|'),
  };
  return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

int _countOutsideQuotes(String value, String needle) {
  var count = 0;
  var quoted = false;
  for (final char in value.split('')) {
    if (char == '"') quoted = !quoted;
    if (char == needle && !quoted) count++;
  }
  return count;
}

int? detectStatementHeader(List<List<String>> rows) {
  int? bestIndex;
  var bestScore = 1;
  for (var i = 0; i < rows.length && i < 200; i++) {
    if (!rows[i]
        .map(_normalise)
        .any(
          (cell) =>
              cell.contains('date') ||
              cell == 'timestamp' ||
              cell == 'occurred at' ||
              cell == 'time',
        )) {
      continue;
    }
    final score = rows[i]
        .map(_normalise)
        .fold<int>(0, (total, value) => total + _headerScore(value));
    if (score > bestScore && rows[i].length >= 2) {
      bestIndex = i;
      bestScore = score;
    }
  }
  return bestIndex;
}

int _headerScore(String value) {
  if (value.isEmpty) return 0;
  var score = 0;
  if (_hasAny(value, ['date', 'time', 'posted', 'value'])) score += 2;
  if (_hasAny(value, [
        'amount',
        'debit',
        'credit',
        'withdraw',
        'paid',
        'spent',
        'value',
      ]) ||
      value == 'dr' ||
      value == 'cr') {
    score += 2;
  }
  if (_hasAny(value, [
    'merchant',
    'description',
    'narration',
    'details',
    'memo',
    'place',
    'payee',
    'remarks',
    'particular',
  ])) {
    score += 2;
  }
  if (_hasAny(value, [
    'balance',
    'reference',
    'id',
    'account',
    'card',
    'category',
    'type',
    'currency',
  ])) {
    score += 1;
  }
  return score;
}

/// What the row parser learned about a row beyond the row itself.
class _RowMeta {
  /// Money in/out was taken from the sign of a single amount column, which is a
  /// convention (card exports print spending as positive, bank exports print it
  /// as negative), not something the file says.
  bool signDerived = false;
}

ParsedStatementLine? _parseRow(
  List<String> row,
  List<String> headers,
  int inferredYear,
  StatementTableOptions options,
  String sourceRowId, [
  _RowMeta? meta,
]) {
  double? number(String value) => _number(value, options.numberFormat);
  DateTime? dateValue(String value, int year) =>
      _parseDate(value, year, options);
  final currencyIndex =
      options.columns[ImportColumn.currency] ??
      _headerIndex(headers, ['currency']);
  // "Withdrawal Amount (INR)" contains "amount inr" but is a bank statement's
  // debit column, not the billed-INR column of a foreign-currency card export.
  final billedInrIndex = _headerIndex(
    [
      for (final h in headers)
        RegExp(
              r'\b(?:withdraw\w*|deposit\w*|debit|credit|balance|dr|cr)\b',
            ).hasMatch(h)
            ? ''
            : h,
    ],
    [
      'billed inr',
      'amount inr',
      'inr amount',
      'settled inr',
      'billed amount inr',
    ],
  );
  final printedCurrency =
      currencyIndex == null || currencyIndex < 0 || currencyIndex >= row.length
      ? null
      : row[currencyIndex].trim().toUpperCase();
  final foreignCurrency =
      printedCurrency != null &&
          printedCurrency.isNotEmpty &&
          !const ['INR', 'RS', 'RUPEES', '₹'].contains(printedCurrency)
      ? printedCurrency
      : null;
  if (billedInrIndex == null &&
      currencyIndex != null &&
      currencyIndex >= 0 &&
      currencyIndex < row.length &&
      row[currencyIndex].trim().isNotEmpty &&
      ![
        'inr',
        'rs',
        'rupees',
        '₹',
      ].contains(row[currencyIndex].trim().toLowerCase())) {
    return null;
  }
  final dateIndex =
      options.columns[ImportColumn.date] ??
      _bestIndex(row, headers, (header, value) {
        final score = _hasAny(header, ['date', 'time', 'posted', 'value'])
            ? 5
            : 0;
        return score + (dateValue(value, inferredYear) == null ? 0 : 2);
      });
  if (dateIndex == null || dateIndex < 0 || dateIndex >= row.length) {
    return null;
  }
  final date = dateValue(row[dateIndex], inferredYear);
  if (date == null) return null;

  final debitIndex =
      options.columns[ImportColumn.debit] ??
      _headerIndex(headers, [
        'debit',
        'withdraw',
        'withdrawal',
        'expense',
        'spent',
        'paid',
        'dr',
      ]);
  final creditIndex =
      options.columns[ImportColumn.credit] ??
      _headerIndex(headers, [
        'credit',
        'deposit',
        'refund',
        'income',
        'received',
        'cr',
      ]);
  // Do not treat a "Value Date" column as the amount merely because it
  // contains the word value. A plain "Value" column is still handled by the
  // numeric fallback below.
  final amountIndex =
      billedInrIndex ??
      options.columns[ImportColumn.amount] ??
      _headerIndex(headers, [
        'amount',
        'transaction amount',
        'total',
        'price',
        'value',
        'inr',
        'cost',
      ]);
  var isCredit = false;
  var dedicatedDirection = false;
  String? amountRaw;
  if (billedInrIndex != null && billedInrIndex < row.length) {
    amountRaw = row[billedInrIndex];
  } else if (debitIndex != null &&
      debitIndex >= 0 &&
      debitIndex < row.length &&
      (number(row[debitIndex]) ?? 0) != 0) {
    amountRaw = row[debitIndex];
    dedicatedDirection = true;
  } else if (creditIndex != null &&
      creditIndex >= 0 &&
      creditIndex < row.length &&
      (number(row[creditIndex]) ?? 0) != 0) {
    amountRaw = row[creditIndex];
    dedicatedDirection = true;
    isCredit = true;
  } else if (amountIndex != null &&
      amountIndex >= 0 &&
      amountIndex < row.length) {
    amountRaw = row[amountIndex];
    isCredit = RegExp(
      r'\b(?:cr|credit)\b',
      caseSensitive: false,
    ).hasMatch(row[amountIndex]);
  }
  if (debitIndex != null &&
      debitIndex >= 0 &&
      debitIndex < row.length &&
      creditIndex != null &&
      creditIndex >= 0 &&
      creditIndex < row.length &&
      (number(row[debitIndex]) ?? 0) != 0 &&
      (number(row[creditIndex]) ?? 0) != 0) {
    return null;
  }
  if (amountRaw == null && amountIndex != null && amountIndex >= 0) return null;
  if (amountRaw == null) {
    if (headers.isNotEmpty) return null;
    final candidates = <({int index, double value})>[];
    for (var i = 0; i < row.length; i++) {
      if (i == dateIndex ||
          _hasAny(headers.elementAtOrNull(i) ?? '', [
            'balance',
            'limit',
            'reference',
            'id',
            'account',
            'card',
          ])) {
        continue;
      }
      final value = number(row[i]);
      if (value != null) candidates.add((index: i, value: value));
    }
    if (candidates.length != 1) return null;
    amountRaw = row[candidates.first.index];
    isCredit = options.negativeIsExpense
        ? candidates.first.value > 0
        : candidates.first.value < 0;
    meta?.signDerived = true;
  }
  if (!dedicatedDirection &&
      amountIndex != null &&
      amountIndex >= 0 &&
      !RegExp(
        r'\b(?:CR|DR|credit|debit)\b',
        caseSensitive: false,
      ).hasMatch(amountRaw)) {
    final numeric = number(amountRaw);
    if (numeric != null) {
      isCredit = options.negativeIsExpense ? numeric > 0 : numeric < 0;
      meta?.signDerived = true;
    }
  }
  final directionIndex =
      options.columns[ImportColumn.direction] ??
      _headerIndex(headers, [
        'dr cr',
        'debit credit',
        'income expense',
        'in out',
        'transaction type',
        'type',
        'direction',
      ]);
  if (directionIndex != null &&
      directionIndex >= 0 &&
      directionIndex < row.length) {
    final direction = _normalise(row[directionIndex]);
    if (['cr', 'credit', 'income', 'refund'].contains(direction)) {
      isCredit = true;
      meta?.signDerived = false;
    }
    if (['dr', 'debit', 'expense', 'spend'].contains(direction)) {
      isCredit = false;
      meta?.signDerived = false;
    }
  }
  final amountValue = number(amountRaw);
  if (amountValue == null || amountValue == 0) return null;

  final descriptionIndex =
      options.columns[ImportColumn.description] ??
      _bestIndex(row, headers, (header, value) {
        if (value.trim().isEmpty ||
            dateValue(value, inferredYear) != null ||
            number(value) != null) {
          return 0;
        }
        if (_hasAny(header, [
          'merchant',
          'description',
          'narration',
          'details',
          'memo',
          'place',
          'payee',
          'remarks',
          'particular',
          'name',
          'note',
          'vendor',
          'title',
        ])) {
          return 5;
        }
        if (_hasAny(header, [
          'reference',
          'id',
          'account',
          'card',
          'category',
          'type',
          'currency',
        ])) {
          return 0;
        }
        return 1;
      }, excluded: {dateIndex});
  if (descriptionIndex == null ||
      descriptionIndex < 0 ||
      descriptionIndex >= row.length) {
    return null;
  }
  final referenceIndex = _headerIndex(headers, [
    'reference',
    'utr',
    'rrn',
    'bank reference',
    'upi reference',
    'transaction reference',
  ]);
  final reference = referenceIndex != null && referenceIndex < row.length
      ? row[referenceIndex].trim()
      : null;
  final description = row[descriptionIndex].trim();
  if (description.length < 2) return null;
  final accountIndex =
      options.columns[ImportColumn.account] ??
      _headerIndex(headers, ['source account', 'paid with', 'account', 'card']);
  final expenseIndex = headers.indexOf('expense');
  final typeIndex = _headerIndex(headers, ['type', 'category']);
  final kindIndex = _headerIndex(headers, [
    'entry kind',
    'transaction type',
    'kind',
  ]);
  final importedKind = kindIndex != null && kindIndex < row.length
      ? _normalise(row[kindIndex])
      : '';
  final categoryHintIndex = _headerIndex(headers, [
    'category',
    'category name',
  ]);
  final subcategoryHintIndex = _headerIndex(headers, [
    'subcategory',
    'sub category',
    'subcategory name',
  ]);
  final tagNames = normalizeImportedTagNames([
    for (var i = 0; i < headers.length && i < row.length; i++)
      if (const [
        'tag',
        'tags',
        'label',
        'labels',
        'tag names',
      ].contains(headers[i]))
        ...parseImportedTagNames(row[i]),
  ]);
  final transfer =
      importedKind == 'transfer' ||
      RegExp(
        r'\b(?:self\s+transfer|own\s+account|transfer|repayment|emi|loan\s+(?:payment|repayment|disbursement)|salary\s+advance|credit\s+card\s+(?:bill\s+)?(?:payment|pmt)|card\s+bill\s+pay|cc\s*bill\s*pay(?:ment)?|auto\s*debit\s*cc\w*|wallet\s+(?:load|top[ -]?up)|top[ -]?up|cash\s+(?:withdrawal|deposit)|refund(?:ed)?|chargeback|revers(?:al|ed)|cashback|reward|statement\s+credit|balance\s+adjustment|card\s+adjustment|gift|reimburse(?:ment|d)?|investment\s+proceeds|redemption|fd\s+maturity|fixed\s+deposit\s+maturity)\b',
        caseSensitive: false,
      ).hasMatch(description) ||
      (expenseIndex >= 0 && expenseIndex < row.length
          ? _normalise(row[expenseIndex]) == 'no'
          : typeIndex != null &&
                typeIndex < row.length &&
                _normalise(row[typeIndex]) == 'transfer');
  final investment =
      importedKind == 'investment' ||
      (typeIndex != null &&
          typeIndex < row.length &&
          [
            'investment',
            'invest',
            'mutual fund',
            'sip',
          ].contains(_normalise(row[typeIndex]))) ||
      isInvestmentMovementDescription(description);
  final dateText = row[dateIndex].trim().replaceFirst(
    RegExp(r'\s+\d{1,2}:\d{2}.*$'),
    '',
  );
  final numericDate = RegExp(
    r'^(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?$',
  ).firstMatch(dateText);
  final reviewReasons = <String>[];
  if (numericDate != null &&
      !options.dateOrderConfirmed &&
      int.parse(numericDate.group(1)!) <= 12 &&
      int.parse(numericDate.group(2)!) <= 12 &&
      numericDate.group(1) != numericDate.group(2)) {
    reviewReasons.add('Confirm day/month order in Formats, or edit the date.');
  }
  if (numericDate != null &&
      numericDate.group(3) == null &&
      options.year == null) {
    reviewReasons.add(
      'This date has no year. Choose the export year in Formats, or edit the date.',
    );
  }
  if (RegExp(
        r'^(?:\d{1,2}[\s./-]+[A-Za-z]{3,9}|[A-Za-z]{3,9}[\s./-]+\d{1,2}),?\s*$',
      ).hasMatch(dateText) &&
      options.year == null) {
    reviewReasons.add(
      'This date has no year. Choose the export year in Formats, or edit the date.',
    );
  }
  return ParsedStatementLine(
    sourceRowId: sourceRowId,
    reviewReasons: reviewReasons,
    sourceAccount:
        accountIndex != null &&
            accountIndex >= 0 &&
            accountIndex < row.length &&
            row[accountIndex].trim().isNotEmpty
        ? row[accountIndex].trim()
        : null,
    isTransfer: transfer,
    isInvestment: investment,
    date: date,
    description: description,
    bankReference:
        reference != null && RegExp(r'^[a-zA-Z0-9-]{6,40}$').hasMatch(reference)
        ? reference
        : null,
    categoryHint: categoryHintIndex != null && categoryHintIndex < row.length
        ? row[categoryHintIndex].trim()
        : null,
    subcategoryHint:
        subcategoryHintIndex != null && subcategoryHintIndex < row.length
        ? row[subcategoryHintIndex].trim()
        : null,
    tagNames: tagNames,
    originalCurrency:
        foreignCurrency ??
        _cellFor(headers, row, [
          'original currency',
          'foreign currency',
          'transaction currency',
        ])?.toUpperCase(),
    originalAmount:
        _cellFor(headers, row, [
          'original amount',
          'foreign amount',
          'transaction amount foreign',
        ])?.replaceAll(',', '') ??
        (foreignCurrency != null && billedInrIndex != null
            ? _cellFor(headers, row, [
                'amount',
                'transaction amount',
              ])?.replaceAll(',', '')
            : null),
    foreignSourceKey: _cellFor(headers, row, [
      'foreign source key',
      'foreign_source_key',
    ]),
    instrument: _parseInstrument(
      _cellFor(headers, row, [
        'instrument',
        'payment instrument',
        'paid using',
        'paid with',
      ]),
    ),
    rail: _parseRail(_cellFor(headers, row, ['rail', 'payment rail'])),
    note: _cellFor(headers, row, ['note', 'notes', 'remarks note']),
    amount: Money.fromRupees(amountValue.abs()),
    isCredit: importedKind == 'income' || isCredit,
  );
}

String? _cellFor(List<String> headers, List<String> row, List<String> names) {
  final index = _headerIndex(headers, names);
  if (index == null || index < 0 || index >= row.length) return null;
  final value = row[index].trim();
  return value.isEmpty ? null : value;
}

TxnInstrument? _parseInstrument(String? value) {
  if (value == null) return null;
  final normalized = _normalise(value).replaceAll(' ', '_');
  for (final instrument in TxnInstrument.values) {
    if (instrument.wireValue == normalized) return instrument;
  }
  return null;
}

String? _parseRail(String? value) {
  if (value == null) return null;
  final normalized = _normalise(value).replaceAll(' ', '_');
  return const {
        'upi_qr',
        'swipe',
        'online',
        'contactless',
        'atm',
        'emi',
        'unknown',
      }.contains(normalized)
      ? normalized
      : null;
}

int? _bestIndex(
  List<String> row,
  List<String> headers,
  int Function(String header, String value) score, {
  Set<int> excluded = const {},
}) {
  int? best;
  var bestScore = 0;
  for (var i = 0; i < row.length; i++) {
    if (excluded.contains(i)) continue;
    final current = score(i < headers.length ? headers[i] : '', row[i]);
    if (current > bestScore) {
      best = i;
      bestScore = current;
    }
  }
  return best;
}

int? _headerIndex(List<String> headers, List<String> keywords) {
  for (var i = 0; i < headers.length; i++) {
    if (keywords.contains(headers[i])) return i;
  }
  for (var i = 0; i < headers.length; i++) {
    if (headers[i].contains('date')) continue;
    final moneyColumn = keywords.any(
      (word) => [
        'debit',
        'credit',
        'withdraw',
        'withdrawal',
        'expense',
        'spent',
        'paid',
        'deposit',
        'refund',
        'income',
        'received',
        'amount',
        'total',
        'price',
        'value',
        'inr',
        'cost',
      ].contains(word),
    );
    if (moneyColumn &&
        (RegExp(
              r'\b(?:card|account|type|balance|limit|reference|id|opening|closing)\b',
            ).hasMatch(headers[i]) ||
            headers[i] == 'income expense' ||
            headers[i] == 'debit credit')) {
      continue;
    }
    // A short keyword ("dr", "cr", "id") is a whole word: "cr" is in
    // "description" and "id" is in "paid".
    if (keywords.any(
      (keyword) =>
          headers[i] == keyword ||
          (keyword.length <= 3
              ? RegExp('\\b$keyword\\b').hasMatch(headers[i])
              : headers[i].contains(keyword)),
    )) {
      return i;
    }
  }
  return null;
}

String _normalise(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

bool _hasAny(String value, List<String> needles) => needles.any(value.contains);

double? _number(
  String raw, [
  ImportNumberFormat format = ImportNumberFormat.decimalPoint,
]) {
  var value = raw.toLowerCase().trim();
  if (value.isEmpty ||
      value == '-' ||
      value == '—' ||
      _hasAny(value, ['n/a', 'null'])) {
    return null;
  }
  value = value
      .replaceAll(
        RegExp(r'(?:INR|Rs\.?|₹|\bDR\b|\bCR\b)', caseSensitive: false),
        '',
      )
      .trim();
  if (value.startsWith('(') != value.endsWith(')')) return null;
  final negative = value.startsWith('(') || value.startsWith('-');
  value = value.replaceAll(RegExp(r'[\u00a0\u202f]'), ' ');
  if (RegExp(
    r'^[-+]?\(?\d{1,3}(?: \d{3})+(?:[.,]\d{1,2})?\)?$',
  ).hasMatch(value)) {
    value = value.replaceAll(' ', '');
  }
  if (format == ImportNumberFormat.decimalComma) {
    if (!RegExp(
      r'^[-+]?\(?(?:\d+|\d{1,3}(?:\.\d{3})+)(?:,\d{1,2})?\)?$',
    ).hasMatch(value)) {
      return null;
    }
    value = value.replaceAll('.', '').replaceAll(',', '.');
  }
  if (!RegExp(r'^[-+]?\(?\d[\d,]*(?:\.\d{1,2})?\)?$').hasMatch(value)) {
    return null;
  }
  final whole = value.replaceAll(RegExp(r'[-+()]'), '').split('.').first;
  if (whole.contains(',') &&
      !RegExp(
        r'^(?:\d{1,3}(?:,\d{3})+|\d{1,2}(?:,\d{2})*,\d{3})$',
      ).hasMatch(whole)) {
    return null;
  }
  value = value.replaceAll(RegExp(r'[,()]'), '');
  if (value.isEmpty || value == '-' || value == '.') return null;
  final parsed = double.tryParse(value);
  return parsed == null || !parsed.isFinite || parsed.abs() > 9999999999.99
      ? null
      : (negative ? -parsed.abs() : parsed);
}

DateTime? _parseDate(
  String raw,
  int inferredYear, [
  StatementTableOptions options = const StatementTableOptions(),
]) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final dateTime = RegExp(
    r'^(.+?)\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$',
    caseSensitive: false,
  ).firstMatch(value);
  if (dateTime != null) {
    final date = _parseDate(dateTime.group(1)!, inferredYear, options);
    var hour = int.parse(dateTime.group(2)!);
    final minute = int.parse(dateTime.group(3)!);
    final second = int.parse(dateTime.group(4) ?? '0');
    final period = dateTime.group(5)?.toUpperCase();
    if (date == null ||
        minute > 59 ||
        second > 59 ||
        (period == null ? hour > 23 : hour < 1 || hour > 12)) {
      return null;
    }
    if (period != null) hour = hour % 12 + (period == 'PM' ? 12 : 0);
    return DateTime(date.year, date.month, date.day, hour, minute, second);
  }
  final epoch = int.tryParse(value);
  if (epoch != null && (value.length == 10 || value.length == 13)) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      value.length == 10 ? epoch * 1000 : epoch,
    );
    return date.year >= 1900 && date.year <= 2100 ? date : null;
  }
  final iso = DateTime.tryParse(value);
  if (iso != null) {
    final parts = RegExp(
      r'^(\d{4})-?(\d{2})-?(\d{2})(?:$|T| )',
    ).firstMatch(value);
    if (parts != null) {
      final checked = DateTime(
        int.parse(parts.group(1)!),
        int.parse(parts.group(2)!),
        int.parse(parts.group(3)!),
      );
      if (checked.month != int.parse(parts.group(2)!) ||
          checked.day != int.parse(parts.group(3)!)) {
        return null;
      }
    }
    return iso;
  }
  final match = RegExp(
    r'^(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?$',
  ).firstMatch(value);
  if (match != null) {
    final first = int.parse(match.group(1)!);
    final second = int.parse(match.group(2)!);
    var year =
        int.tryParse(match.group(3) ?? '') ?? options.year ?? inferredYear;
    if (year < 100) year += 2000;
    final day = options.dateOrderConfirmed
        ? (options.dateOrder == ImportDateOrder.dayFirst ? first : second)
        : first > 12
        ? first
        : second > 12
        ? second
        : options.dateOrder == ImportDateOrder.monthFirst
        ? second
        : first;
    final month = options.dateOrderConfirmed
        ? (options.dateOrder == ImportDateOrder.dayFirst ? second : first)
        : first > 12
        ? second
        : second > 12
        ? first
        : options.dateOrder == ImportDateOrder.monthFirst
        ? first
        : second;
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }
  final monthFirst = RegExp(
    r'^([A-Za-z]{3,9})[\s./-]+(\d{1,2})(?:[,\s./-]+(\d{2,4}))?$',
  ).firstMatch(value);
  if (monthFirst != null) {
    return _parseDate(
      '${monthFirst.group(2)} ${monthFirst.group(1)}${monthFirst.group(3) == null ? '' : ' ${monthFirst.group(3)}'}',
      inferredYear,
      options,
    );
  }
  final named = RegExp(
    r'^(\d{1,2})[\s./-]+([A-Za-z]{3,9})(?:[,\s./-]+(\d{2,4}))?$',
  ).firstMatch(value);
  if (named != null) {
    const months = {
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
    final month = months[named.group(2)!.toLowerCase().substring(0, 3)];
    var year =
        int.tryParse(named.group(3) ?? '') ?? options.year ?? inferredYear;
    if (year < 100) year += 2000;
    if (month == null) return null;
    final day = int.parse(named.group(1)!);
    final date = DateTime(year, month, day);
    return date.month == month && date.day == day ? date : null;
  }
  return null;
}

extension on List<String> {
  String? elementAtOrNull(int index) => index < length ? this[index] : null;
}
