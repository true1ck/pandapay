import 'dart:convert';

import 'package:pandapay_domain/pandapay_domain.dart';

import 'statement_reconciler.dart';
import 'user_cards_repository.dart' show TxnInstrument;

enum ImportDateOrder { dayFirst, monthFirst }

enum ImportNumberFormat { decimalPoint, decimalComma }

/// Preserve spelling while coalescing repeated names from a file or picker.
List<String> normalizeImportedTagNames(Iterable<String> values) {
  final names = <String, String>{};
  for (final value in values) {
    final name = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isNotEmpty) names.putIfAbsent(name.toLowerCase(), () => name);
  }
  return List.unmodifiable(names.values);
}

/// JSON arrays make the export lossless even when names contain delimiters.
/// Other apps commonly separate their tag/label columns with ;, |, or commas.
List<String> parseImportedTagNames(String value) {
  final text = value.trim();
  if (text.isEmpty) return const [];
  if (text.startsWith('[')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        return normalizeImportedTagNames([
          for (final item in decoded)
            if (item is String) item
            else if (item is Map && item['name'] is String)
              item['name'] as String,
        ]);
      }
    } on FormatException {
      // A non-JSON source label remains an ordinary name below.
    }
  }
  return normalizeImportedTagNames(text.split(RegExp(r'[;|,]')));
}

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
  final List<String> tagNames;

  /// Explicit, user-selected catalogue assignment. `categoryId` is a built-in
  /// reporting category; `userCategoryId` is a private category/subcategory.
  /// These are deliberately separate from imported name hints, which may not
  /// belong to the signed-in account's taxonomy.
  final String? categoryId;
  final String? userCategoryId;
  final TxnInstrument? instrument;
  final String? rail;
  final String? note;
  final String status;
  final bool merchantNameMissing;
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
    this.tagNames = const [],
    this.categoryId,
    this.userCategoryId,
    this.instrument,
    this.rail,
    this.note,
    this.status = 'active',
    this.merchantNameMissing = false,
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
    List<String>? tagNames,
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
    tagNames: tagNames ?? this.tagNames,
    categoryId: categoryId,
    userCategoryId: userCategoryId,
    instrument: instrument,
    rail: rail,
    note: note,
    status: status,
    merchantNameMissing: description == null ? merchantNameMissing : false,
    sourceRowId: sourceRowId ?? this.sourceRowId,
    reviewReasons: const [],
  );
}

class ParsedStatement {
  final List<ParsedStatementLine> transactions;
  final Money? closingBalance;
  final List<String> warnings;
  final List<ImportRejectedRow> rejectedRows;
  final StatementReconciliationResult? reconciliation;
  const ParsedStatement({
    required this.transactions,
    this.closingBalance,
    this.warnings = const [],
    this.rejectedRows = const [],
    this.reconciliation,
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
  if ((row.bankReference?.length ?? 0) > 40 ||
      (row.bankReference?.isNotEmpty == true &&
          !RegExp(r'^[a-zA-Z0-9-]{6,40}$').hasMatch(row.bankReference!))) {
    return 'Bank reference must be 6–40 letters, numbers, or hyphens.';
  }
  if ((row.categoryHint?.length ?? 0) > 120 ||
      (row.subcategoryHint?.length ?? 0) > 120) {
    return 'Category names must be 120 characters or fewer.';
  }
  if ((row.note?.length ?? 0) > 500) {
    return 'Note must be 500 characters or fewer.';
  }
  if (!const {'active', 'ignored', 'deleted'}.contains(row.status)) {
    return 'Transaction status is not supported.';
  }
  if (row.tagNames.length > 30 || row.tagNames.any((name) => name.trim().isEmpty || name.length > 60)) {
    return 'Use up to 30 tags, each with 1–60 characters.';
  }
  if (row.reviewReasons.isNotEmpty) return row.reviewReasons.join(' ');
  return null;
}
