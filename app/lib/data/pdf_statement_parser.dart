import 'dart:typed_data';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'import_models.dart';
export 'import_models.dart';

class StatementParseException implements Exception {
  final String message;
  const StatementParseException(this.message);
  @override
  String toString() => message;
}

/// Extracts a PDF text layer on-device. An empty result is intentional: it
/// lets the caller try the image/OCR path for scanned statements.
class PdfStatementReader {
  String extractText(Uint8List bytes, {String? password}) =>
      extractPages(bytes, password: password).join('\n');

  List<String> extractPages(Uint8List bytes, {String? password}) {
    late final PdfDocument document;
    try {
      document = PdfDocument(inputBytes: bytes, password: password);
    } catch (_) {
      throw const StatementParseException(
        "That password didn't work for this statement.",
      );
    }
    try {
      final extractor = PdfTextExtractor(document);
      return [
        for (var i = 0; i < document.pages.count; i++)
          extractor.extractText(startPageIndex: i, endPageIndex: i),
      ];
    } finally {
      document.dispose();
    }
  }
}

// PDF text extraction commonly prefixes a row with a serial number or a
// table marker. Keep the same capture groups as [_dateAtStart], but allow the
// date to occur after that prefix instead of assuming a fixed table layout.
final _dateAnywhere = RegExp(
  r'(?:(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})|(\d{4})[./-](\d{1,2})[./-](\d{1,2})|(\d{1,2})[\s./-]+([A-Za-z]{3,9})[\s,./-]+(\d{2,4})|([A-Za-z]{3,9})[\s-]+(\d{1,2}),?[\s-]+(\d{2,4}))\b',
  caseSensitive: false,
);

// Currency symbols/codes and decimal numbers make a strong candidate. Plain
// integers are also accepted because many bank PDFs omit .00.
final _amountToken = RegExp(
  r'(?:(?:₹|rs\.?|inr)\s*)?[\(\-]?\s*\d[\d,]*(?:\.\d{1,2})?\s*\)?\s*(?:dr|cr|debit|credit)?\b',
  caseSensitive: false,
);

