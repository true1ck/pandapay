import 'dart:typed_data';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

class StatementParseException implements Exception {
  final String message;
  const StatementParseException(this.message);
  @override
  String toString() => message;
}

/// Extracts a PDF text layer on-device. An empty result is intentional: it
/// lets the caller try the image/OCR path for scanned statements.
class PdfStatementReader {
  String extractText(Uint8List bytes, {String? password}) {
    late final PdfDocument document;
    try {
      document = PdfDocument(inputBytes: bytes, password: password);
    } catch (_) {
      throw const StatementParseException(
        "That password didn't work for this statement.",
      );
    }
    try {
      return PdfTextExtractor(document).extractText();
    } finally {
      document.dispose();
    }
  }
}

class ParsedStatementLine {
  final DateTime date;
  final String description;
  final Money amount;
  final bool isCredit;
  const ParsedStatementLine({
    required this.date,
    required this.description,
    required this.amount,
    this.isCredit = false,
  });
}

class ParsedStatement {
  final List<ParsedStatementLine> transactions;
  final Money? closingBalance;
  const ParsedStatement({required this.transactions, this.closingBalance});
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

DateTime? _dateFromMatch(RegExpMatch match) {
  int? day;
  int? month;
  int? year;
  if (match.group(1) != null) {
    day = int.tryParse(match.group(1)!);
    month = int.tryParse(match.group(2)!);
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

ParsedStatementLine? _parseTransactionBlock(String block) {
  final dateMatch = _dateAnywhere.firstMatch(block);
  if (dateMatch == null) return null;
  final date = _dateFromMatch(dateMatch);
  if (date == null) return null;

  final afterDate = block.substring(dateMatch.end).trim();
  final candidates = _amountToken.allMatches(afterDate).toList();
  if (candidates.isEmpty) return null;

  // In common bank table extraction, debit/credit is followed by a running
  // balance. With three numeric columns the middle value is the spend.
  final selected = candidates.length >= 3
      ? candidates[candidates.length - 2]
      : candidates.first;
  final amount = _parseAmount(selected.group(0)!);
  if (amount == null) return null;

  // Narration is the text before the first monetary column. This avoids
  // importing reference numbers or running balances as merchant names.
  final description = _cleanDescription(
    afterDate.substring(0, candidates.first.start),
  );
  if (description.isEmpty) return null;
  final isCredit = RegExp(
    r'\b(?:cr|credit)\b',
    caseSensitive: false,
  ).hasMatch(block);
  return ParsedStatementLine(
    date: date,
    description: description,
    amount: amount,
    isCredit: isCredit,
  );
}

/// Generic, conservative parser for bank/card statement text layers and OCR.
/// It supports common numeric/date variants, multi-line narrations, and the
/// usual debit/credit + running-balance column layout. Unsupported or
/// ambiguous lines are skipped instead of becoming invented transactions.
ParsedStatement parseStatementText(String text) {
  final transactions = <ParsedStatementLine>[];
  Money? closingBalance;
  String? block;

  void flush() {
    final candidate = block;
    block = null;
    if (candidate == null) return;
    final parsed = _parseTransactionBlock(candidate);
    if (parsed != null) transactions.add(parsed);
  }

  for (final raw in text.replaceAll('\r', '').split('\n')) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (_closingBalanceLine.hasMatch(line)) {
      flush();
      final amounts = _amountToken.allMatches(line).toList();
      if (amounts.isNotEmpty)
        closingBalance = _parseAmount(amounts.last.group(0)!);
      continue;
    }
    // Header rows such as "Statement Period" and "Card Number" can contain
    // date-like and numeric tokens. They are metadata, never transactions.
    if (RegExp(
      r'\b(?:statement\s+period|card\s+number|account\s+number|opening\s+balance)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      flush();
      continue;
    }
    if (_dateAnywhere.hasMatch(line)) {
      flush();
      block = line;
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
  );
}
