import 'package:pandapay_domain/pandapay_domain.dart';

import 'pdf_statement_parser.dart';

/// Parses transaction exports without depending on one bank's column names.
///
/// Real-world CSV exports differ in delimiter, header spelling, column order,
/// date notation, and whether debit/credit are separate columns. This parser
/// scores headers and values instead of requiring one exact schema. Rows that
/// do not have a credible date, amount, and description are skipped so a
/// metadata row can never become a made-up transaction.
ParsedStatement parseFlexibleCsvStatement(String input) {
  final rows = _csvRows(input);
  if (rows.isEmpty) return const ParsedStatement(transactions: []);

  final headerIndex = _findHeaderRow(rows);
  final headers = headerIndex == null
      ? const <String>[]
      : rows[headerIndex].map(_normalise).toList(growable: false);
  final dataRows = rows.skip(headerIndex == null ? 0 : headerIndex + 1);
  final transactions = <ParsedStatementLine>[];
  var inferredYear = const SystemClock().now().year;

  for (final row in dataRows) {
    if (row.every((cell) => cell.trim().isEmpty)) continue;
    final parsed = _parseRow(row, headers, inferredYear);
    if (parsed == null) continue;
    inferredYear = parsed.date.year;
    transactions.add(parsed);
  }

  return ParsedStatement(transactions: transactions);
}

List<List<String>> _csvRows(String input) {
  final text = input
      .replaceFirst('\ufeff', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  if (text.trim().isEmpty) return const [];
  final sample = text.split('\n').take(12).join('\n');
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

int? _findHeaderRow(List<List<String>> rows) {
  var bestIndex;
  var bestScore = 1;
  for (var i = 0; i < rows.length && i < 20; i++) {
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
  ]))
    score += 2;
  if (_hasAny(value, [
    'merchant',
    'description',
    'narration',
    'details',
    'memo',
    'payee',
    'remarks',
    'particular',
  ]))
    score += 2;
  if (_hasAny(value, [
    'balance',
    'reference',
    'id',
    'account',
    'card',
    'category',
    'type',
    'currency',
  ]))
    score += 1;
  return score;
}

ParsedStatementLine? _parseRow(
  List<String> row,
  List<String> headers,
  int inferredYear,
) {
  final dateIndex = _bestIndex(row, headers, (header, value) {
    final score = _hasAny(header, ['date', 'time', 'posted', 'value']) ? 5 : 0;
    return score + (_parseDate(value, inferredYear) == null ? 0 : 2);
  });
  if (dateIndex == null) return null;
  final date = _parseDate(row[dateIndex], inferredYear);
  if (date == null) return null;

  final debitIndex = _headerIndex(headers, [
    'debit',
    'withdraw',
    'withdrawal',
    'expense',
    'spent',
    'paid',
  ]);
  final creditIndex = _headerIndex(headers, [
    'credit',
    'deposit',
    'refund',
    'income',
    'received',
  ]);
  // Do not treat a "Value Date" column as the amount merely because it
  // contains the word value. A plain "Value" column is still handled by the
  // numeric fallback below.
  final amountIndex = _headerIndex(headers, [
    'amount',
    'transaction amount',
    'total',
    'price',
  ]);
  var isCredit = false;
  String? amountRaw;
  if (debitIndex != null &&
      debitIndex < row.length &&
      _number(row[debitIndex]) != null) {
    amountRaw = row[debitIndex];
  } else if (creditIndex != null &&
      creditIndex < row.length &&
      _number(row[creditIndex]) != null) {
    amountRaw = row[creditIndex];
    isCredit = true;
  } else if (amountIndex != null && amountIndex < row.length) {
    amountRaw = row[amountIndex];
    isCredit =
        _hasAny(_normalise(row[amountIndex]), ['credit', 'refund', 'income']) ||
        row.any(
          (cell) => _hasAny(_normalise(cell), ['credit', 'refund', 'income']),
        );
  }
  if (amountRaw == null) {
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
          ]))
        continue;
      final value = _number(row[i]);
      if (value != null) candidates.add((index: i, value: value));
    }
    if (candidates.isEmpty) return null;
    amountRaw = row[candidates.first.index];
    isCredit = candidates.first.value < 0;
  }
  final amountValue = _number(amountRaw);
  if (amountValue == null || amountValue == 0) return null;

  final descriptionIndex = _bestIndex(row, headers, (header, value) {
    if (value.trim().isEmpty ||
        _parseDate(value, inferredYear) != null ||
        _number(value) != null)
      return 0;
    if (_hasAny(header, [
      'merchant',
      'description',
      'narration',
      'details',
      'memo',
      'payee',
      'remarks',
      'particular',
      'name',
    ]))
      return 5;
    if (_hasAny(header, [
      'reference',
      'id',
      'account',
      'card',
      'category',
      'type',
      'currency',
    ]))
      return 0;
    return 1;
  }, excluded: {dateIndex});
  if (descriptionIndex == null) return null;
  final description = row[descriptionIndex].trim();
  if (description.length < 2) return null;
  return ParsedStatementLine(
    date: date,
    description: description,
    amount: Money.fromRupees(amountValue.abs()),
    isCredit: isCredit,
  );
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
    if (keywords.any(
      (keyword) => headers[i] == keyword || headers[i].contains(keyword),
    ))
      return i;
  }
  return null;
}

String _normalise(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

bool _hasAny(String value, List<String> needles) => needles.any(value.contains);

double? _number(String raw) {
  var value = raw.toLowerCase().trim();
  if (value.isEmpty ||
      value == '-' ||
      value == '—' ||
      _hasAny(value, ['n/a', 'null']))
    return null;
  final negative = value.startsWith('(') || value.startsWith('-');
  value = value.replaceAll(RegExp(r'[^0-9.\-]'), '');
  if (value.isEmpty || value == '-' || value == '.') return null;
  final parsed = double.tryParse(value);
  return parsed == null ? null : (negative ? -parsed.abs() : parsed);
}

DateTime? _parseDate(String raw, int inferredYear) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final epoch = int.tryParse(value);
  if (epoch != null && (value.length == 10 || value.length == 13)) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      value.length == 10 ? epoch * 1000 : epoch,
    );
    return DateTime(date.year, date.month, date.day);
  }
  final iso = DateTime.tryParse(value);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final match = RegExp(
    r'^(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?$',
  ).firstMatch(value);
  if (match != null) {
    final first = int.parse(match.group(1)!);
    final second = int.parse(match.group(2)!);
    var year = int.tryParse(match.group(3) ?? '') ?? inferredYear;
    if (year < 100) year += 2000;
    final day = first > 12
        ? first
        : second > 12
        ? second
        : first;
    final month = first > 12
        ? second
        : second > 12
        ? first
        : second;
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }
  final named = RegExp(
    r'^(\d{1,2})\s+([A-Za-z]{3,9}),?\s*(\d{2,4})?$',
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
    var year = int.tryParse(named.group(3) ?? '') ?? inferredYear;
    if (year < 100) year += 2000;
    if (month == null) return null;
    return DateTime(year, month, int.parse(named.group(1)!));
  }
  return null;
}

extension on List<String> {
  String? elementAtOrNull(int index) => index < length ? this[index] : null;
}
