import 'package:pandapay_domain/pandapay_domain.dart';

import 'import_models.dart';

/// The OCR result is deliberately richer than [ParsedStatementLine]. A bill
/// may contain a readable final amount while its merchant or date is blurred.
/// The UI can safely prefill the amount and ask the user for only the missing
/// fields instead of throwing away the useful part of the scan.
class ReceiptScanResult {
  final bool looksLikeReceipt;
  final double? amountRupees;
  final DateTime? date;
  final String? merchant;
  final List<String> reviewReasons;

  const ReceiptScanResult({
    required this.looksLikeReceipt,
    this.amountRupees,
    this.date,
    this.merchant,
    this.reviewReasons = const [],
  });

  ParsedStatementLine? get parsedLine {
    final amount = amountRupees;
    final dateValue = date;
    final merchantValue = merchant;
    if (amount == null || dateValue == null || merchantValue == null) {
      return null;
    }
    return ParsedStatementLine(
      date: dateValue,
      description: merchantValue,
      amount: Money.fromRupees(amount),
      sourceRowId: 'receipt',
      reviewReasons: reviewReasons,
    );
  }
}

class _ReceiptTotalCandidate {
  final double amount;
  final int rank;
  final int lineIndex;

  const _ReceiptTotalCandidate({
    required this.amount,
    required this.rank,
    required this.lineIndex,
  });
}

class _ReceiptDateCandidate {
  final DateTime date;
  final int priority;
  final int lineIndex;

  const _ReceiptDateCandidate({
    required this.date,
    required this.priority,
    required this.lineIndex,
  });
}

class _ReceiptLabelMatch {
  final RegExpMatch match;
  final int rank;

  const _ReceiptLabelMatch(this.match, this.rank);
}

final _receiptNumber = RegExp(
  r'(?:(?:₹|rs\.?|inr|\$|€|£)\s*)?(\d(?:[\d.,]*\d)?)',
  caseSensitive: false,
);

final _amountOnly = RegExp(
  r'^(?:(?:₹|rs\.?|inr|\$|€|£)\s*)?\d(?:[\d.,]*\d)?\s*(?:₹|rs\.?|inr|\$|€|£)?$',
  caseSensitive: false,
);

final _totalLabelPatterns = <({RegExp pattern, int rank})>[
  (pattern: RegExp(r'\bgrand\s*tota[l1i]\b', caseSensitive: false), rank: 130),
  (
    pattern: RegExp(
      r'\btotal\s*(?:payable|due|amount|amt|bill|invoice)\b',
      caseSensitive: false,
    ),
    rank: 120,
  ),
  (
    pattern: RegExp(
      r'\bnet\s*(?:payable|amount|total)\b',
      caseSensitive: false,
    ),
    rank: 115,
  ),
  (
    pattern: RegExp(
      r'\b(?:amount|balance)\s*(?:due|payable|paid|to\s*(?:be\s*)?paid)\b',
      caseSensitive: false,
    ),
    rank: 110,
  ),
  (pattern: RegExp(r'\binvoice\s*total\b', caseSensitive: false), rank: 105),
  (pattern: RegExp(r'\bfinal\s*amount\b', caseSensitive: false), rank: 105),
  (
    pattern: RegExp(
      r'\btotal\s*(?:incl|including|inclusive)\.?\s*(?:of\s*)?(?:tax|gst|vat)\b',
      caseSensitive: false,
    ),
    rank: 100,
  ),
  (
    pattern: RegExp(r'\b(?:payable|amount\s+to\s+pay)\b', caseSensitive: false),
    rank: 100,
  ),
  (
    pattern: RegExp(r'\b(?:payable|paid)\s+amount\b', caseSensitive: false),
    rank: 95,
  ),
];

final _receiptMarkers = RegExp(
  r'\b(?:gstin|gst|vat|tax|cashier|bill\s*(?:no|number)|receipt|invoice|item|qty|quantity|subtotal|sub\s+total|paid|take\s*away|thank\s+you|date)\b',
  caseSensitive: false,
);

