import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'csv_statement_parser.dart';
import 'import_models.dart';
import 'import_repository.dart';
import 'pdf_statement_parser.dart'
    show parseStatementText, StatementParseException;
import 'spreadsheet_statement_parser.dart';

enum ImportDocumentKind { pdf, spreadsheet, delimited, json }

/// Format adapters end here. Review and ingestion operate on one transaction model.
class ImportDocument {
  static const maxFileBytes = 20 * 1024 * 1024;
  final Uint8List bytes;
  final String name;
  final ImportDocumentKind kind;
  final String digest;
  Map<String, List<List<String>>>? _tables;
  String? pdfText;
  final List<String> extractionWarnings = [];

  ImportDocument._(this.bytes, this.name, this.kind)
    : digest = sha256.convert(bytes).toString();

  factory ImportDocument.open(Uint8List bytes, String name) {
    if (bytes.isEmpty) {
      throw const StatementParseException(
        'This file is empty. Export the transaction history again.',
      );
    }
    if (bytes.length > maxFileBytes) {
      throw const StatementParseException(
        'This file exceeds 20 MB. Export a smaller date range.',
      );
    }
    final prefix = latin1.decode(bytes.take(1024).toList());
    final lower = name.toLowerCase();
    if (prefix.contains('%PDF-')) {
      return ImportDocument._(bytes, name, ImportDocumentKind.pdf);
    }
    if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b) {
      final document = ImportDocument._(
        bytes,
        name,
        ImportDocumentKind.spreadsheet,
      );
      document._tables = readSpreadsheetTables(bytes);
      if (document._tables!.isEmpty) {
        throw const StatementParseException(
          'This ZIP file is not an Excel transaction workbook. Choose XLSX or CSV.',
        );
      }
      return document;
    }
    if (bytes.length >= 4 && bytes[0] == 0xd0 && bytes[1] == 0xcf) {
      throw const StatementParseException(
        'Legacy or encrypted Excel files cannot be read. Export an unencrypted XLSX or CSV file.',
      );
    }
    if (lower.endsWith('.pdf') || lower.endsWith('.xlsx')) {
      throw const StatementParseException(
        'The file contents do not match its format. Export it again; renaming the extension is not enough.',
      );
    }
    final text = decodeStatementBytes(bytes).trimLeft();
    if (text.startsWith('<')) {
      throw const StatementParseException(
        'This is an XML or HTML export. For SMS backups use Import SMS backup; for spending export CSV or XLSX.',
      );
    }
    return ImportDocument._(
      bytes,
      name,
      text.startsWith('[') || text.startsWith('{')
          ? ImportDocumentKind.json
          : ImportDocumentKind.delimited,
    );
  }

  Map<String, List<List<String>>> get tables => _tables ??= switch (kind) {
    ImportDocumentKind.spreadsheet => readSpreadsheetTables(bytes),
    ImportDocumentKind.delimited => {
      'table': readDelimitedRows(decodeStatementBytes(bytes)),
    },
    ImportDocumentKind.json => {'json': _jsonRows(decodeStatementBytes(bytes))},
    ImportDocumentKind.pdf => {},
  };

  ParsedStatement parse({
    StatementTableOptions options = const StatementTableOptions(),
    Map<String, StatementTableOptions> tableOptions = const {},
  }) {
    if (kind == ImportDocumentKind.pdf) {
      final parsed = parseStatementText(pdfText ?? '', options: options);
      return ParsedStatement(
        transactions: parsed.transactions,
        closingBalance: parsed.closingBalance,
        rejectedRows: parsed.rejectedRows,
        warnings: [...parsed.warnings, ...extractionWarnings],
      );
    }
    final rows = <ParsedStatementLine>[];
    final rejected = <ImportRejectedRow>[];
    final warnings = <String>[];
    for (final entry in tables.entries) {
      final parsed = parseStatementRows(
        entry.value,
        options: tableOptions[entry.key] ?? options,
        sourceId: entry.key,
      );
      rows.addAll(parsed.transactions);
      rejected.addAll(parsed.rejectedRows);
      warnings.addAll(parsed.warnings);
    }
    return ParsedStatement(
      transactions: rows,
      rejectedRows: rejected,
      warnings: warnings,
    );
  }

  String get importSource => switch (kind) {
    ImportDocumentKind.pdf => 'statement',
    ImportDocumentKind.spreadsheet => 'xlsx',
    ImportDocumentKind.json => 'json',
    ImportDocumentKind.delimited => 'csv',
  };
}

