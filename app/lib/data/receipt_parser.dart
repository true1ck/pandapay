import 'package:pandapay_domain/pandapay_domain.dart';

import 'import_models.dart';

/// Null means this is not a receipt. An empty list means a receipt was found
/// but essential fields could not be read; never feed its item rows to the
/// statement parser in that case.
List<ParsedStatementLine>? parseReceiptLines(List<String> lines) {
  final strongTotal = RegExp(
    r'\b(?:grand\s*total|net\s*(?:total|amount|payable)|total\s*(?:amount|payable)|amount\s*(?:due|payable)|balance\s*due)\b',
    caseSensitive: false,
  );
  final receiptMarker = RegExp(
    r'\b(?:gstin|cashier|bill\s*(?:no|number)|receipt|invoice|qty|quantity)\b',
    caseSensitive: false,
  );
  final text = lines.join('\n');
  if (!strongTotal.hasMatch(text) || !receiptMarker.hasMatch(text)) return null;

  final amounts = <double>[];
  final number = RegExp(
    r'(?:₹|rs\.?|inr)?\s*(\d[\d,]*(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
  for (var i = 0; i < lines.length; i++) {
    final label = strongTotal.firstMatch(lines[i]);
    if (label == null) continue;
    var value = lines[i].substring(label.end).trim();
    // ML Kit may emit the total as a separate line/block.
    if (value.isEmpty && i + 1 < lines.length) value = lines[i + 1];
    final match = number.firstMatch(value);
    if (match != null && value.substring(0, match.start).trim().isEmpty) {
      final amount = double.tryParse(match.group(1)!.replaceAll(',', ''));
      if (amount != null && amount > 0) amounts.add(amount);
    }
  }
  if (amounts.isEmpty) return [];

  final dates = <DateTime>[];
  for (final match in RegExp(
    r'\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})\b',
  ).allMatches(text)) {
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    var year = int.parse(match.group(3)!);
    if (year < 100) year += 2000;
    final date = DateTime(year, month, day);
    if (date.year == year && date.month == month && date.day == day) {
      dates.add(date);
    }
  }
  if (dates.isEmpty) return [];

  String? merchant;
  for (final line in lines.take(8)) {
    if (!RegExp(r'[a-zA-Z]{3}').hasMatch(line) ||
        RegExp(
          r'\d|\b(?:paid|receipt|invoice|tax|original|duplicate|welcome|date|cashier)\b',
          caseSensitive: false,
        ).hasMatch(line)) {
      continue;
    }
    merchant = line;
    break;
  }
  if (merchant == null) return [];
  return [
    ParsedStatementLine(
      date: dates.first,
      description: merchant,
      amount: Money.fromRupees(amounts.first),
      sourceRowId: 'receipt',
      reviewReasons: [
        if (amounts.toSet().length > 1)
          'Multiple bill totals were detected. Verify the final payable amount.',
        if (dates.toSet().length > 1)
          'Multiple dates were detected. Verify the bill date.',
      ],
    ),
  ];
}