final _dateMarker = RegExp(
  r'\b(?:date|invoice\s+date|bill\s+date|order\s+date|transaction\s+date)\b',
  caseSensitive: false,
);

final _nonTransactionDateMarker = RegExp(
  r'\b(?:due|expiry|expiration|valid\s+until|pay\s+by)\s+date\b',
  caseSensitive: false,
);

final _months = <String, int>{
  'jan': 1,
  'january': 1,
  'feb': 2,
  'february': 2,
  'mar': 3,
  'march': 3,
  'apr': 4,
  'april': 4,
  'may': 5,
  'jun': 6,
  'june': 6,
  'jul': 7,
  'july': 7,
  'aug': 8,
  'august': 8,
  'sep': 9,
  'sept': 9,
  'september': 9,
  'oct': 10,
  'october': 10,
  'nov': 11,
  'november': 11,
  'dec': 12,
  'december': 12,
};

String _cleanLine(String value) =>
    value.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

double? _parseNumber(String raw) {
  final value = raw.replaceAll(' ', '').trim();
  if (value.isEmpty) return null;

  // Support both Indian/English thousands separators and decimal-comma
  // receipts. `1,234` remains 1234 while `47,95` becomes 47.95.
  final comma = value.lastIndexOf(',');
  final dot = value.lastIndexOf('.');
  final normalized = comma >= 0 && dot >= 0
      ? comma > dot
            ? '${value.substring(0, comma).replaceAll(RegExp(r'[.,]'), '')}.${value.substring(comma + 1)}'
            : '${value.substring(0, dot).replaceAll(RegExp(r'[.,]'), '')}.${value.substring(dot + 1)}'
      : comma >= 0
      ? RegExp(r',\d{2}$').hasMatch(value)
            ? value
                  .replaceFirst(RegExp(r',(?=\d{2}$)'), '.')
                  .replaceAll(',', '')
            : value.replaceAll(',', '')
      : value;
  return double.tryParse(normalized);
}

double? _amountAfter(String value, int start) {
  final suffix = value.substring(start);
  final matches = _receiptNumber.allMatches(suffix).toList();
  for (final match in matches.reversed) {
    final end = match.end;
    if (end < suffix.length &&
        suffix.substring(end).trimLeft().startsWith('%')) {
      continue;
    }
    final amount = _parseNumber(match.group(1)!);
    if (amount != null && amount > 0) return amount;
  }
  return null;
}

bool _isExcludedTotalLabel(String line, RegExpMatch match) {
  final before = line.substring(0, match.start).toLowerCase();
  final after = line.substring(match.end).toLowerCase();
  return before.trimRight().endsWith('sub') ||
      RegExp(
        r'^\s*(?:qty|quantity|items?|tax|gst|discount|savings|shipping|delivery|charges?)\b',
      ).hasMatch(after) ||
      RegExp(r'grand\s*$', caseSensitive: false).hasMatch(before);
}

List<_ReceiptLabelMatch> _totalLabelsForLine(String line) {
  final matches = <_ReceiptLabelMatch>[];
  for (final entry in _totalLabelPatterns) {
    for (final match in entry.pattern.allMatches(line)) {
      if (!_isExcludedTotalLabel(line, match)) {
        matches.add(_ReceiptLabelMatch(match, entry.rank));
      }
    }
  }

  // Thermal receipts often print only `TOTAL`. Keep it as a fallback, but
  // explicitly exclude subtotal, total-quantity and the `total` in Grand
  // Total, which are common false positives.
  for (final match in RegExp(
    r'\btotal\b',
    caseSensitive: false,
  ).allMatches(line)) {
    if (!_isExcludedTotalLabel(line, match)) {
      matches.add(_ReceiptLabelMatch(match, 70));
    }
  }
  return matches;
}