List<List<String>> _jsonRows(String input) {
  final value = jsonDecode(input);
  final records = value is List
      ? value
      : value is Map
      ? value['transactions'] ?? value['expenses'] ?? value['data']
      : null;
  if (records is! List || records.any((row) => row is! Map)) {
    throw const StatementParseException(
      'Choose a JSON list of transaction objects, or an export with a transactions/expenses/data list.',
    );
  }
  final headers = <String>{
    for (final row in records.cast<Map>())
      ...row.keys.map((key) => key.toString()),
  }.toList();
  return [
    headers,
    for (final row in records.cast<Map>())
      [
        for (final key in headers)
          row[key] == null
              ? ''
              : row[key] is Map || row[key] is List
              ? ''
              : row[key].toString(),
      ],
  ];
}

class ImportProgress {
  final int added;
  final int duplicates;
  final int alreadyImported;
  final int completedBatches;
  final int totalBatches;
  const ImportProgress({
    this.added = 0,
    this.duplicates = 0,
    this.alreadyImported = 0,
    this.completedBatches = 0,
    this.totalBatches = 0,
  });
  String get description =>
      '$added added · $duplicates need duplicate review · $alreadyImported already imported';
}

/// Owns the review decision for every row, regardless of file/OCR adapter.
/// Source locations, not parsed-list positions, define retry identities.
class TransactionImportSession {
  static const unknownAccount = 'Unspecified account';
  static const batchSize = 250;
  static const batchBytes = 64 * 1024;
  final String fileDigest;
  final String importSource;
  final ParsedStatement statement;
  late final List<ParsedStatementLine> rows;
  final Set<int> excluded = {};
  final Map<String, String> destinations = {};
  final Map<String, StatementImport> _completed = {};
  bool submitting = false;
  bool _submissionStarted = false;
  bool get reviewLocked => _submissionStarted;
  ImportProgress progress = const ImportProgress();

