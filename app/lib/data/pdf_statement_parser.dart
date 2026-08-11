import 'dart:typed_data';

import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// F2 (ui-spec Statement PDF Import, GAP_ANALYSIS.md §3). Thrown for a
/// wrong/missing password on an encrypted PDF, or a file that isn't a
/// readable PDF at all — [StatementPdfImportScreen] shows this message
/// directly, so it's already user-facing plain language, not a raw
/// exception string.
class StatementParseException implements Exception {
  final String message;
  const StatementParseException(this.message);
  @override
  String toString() => message;
}

/// Bridges syncfusion_flutter_pdf's byte-level API to plain text. Kept
/// separate from [parseStatementText] below so the actual line-extraction
/// heuristic stays a pure function, unit-testable with plain strings
/// instead of a real PDF file.
class PdfStatementReader {
  /// Decrypts (if [password] is given) and extracts all text from the PDF
  /// at [bytes]. Never touches the network — entirely on-device, matching
  /// this screen's existing security note (the password is used only
  /// in-memory here, never sent anywhere, never logged).
  String extractText(Uint8List bytes, {String? password}) {
    late final PdfDocument document;
    try {
      document = PdfDocument(inputBytes: bytes, password: password);
    } catch (_) {
      // syncfusion throws a variety of internal exception types for "wrong
      // password" vs "not a valid PDF" vs "corrupted" — none of them are
      // meant to be shown to a user verbatim, and this screen only has one
      // actionable next step regardless (retry the password or pick a
      // different file), so they're collapsed into one message rather than
      // guessing which internal type means what.
      throw const StatementParseException("That password didn't work for this statement.");
    }
    try {
      final text = PdfTextExtractor(document).extractText();
      if (text.trim().isEmpty) {
        throw const StatementParseException(
          "Couldn't read any text from this PDF — it may be a scanned image.",
        );
      }
      return text;
    } finally {
      document.dispose();
    }
  }
}

/// One transaction line detected in the statement text.
class ParsedStatementLine {
  final DateTime date;
  final String description;
  final Money amount;
  const ParsedStatementLine({required this.date, required this.description, required this.amount});
}

class ParsedStatement {
  final List<ParsedStatementLine> transactions;
  final Money? closingBalance;
  const ParsedStatement({required this.transactions, this.closingBalance});
}

/// `DD/MM/YYYY` or `DD-MM-YYYY` (2- or 4-digit year) at the start of a
/// line, then a description, then an amount with optional thousands
/// commas and exactly 2 decimal places, then an optional Dr/Cr/DR/CR
/// suffix (ignored — this screen doesn't yet distinguish debits from
/// credits, matching its own "every detected line treated the same" scope
/// note in confirmStatementImport's caller).
final _transactionLine = RegExp(
  r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})\s+(.+?)\s+([\d,]+\.\d{2})\s*(?:Dr|Cr|DR|CR)?\s*$',
);

final _closingBalanceLine = RegExp(r'closing\s*balance\D*([\d,]+\.\d{2})', caseSensitive: false);

DateTime? _parseDate(String d, String m, String y) {
  final day = int.tryParse(d);
  final month = int.tryParse(m);
  var year = int.tryParse(y);
  if (day == null || month == null || year == null) return null;
  if (year < 100) year += 2000;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  try {
    return DateTime(year, month, day);
  } catch (_) {
    return null;
  }
}

Money? _parseAmount(String raw) {
  final cleaned = raw.replaceAll(',', '');
  final value = double.tryParse(cleaned);
  if (value == null) return null;
  return Money.fromRupees(value);
}

/// Heuristic, best-effort line extraction — deliberately NOT issuer-
/// specific column parsing (ui-spec F2's "issuer-specific column-layout
/// parsing per bank" is out of scope here, same as this screen's own
/// original doc-comment flagged; PDF table layouts vary far more than
/// SMS/email text ever does). A line that doesn't match the pattern is
/// silently skipped rather than surfaced as a parse error — a statement
/// with a mix of header/footer/summary text alongside transaction rows is
/// the normal case, not a failure, so only "found zero transactions at
/// all" is treated as worth surfacing (by the caller checking
/// `.transactions.isEmpty`, not by this function throwing).
ParsedStatement parseStatementText(String text) {
  final transactions = <ParsedStatementLine>[];
  Money? closingBalance;

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final balanceMatch = _closingBalanceLine.firstMatch(line);
    if (balanceMatch != null) {
      closingBalance = _parseAmount(balanceMatch.group(1)!) ?? closingBalance;
      continue;
    }

    final match = _transactionLine.firstMatch(line);
    if (match == null) continue;
    final date = _parseDate(match.group(1)!, match.group(2)!, match.group(3)!);
    final amount = _parseAmount(match.group(5)!);
    if (date == null || amount == null) continue;

    transactions.add(ParsedStatementLine(date: date, description: match.group(4)!.trim(), amount: amount));
  }

  return ParsedStatement(transactions: transactions, closingBalance: closingBalance);
}
