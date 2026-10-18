import 'pdf_statement_parser.dart';
import 'receipt_parser.dart';

class ScreenshotCategorySummary {
  final String category;
  final int spendCount;
  final double totalRupees;
  const ScreenshotCategorySummary({
    required this.category,
    required this.spendCount,
    required this.totalRupees,
  });
}

class ParsedSpendingScreenshot {
  final List<ParsedStatementLine> transactions;
  final double? totalSpendRupees;
  final String? periodLabel;
  final List<ScreenshotCategorySummary> categorySummaries;

  const ParsedSpendingScreenshot({
    required this.transactions,
    this.totalSpendRupees,
    this.periodLabel,
    this.categorySummaries = const [],
  });

  bool get isSummaryOnly =>
      transactions.isEmpty &&
      (categorySummaries.isNotEmpty || totalSpendRupees != null);
}

final _spendTotal = RegExp(
  r'\bspends?\s+(?:₹|rs\.?|inr)?\s*([\d,]+(?:\.\d{1,2})?)',
  caseSensitive: false,
);
final _count = RegExp(r'\b(\d+)\s+spends?\b', caseSensitive: false);
final _amount = RegExp(
  r'(?:₹|rs\.?|inr)\s*([\d,]+(?:\.\d{1,2})?)',
  caseSensitive: false,
);

double? _number(String? value) =>
    value == null ? null : double.tryParse(value.replaceAll(',', ''));

ParsedSpendingScreenshot parseSpendingScreenshotText(String text) {
  final lines = text
      .replaceAll('\r', '')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final statement = parseStatementText(text);
  final total = _spendTotal.firstMatch(text);
  final summaries = <ScreenshotCategorySummary>[];

  for (var i = 0; i < lines.length; i++) {
    final countMatch = _count.firstMatch(lines[i]);
    if (countMatch == null) continue;
    String? category;
    for (var previous = i - 1; previous >= 0 && previous >= i - 3; previous--) {
      final candidate = lines[previous];
      if (!RegExp(
        r'\b(?:spends?|₹|rs\.?|inr|categories?)\b',
        caseSensitive: false,
      ).hasMatch(candidate)) {
        category = candidate;
        break;
      }
    }
    if (category == null) continue;
    double? amount;
    for (var next = i; next < lines.length && next <= i + 3; next++) {
      amount ??= _number(_amount.firstMatch(lines[next])?.group(1));
    }
    if (amount == null) continue;
    summaries.add(
      ScreenshotCategorySummary(
        category: category,
        spendCount: int.parse(countMatch.group(1)!),
        totalRupees: amount,
      ),
    );
  }

  return ParsedSpendingScreenshot(
    transactions: parseReceiptLines(lines) ?? statement.transactions,
    totalSpendRupees: _number(total?.group(1)),
    periodLabel: _firstPeriodLabel(lines),
    categorySummaries: summaries,
  );
}

String? _firstPeriodLabel(List<String> lines) {
  final month = RegExp(
    r'\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\b',
    caseSensitive: false,
  );
  for (final line in lines) {
    if (month.hasMatch(line)) return line;
  }
  return null;
}