  TransactionImportSession({
    required this.fileDigest,
    required this.importSource,
    required this.statement,
  }) {
    rows = List.of(statement.transactions);
    final seen = <String>{};
    final today = DateTime.now();
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final identity =
          '${row.date.toIso8601String()}|${row.amount.paise}|${row.description.trim().toLowerCase()}|${accountFor(row)}|${row.isCredit}|${row.isTransfer}|${row.bankReference?.toUpperCase()}';
      final isRepeat = !seen.add(identity);
      final possibleCredit =
          !row.isCredit &&
          !row.isTransfer &&
          RegExp(
            r'\b(?:salary|refund|cashback|reversal|account transfer|credit card bill payment|repayment)\b',
            caseSensitive: false,
          ).hasMatch(row.description);
      final future = row.date.isAfter(
        DateTime(today.year, today.month, today.day + 1),
      );
      if (isRepeat || future || possibleCredit) {
        rows[i] = ParsedStatementLine(
          date: row.date,
          description: row.description,
          amount: row.amount,
          isCredit: row.isCredit,
          isTransfer: row.isTransfer,
          sourceAccount: row.sourceAccount,
          bankReference: row.bankReference,
          sourceRowId: row.sourceRowId,
          reviewReasons: [
            ...row.reviewReasons,
            if (isRepeat)
              'Repeated date, amount and merchant. Use Edit to confirm a separate purchase, or leave excluded.',
            if (future)
              'This date is in the future. Verify it using Edit before importing.',
            if (possibleCredit)
              'This may be income, a refund or a transfer. Verify its type using Edit.',
          ],
        );
      }
    }
    for (var i = 0; i < rows.length; i++) {
      if (!eligible(i)) excluded.add(i);
    }
  }

  String accountFor(ParsedStatementLine row) =>
      row.sourceAccount?.trim().isNotEmpty == true
      ? row.sourceAccount!.trim()
      : unknownAccount;
  Set<String> get accounts => rows
      .where((row) => !row.isCredit && !row.isTransfer)
      .map(accountFor)
      .toSet();
  bool eligible(int index) =>
      !rows[index].isCredit &&
      !rows[index].isTransfer &&
      validateImportedTransaction(rows[index]) == null;
  List<int> get selected => [
    for (var i = 0; i < rows.length; i++)
      if (!excluded.contains(i) && eligible(i)) i,
  ];
  int get selectedPaise =>
      selected.fold(0, (sum, i) => sum + rows[i].amount.paise);
  bool get ready =>
      selected.isNotEmpty &&
      selected.every((i) => destinations.containsKey(accountFor(rows[i])));
  String location(int index) => rows[index].sourceRowId ?? 'row:$index';
  String rowKey(int index) => sha256
      .convert(
        utf8.encode(
          location(index).startsWith('image:')
              ? location(index)
              : '$fileDigest:${location(index)}',
        ),
      )
      .toString();

  void replaceRow(int index, ParsedStatementLine row) {
    if (reviewLocked) {
      throw StateError('Finish or retry this import before editing rows.');
    }
    rows[index] = row.reviewed(sourceRowId: location(index));
    if (eligible(index)) {
      excluded.remove(index);
    } else {
      excluded.add(index);
    }
  }

  void addCorrectedRow(ImportRejectedRow rejected, ParsedStatementLine row) {
    if (reviewLocked) {
      throw StateError('Finish or retry this import before editing rows.');
    }
    if (rows.any((r) => r.sourceRowId == rejected.sourceRowId)) {
      throw StateError('This row has already been corrected.');
    }
    rows.add(row.reviewed(sourceRowId: rejected.sourceRowId));
  }

  bool get hasCommittedBatches => _completed.isNotEmpty;

  StatementTransactionInput inputFor(int index) => StatementTransactionInput(
    occurredAt: rows[index].date,
    amount: rows[index].amount,
    merchantName: rows[index].description,
    bankReference: rows[index].bankReference,
    importRowKey: rowKey(index),
    sourceAccount: rows[index].sourceAccount?.replaceAllMapped(
      RegExp(r'\d{6,}'),
      (match) => '****${match[0]!.substring(match[0]!.length - 4)}',
    ),
  );

  Future<ImportProgress> submit(
    ImportRepository repository, {
    void Function(ImportProgress)? onProgress,
  }) async {
    if (submitting) throw StateError('An import is already in progress.');
    if (!ready) {
      throw StateError(
        'Select valid spending and map every selected source account.',
      );
    }
    _submissionStarted = true;
    submitting = true;
    try {
      final groups = <String, List<int>>{};
      for (final i in selected) {
        groups.putIfAbsent(accountFor(rows[i]), () => []).add(i);
      }
      final batches = <({String account, List<int> indices})>[];
      var planned = 0;
      for (final entry in groups.entries) {
        final indices = entry.value
          ..sort((a, b) => location(a).compareTo(location(b)));
        var pending = <int>[];
        var bytes =
            1024; // Leave room for batch metadata under Express's 100 KB limit.
        for (final index in indices) {
          final rowBytes =
              utf8.encode(jsonEncode(inputFor(index).toJson())).length + 1;
          if (pending.isNotEmpty &&
              (pending.length >= batchSize || bytes + rowBytes > batchBytes)) {
            batches.add((account: entry.key, indices: pending));
            pending = [];
            bytes = 1024;
          }
          pending.add(index);
          bytes += rowBytes;
          if (++planned % 1000 == 0) await Future<void>.delayed(Duration.zero);
        }
        if (pending.isNotEmpty) {
          batches.add((account: entry.key, indices: pending));
        }
      }
      void report() {
        progress = ImportProgress(
          added: _completed.values.fold(
            0,
            (sum, batch) => sum + batch.addedCount,
          ),
          duplicates: _completed.values.fold(
            0,
            (sum, batch) => sum + batch.pendingDuplicateCount,
          ),
          alreadyImported: _completed.values.fold(
            0,
            (sum, batch) => sum + batch.exactRetryCount,
          ),
          completedBatches: _completed.length,
          totalBatches: batches.length,
        );
        onProgress?.call(progress);
      }

      report();
      for (final batch in batches) {
        final destination = destinations[batch.account]!;
        final key = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  fileDigest,
                  destination,
                  batch.indices.map(rowKey).toList(),
                ]),
              ),
            )
            .toString();
        if (_completed.containsKey(key)) continue;
        final dates = batch.indices.map((i) => rows[i].date).toList()..sort();
        final imported = await repository.confirmStatementImport(
          userCardId: destination.isEmpty ? null : destination,
          statementFrom: dates.first,
          statementTo: dates.last,
          closingBalance: batches.length == 1 ? statement.closingBalance : null,
          txnCount: batch.indices.length,
          reconciledCount: 0,
          importSource: importSource,
          importKey: key,
          transactions: [for (final i in batch.indices) inputFor(i)],
        );
        _completed[key] = imported;
        report();
      }
      return progress;
    } finally {
      submitting = false;
    }
  }
}