final _closingBalanceLine = RegExp(
  r'\b(?:closing|ending)\s+balance\b',
  caseSensitive: false,
);
final _monthNames = <String, int>{
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

DateTime? _dateFromMatch(RegExpMatch match, StatementTableOptions options) {
  int? day;
  int? month;
  int? year;
  if (match.group(1) != null) {
    day = int.tryParse(match.group(1)!);
    month = int.tryParse(match.group(2)!);
    if (options.dateOrder == ImportDateOrder.monthFirst &&
        day != null &&
        month != null &&
        (options.dateOrderConfirmed || day <= 12)) {
      final swap = day;
      day = month;
      month = swap;
    }
    year = int.tryParse(match.group(3)!);
  } else if (match.group(4) != null) {
    year = int.tryParse(match.group(4)!);
    month = int.tryParse(match.group(5)!);
    day = int.tryParse(match.group(6)!);
  } else if (match.group(7) != null) {
    day = int.tryParse(match.group(7)!);
    month = _monthNames[match.group(8)!.toLowerCase()];
    year = int.tryParse(match.group(9)!);
  } else {
    month = _monthNames[match.group(10)!.toLowerCase()];
    day = int.tryParse(match.group(11)!);
    year = int.tryParse(match.group(12)!);
  }
  if (day == null || month == null || year == null) return null;
  if (year < 100) year += 2000;
  if (day < 1 || day > 31 || month < 1 || month > 12) return null;
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

Money? _parseAmount(String raw) {
  var cleaned = raw.toLowerCase().replaceAll(
    RegExp(r'₹|rs\.?|inr|dr|cr|debit|credit'),
    '',
  );
  cleaned = cleaned.replaceAll(',', '').replaceAll(' ', '').trim();
  if (cleaned.startsWith('(') && cleaned.endsWith(')')) {
    cleaned = cleaned.substring(1, cleaned.length - 1);
  }
  final value = double.tryParse(cleaned.replaceFirst('-', ''));
  return value == null ? null : Money.fromRupees(value.abs());
}

String _cleanDescription(String value) {
  return value
      .replaceAll(RegExp(r'[|:_\-]+\s*$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

ParsedStatementLine? _parseTransactionBlock(
  String block,
  StatementTableOptions options,
) {
  if (RegExp(r'\b(?:TOTAL AMOUNT|TOP MERCHANTS|FROM:|TO:)').hasMatch(block)) {
    return null;
  }
  final dateMatch = _dateAnywhere.firstMatch(block);
  if (dateMatch == null) return null;
  var date = _dateFromMatch(dateMatch, options);
  if (date == null) return null;
  final time = RegExp(
    r'^\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?',
    caseSensitive: false,
  ).firstMatch(block.substring(dateMatch.end));
  if (time != null) {
    var hour = int.parse(time.group(1)!);
    final minute = int.parse(time.group(2)!);
    final second = int.parse(time.group(3) ?? '0');
    final period = time.group(4)?.toUpperCase();
    if (minute > 59 ||
        second > 59 ||
        (period == null ? hour > 23 : hour < 1 || hour > 12)) {
      return null;
    }
    if (period != null) hour = hour % 12 + (period == 'PM' ? 12 : 0);
    date = DateTime(date.year, date.month, date.day, hour, minute, second);
  }

  final reasons = <String>[];
  if (dateMatch.group(1) != null &&
      !options.dateOrderConfirmed &&
      int.parse(dateMatch.group(1)!) <= 12 &&
      int.parse(dateMatch.group(2)!) <= 12 &&
      dateMatch.group(1) != dateMatch.group(2)) {
    reasons.add('Confirm day/month order in Formats, or edit the date.');
  }
  // Time is not an amount. Export tables frequently wrap AM/PM onto a line.
  final afterDate = block
      .substring(dateMatch.end)
      .replaceFirst(
        RegExp(
          r'^\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\b(?:AM|PM)\b', caseSensitive: false), '')
      .trim();
  final directed = RegExp(
    r'(?:(?:₹|INR|Rs\.?)\s*)?(\d[\d,]*(?:\.\d{1,2})?)\s+(DR|CR)\b',
    caseSensitive: false,
  ).firstMatch(afterDate);
  if (directed != null) {
    final description = _cleanDescription(
      afterDate.substring(0, directed.start),
    );
    final amount = _parseAmount(directed.group(1)!);
    if (description.isEmpty || amount == null || amount.paise <= 0) return null;
    final tail = afterDate.substring(directed.end).trim();
    // Axio exports identify the source account, followed by expense/income flags.
    final account = RegExp(
      r'^(.*?)\s+(Yes|No|-)\s+(Yes|No|-)\s+',
      caseSensitive: false,
    ).firstMatch(tail);
    return ParsedStatementLine(
      date: date,
      description: description,
      amount: amount,
      isCredit: directed.group(2)!.toUpperCase() == 'CR',
      sourceAccount: account?.group(1)?.trim(),
      reviewReasons: reasons,
      isTransfer: account != null
          ? account.group(2)!.toLowerCase() == 'no'
          : RegExp(
              r'\b(?:TRANSFER|CREDIT CARD BILL PAYMENT|REPAYMENT)\b',
              caseSensitive: false,
            ).hasMatch(description),
      isInvestment: RegExp(
        r'\b(?:MUTUAL FUND|SIP|INVESTMENT)\b',
        caseSensitive: false,
      ).hasMatch(description),
    );
  }
  final candidates = _amountToken.allMatches(afterDate).toList();
  if (candidates.isEmpty) return null;

  // In common bank table extraction, debit/credit is followed by a running
  // balance. With three numeric columns the middle value is the spend.
  final selected = candidates.length >= 3
      ? candidates[candidates.length - 2]
      : candidates.first;
  final amount = _parseAmount(selected.group(0)!);
  if (amount == null || amount.paise <= 0) return null;

  // Narration is the text before the first monetary column. This avoids
  // importing reference numbers or running balances as merchant names.
  final description = _cleanDescription(
    afterDate.substring(0, candidates.first.start),
  );
  if (description.isEmpty) return null;
  final isCredit = RegExp(
    r'\b(?:cr|credit)\b',
    caseSensitive: false,
  ).hasMatch(selected.group(0)!);
  return ParsedStatementLine(
    date: date,
    description: description,
    amount: amount,
    isCredit: isCredit,
    isInvestment: RegExp(
      r'\b(?:MUTUAL FUND|SIP|INVESTMENT)\b',
      caseSensitive: false,
    ).hasMatch(description),
    reviewReasons: [
      ...reasons,
      if (candidates.length > 1)
        'Multiple numeric columns detected. Verify the amount using Edit.',
    ],
  );
}

/// Generic, conservative parser for bank/card statement text layers and OCR.
/// It supports common numeric/date variants, multi-line narrations, and the
/// usual debit/credit + running-balance column layout. Unsupported or
/// ambiguous lines are skipped instead of becoming invented transactions.
ParsedStatement parseStatementText(
  String text, {
  StatementTableOptions options = const StatementTableOptions(),
}) {
  final transactions = <ParsedStatementLine>[];
  Money? closingBalance;
  String? block;
  String? sourceRowId;
  final rejected = <ImportRejectedRow>[];

  void flush() {
    final candidate = block;
    block = null;
    if (candidate == null) return;
    final parsed = _parseTransactionBlock(candidate, options);
    if (parsed != null) {
      transactions.add(
        ParsedStatementLine(
          date: parsed.date,
          description: parsed.description,
          amount: parsed.amount,
          isCredit: parsed.isCredit,
          isTransfer: parsed.isTransfer,
          isInvestment: parsed.isInvestment,
          sourceAccount: parsed.sourceAccount,
          sourceRowId: sourceRowId,
          reviewReasons: parsed.reviewReasons,
        ),
      );
    } else if (candidate
            .substring(
              _dateAnywhere.firstMatch(candidate)?.end ?? candidate.length,
            )
            .trim()
            .isNotEmpty &&
        !RegExp(
          r'\b(?:TOTAL AMOUNT|TOP MERCHANTS|FROM:|TO:)',
          caseSensitive: false,
        ).hasMatch(candidate)) {
      rejected.add(
        ImportRejectedRow(
          sourceRowId ?? 'pdf:unknown',
          [candidate],
          'Could not safely identify this dated row. Correct its date, description, and amount.',
        ),
      );
    }
  }

  var lineNumber = 0;
  for (final raw in text.replaceAll('\r', '').split('\n')) {
    lineNumber++;
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) continue;
    if (_closingBalanceLine.hasMatch(line)) {
      flush();
      final amounts = _amountToken.allMatches(line).toList();
      if (amounts.isNotEmpty) {
        closingBalance = _parseAmount(amounts.last.group(0)!);
      }
      continue;
    }
    if (RegExp(
      r'^(?:DATE|PLACE|AMOUNT|DR/CR|ACCOUNT|EXPENSE|INCOME|CATEGORY|TAGS|NOTE|RECEIPT)$',
      caseSensitive: false,
    ).hasMatch(line)) {
      flush();
      continue;
    }
    // Header rows such as "Statement Period" and "Card Number" can contain
    // date-like and numeric tokens. They are metadata, never transactions.
    if (RegExp(
      r'\b(?:statement\s+period|card\s+number|account\s+number|opening\s+balance|FROM\s*:|TO\s*:|TOTAL\s+AMOUNT|TOP\s+MERCHANTS|PAGE\s+\d+)',
      caseSensitive: false,
    ).hasMatch(line)) {
      flush();
      continue;
    }
    if (_dateAnywhere.hasMatch(line)) {
      flush();
      block = line;
      sourceRowId = 'pdf:line:$lineNumber';
    } else if (block != null) {
      // Table extraction often puts narration and numeric columns on separate
      // lines. Keep continuation text attached to the preceding date row.
      block = '$block $line';
    }
  }
  flush();

  return ParsedStatement(
    transactions: transactions,
    closingBalance: closingBalance,
    rejectedRows: rejected,
  );
}
