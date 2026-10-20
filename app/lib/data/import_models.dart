import 'package:pandapay_domain/pandapay_domain.dart';

enum ImportDateOrder { dayFirst, monthFirst }

enum ImportNumberFormat { decimalPoint, decimalComma }

enum ImportColumn {
  date,
  description,
  amount,
  debit,
  credit,
  direction,
  account,
  currency,
}

class StatementTableOptions {
  final ImportDateOrder dateOrder;
  final ImportNumberFormat numberFormat;
  final bool dateOrderConfirmed;
  final bool negativeIsExpense;
  final int? year;
  final int? headerRow;
  final Map<ImportColumn, int> columns;
  const StatementTableOptions({
    this.dateOrder = ImportDateOrder.dayFirst,
    this.numberFormat = ImportNumberFormat.decimalPoint,
    this.dateOrderConfirmed = false,
    this.negativeIsExpense = false,
    this.year,
    this.headerRow,
    this.columns = const {},
  });
}

class ImportRejectedRow {
  final String sourceRowId;
  final List<String> cells;
  final String reason;
  const ImportRejectedRow(this.sourceRowId, this.cells, this.reason);
}

class ParsedStatementLine {
  final DateTime date;
  final String description;
  final Money amount;
  final bool isCredit;
  final String? sourceAccount;
  final String? bankReference;
  final String? categoryHint;
  final String? subcategoryHint;
  final bool isTransfer;
  final bool isInvestment;
  final String? sourceRowId;
  final List<String> reviewReasons;
  const ParsedStatementLine({
    required this.date,
    required this.description,
    required this.amount,
    this.isCredit = false,
    this.sourceAccount,
    this.bankReference,
    this.categoryHint,
    this.subcategoryHint,
    this.isTransfer = false,
    this.isInvestment = false,
    this.sourceRowId,
    this.reviewReasons = const [],
  });

  ParsedStatementLine reviewed({
    DateTime? date,
    String? description,
    Money? amount,
    bool? isCredit,
    bool? isTransfer,
    bool? isInvestment,
    String? sourceRowId,
    String? categoryHint,
    String? subcategoryHint,
  }) => ParsedStatementLine(
    date: date ?? this.date,
    description: description ?? this.description,
    amount: amount ?? this.amount,
    isCredit: isCredit ?? this.isCredit,
    isTransfer: isTransfer ?? this.isTransfer,
    isInvestment: isInvestment ?? this.isInvestment,
    sourceAccount: sourceAccount,
    bankReference: bankReference,
    categoryHint: categoryHint ?? this.categoryHint,
    subcategoryHint: subcategoryHint ?? this.subcategoryHint,
    sourceRowId: sourceRowId ?? this.sourceRowId,
    reviewReasons: const [],
  );
}

class ParsedStatement {
  final List<ParsedStatementLine> transactions;
  final Money? closingBalance;
  final List<String> warnings;
  final List<ImportRejectedRow> rejectedRows;
  const ParsedStatement({
    required this.transactions,
    this.closingBalance,
    this.warnings = const [],
    this.rejectedRows = const [],
  });
}

/// The same guard is applied to every reviewed file/OCR row before submission.
String? validateImportedTransaction(ParsedStatementLine row) {
  if (row.amount.paise <= 0 || row.amount.paise > 999999999999) {
    return 'Amount must be positive and below ₹10 billion.';
  }
  if (row.date.year < 1900 || row.date.year > 2100) {
    return 'Choose a date between 1900 and 2100.';
  }
  if (row.description.trim().isEmpty || row.description.length > 500) {
    return 'Description must contain 1–500 characters.';
  }
  if ((row.sourceAccount?.length ?? 0) > 200) {
    return 'Source account label is too long. Adjust the account column.';
  }
  if (row.reviewReasons.isNotEmpty) return row.reviewReasons.join(' ');
  return null;
}