double? _amountForLabel(List<String> lines, int lineIndex, RegExpMatch label) {
  final line = lines[lineIndex];
  final sameLine = _amountAfter(line, label.end);
  if (sameLine != null) return sameLine;

  // ML Kit can put the left label and right-aligned number on separate rows.
  // Only accept a numeric-only following row; searching arbitrary text would
  // attach an item price or tax to the total label.
  for (
    var next = lineIndex + 1;
    next < lines.length && next <= lineIndex + 2;
    next++
  ) {
    final candidate = lines[next].trim();
    if (_amountOnly.hasMatch(candidate)) return _amountAfter(candidate, 0);
  }
  return null;
}

DateTime? _validDate(int year, int month, int day) {
  if (year < 100) year += 2000;
  if (day < 1 || day > 31 || month < 1 || month > 12) return null;
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

List<_ReceiptDateCandidate> _datesForLine(String line, int lineIndex) {
  final priority =
      _dateMarker.hasMatch(line) && !_nonTransactionDateMarker.hasMatch(line)
      ? 2
      : 1;
  final result = <_ReceiptDateCandidate>[];

  for (final match in RegExp(
    r'\b(\d{4})[./-](\d{1,2})[./-](\d{1,2})\b',
  ).allMatches(line)) {
    final date = _validDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
    if (date != null) {
      result.add(
        _ReceiptDateCandidate(
          date: date,
          priority: priority,
          lineIndex: lineIndex,
        ),
      );
    }
  }

  for (final match in RegExp(
    r'\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})\b',
  ).allMatches(line)) {
    var day = int.parse(match.group(1)!);
    var month = int.parse(match.group(2)!);
    final year = int.parse(match.group(3)!);
    if (month > 12 && day <= 12) {
      final swap = day;
      day = month;
      month = swap;
    }
    final date = _validDate(year, month, day);
    if (date != null) {
      result.add(
        _ReceiptDateCandidate(
          date: date,
          priority: priority,
          lineIndex: lineIndex,
        ),
      );
    }
  }

  for (final match in RegExp(
    r'\b(\d{1,2})\s+([A-Za-z]{3,9})\s*,?\s*(\d{2,4})\b',
    caseSensitive: false,
  ).allMatches(line)) {
    final month = _months[match.group(2)!.toLowerCase()];
    final date = month == null
        ? null
        : _validDate(
            int.parse(match.group(3)!),
            month,
            int.parse(match.group(1)!),
          );
    if (date != null) {
      result.add(
        _ReceiptDateCandidate(
          date: date,
          priority: priority,
          lineIndex: lineIndex,
        ),
      );
    }
  }

  for (final match in RegExp(
    r'\b([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{2,4})\b',
    caseSensitive: false,
  ).allMatches(line)) {
    final month = _months[match.group(1)!.toLowerCase()];
    final date = month == null
        ? null
        : _validDate(
            int.parse(match.group(3)!),
            month,
            int.parse(match.group(2)!),
          );
    if (date != null) {
      result.add(
        _ReceiptDateCandidate(
          date: date,
          priority: priority,
          lineIndex: lineIndex,
        ),
      );
    }
  }
  return result;
}

String? _merchantFromLines(List<String> lines) {
  final namedMerchant = RegExp(
    r'^(?:merchant|store|shop|restaurant|seller|vendor|name)\s*[:\-]\s*(.+)$',
    caseSensitive: false,
  );
  final generic = RegExp(
    r'^(?:paid|cash\s+receipt|receipt|invoice|bill|shop\s+name|store\s+name|merchant|thank\s+you|welcome|original|duplicate)$',
    caseSensitive: false,
  );
  final metadata = RegExp(
    r'\b(?:address|tel|phone|contact|date|time|cashier|gstin|manager|bill\s*(?:no|number)|invoice\s*(?:no|number)|qty|quantity|item|price|amount|subtotal|sub\s+total|total|tax|vat|paid|fssai|www\.|\.com)\b',
    caseSensitive: false,
  );

  for (final raw in lines.take(15)) {
    final line = _cleanLine(raw);
    final named = namedMerchant.firstMatch(line);
    final candidate = named?.group(1)?.trim() ?? line;
    if (candidate.isEmpty || generic.hasMatch(candidate)) continue;
    if (!RegExp(r'[A-Za-z]{3}').hasMatch(candidate)) continue;
    if (metadata.hasMatch(candidate)) continue;

    final digits = RegExp(r'\d').allMatches(candidate).length;
    final letters = RegExp(r'[A-Za-z]').allMatches(candidate).length;
    // Permit legitimate names such as 7-Eleven, but not phone numbers or
    // address-like rows dominated by digits.
    if (digits > letters) continue;
    if (candidate.length > 100) continue;
    return candidate;
  }
  return null;
}

/// Extracts all safely identifiable receipt fields from OCR lines.
ReceiptScanResult parseReceiptFields(List<String> rawLines) {
  final lines = rawLines
      .map(_cleanLine)
      .where((line) => line.isNotEmpty)
      .toList();
  final text = lines.join('\n');
  if (lines.isEmpty) return const ReceiptScanResult(looksLikeReceipt: false);

  // A subtotal is enough to recognize a partial receipt, but it must not
  // become the final amount when the payable total is missing.
  final hasTotal = RegExp(
    r'\b(?:sub\s*total|total)\b',
    caseSensitive: false,
  ).hasMatch(text);
  final hasMarker = _receiptMarkers.hasMatch(text);
  final hasDate = RegExp(
    r'\b\d{1,4}[./-]\d{1,2}[./-]\d{1,4}\b',
    caseSensitive: false,
  ).hasMatch(text);
  final looksLikeReceipt = hasTotal && (hasMarker || hasDate);
  if (!looksLikeReceipt) {
    return const ReceiptScanResult(looksLikeReceipt: false);
  }

  final totalCandidates = <_ReceiptTotalCandidate>[];
  for (var i = 0; i < lines.length; i++) {
    for (final label in _totalLabelsForLine(lines[i])) {
      final amount = _amountForLabel(lines, i, label.match);
      if (amount != null && amount > 0) {
        totalCandidates.add(
          _ReceiptTotalCandidate(
            amount: amount,
            rank: label.rank,
            lineIndex: i,
          ),
        );
      }
    }
  }
  totalCandidates.sort((a, b) {
    final rank = b.rank.compareTo(a.rank);
    return rank != 0 ? rank : b.lineIndex.compareTo(a.lineIndex);
  });
  final amount = totalCandidates.isEmpty ? null : totalCandidates.first.amount;

  final dateCandidates = <_ReceiptDateCandidate>[];
  for (var i = 0; i < lines.length; i++) {
    dateCandidates.addAll(_datesForLine(lines[i], i));
  }
  dateCandidates.sort((a, b) {
    final priority = b.priority.compareTo(a.priority);
    return priority != 0 ? priority : a.lineIndex.compareTo(b.lineIndex);
  });
  final date = dateCandidates.isEmpty ? null : dateCandidates.first.date;
  final merchant = _merchantFromLines(lines);
  final reasons = <String>[];
  if (totalCandidates.map((candidate) => candidate.amount).toSet().length > 1) {
    reasons.add(
      'Multiple bill totals were detected. Verify the final payable amount.',
    );
  }
  if (dateCandidates.map((candidate) => candidate.date).toSet().length > 1) {
    reasons.add('Multiple dates were detected. Verify the bill date.');
  }
  if (amount == null) {
    reasons.add('Could not identify the final payable amount.');
  }
  if (date == null) reasons.add('Could not identify the bill date.');
  if (merchant == null) reasons.add('Could not identify the merchant name.');

  return ReceiptScanResult(
    looksLikeReceipt: true,
    amountRupees: amount,
    date: date,
    merchant: merchant,
    reviewReasons: reasons,
  );
}

/// Null means this is not a receipt. An empty list means a receipt was found
/// but essential fields could not be read; never feed its item rows to the
/// statement parser in that case.
List<ParsedStatementLine>? parseReceiptLines(List<String> lines) {
  final result = parseReceiptFields(lines);
  if (!result.looksLikeReceipt) return null;
  final parsed = result.parsedLine;
  return parsed == null ? [] : [parsed];
}
