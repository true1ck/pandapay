import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'api_exception.dart';
import 'csv_statement_parser.dart';
import 'import_models.dart';
import 'import_repository.dart';
import 'user_cards_repository.dart';
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
  final Map<int, String> savedDuplicates = {};
  final Set<int> _confirmedSeparate = {};

  /// Candidates are deliberately described as possible matches, never proof.
  void checkSavedDuplicates(List<TransactionEntry> existing) {
    savedDuplicates.clear();
    String merchant(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    const maxTransactionTimeDifference = Duration(minutes: 10);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (_confirmedSeparate.contains(i)) {
        continue;
      }
      final destination = destinations[accountFor(row)];
      if (destination == null) continue;
      final instrument = instruments[accountFor(row)];
      final userCardId =
          destination.isEmpty || destination.startsWith('instrument:')
          ? null
          : destination;
      final kind = row.isTransfer
          ? TxnEntryKind.transfer
          : row.isInvestment
          ? TxnEntryKind.investment
          : row.isCredit
          ? TxnEntryKind.income
          : TxnEntryKind.spend;
      final saved = existing.cast<TransactionEntry?>().firstWhere((candidate) {
        if (candidate == null || candidate.status != 'active') return false;
        final timeDifference = candidate.occurredAt
            .toLocal()
            .difference(row.date)
            .abs();
        return candidate.amount.paise == row.amount.paise &&
            timeDifference <= maxTransactionTimeDifference &&
            merchant(candidate.merchantName ?? '') ==
                merchant(row.description) &&
            candidate.userCardId == userCardId &&
            (instrument == null || candidate.instrument == instrument) &&
            candidate.entryKind == kind;
      }, orElse: () => null);
      if (saved != null) {
        savedDuplicates[i] =
            'Possible duplicate of saved ${saved.entryKind.label.toLowerCase()} transaction ${saved.id}: exact amount, merchant and account, within 10 minutes. Review it, keep both, edit or skip it.';
      }
    }
  }

  String? exclusionReason(int index) {
    final row = rows[index];
    final reasons = <String>[
      if (validateImportedTransaction(row) case final String issue) issue,
      if (savedDuplicates[index] case final String issue) issue,
    ];
    if (reasons.isNotEmpty) return reasons.join('\n');
    return excluded.contains(index)
        ? 'Skipped by you. Select this row to include it again.'
        : null;
  }

  final Map<String, String> destinations = {};
  final Map<String, String> destinationNotes = {};
  final Map<String, TxnInstrument> instruments = {};
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
    final today = DateTime.now();
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final future = row.date.isAfter(
        DateTime(today.year, today.month, today.day + 1),
      );
      if (future && row.reviewReasons.isEmpty) {
        rows[i] = ParsedStatementLine(
          date: row.date,
          description: row.description,
          amount: row.amount,
          isCredit: row.isCredit,
          isTransfer: row.isTransfer,
          isInvestment: row.isInvestment,
          sourceAccount: row.sourceAccount,
          bankReference: row.bankReference,
          sourceRowId: row.sourceRowId,
          reviewReasons: [
            ...row.reviewReasons,
            if (future)
              'This date is in the future. Verify it using Edit before importing.',
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
  Set<String> get accounts => rows.map(accountFor).toSet();

  /// Infer a source instrument conservatively. Card linking requires a unique
  /// exact last-four match; cash, UPI/bank and wallet labels are safe defaults.
  /// Ambiguous sources remain editable and import as unlinked "other".
  void suggestDestinations(
    List<UserCard> cards, {
    List<BankAccountSummary> bankAccounts = const [],
  }) {
    for (final account in accounts) {
      if (destinations.containsKey(account)) {
        if (destinations[account]!.isEmpty) {
          destinations[account] = 'instrument:other';
          instruments[account] ??= TxnInstrument.other;
          destinationNotes[account] ??=
              'No linked account selected. This will import as an unlinked transaction.';
        }
        continue;
      }
      final lower = account.toLowerCase();
      final suffixes = RegExp(
        r'(?<!\d)\d{4}(?!\d)',
      ).allMatches(account).map((match) => match.group(0)!).toSet();
      final matches = cards.where((card) {
        final last4 = card.last4?.replaceAll(RegExp(r'\D'), '');
        return last4 != null && suffixes.contains(last4);
      }).toList();
      final bankMatches = bankAccounts.where((bank) {
        final last4 = bank.accountLast4.replaceAll(RegExp(r'\D'), '');
        if (!suffixes.contains(last4)) return false;
        final issuers = [bank.issuerName, bank.issuerShortName, bank.issuerSlug]
            .whereType<String>()
            .expand(
              (value) => RegExp(r'[a-z0-9]+').allMatches(value.toLowerCase()),
            )
            .map((match) => match.group(0)!)
            .where((value) => value.length >= 3)
            .toSet();
        final sourceTokens = RegExp(
          r'[a-z0-9]+',
        ).allMatches(lower).map((match) => match.group(0)!).toSet();
        return issuers.isEmpty || issuers.intersection(sourceTokens).isNotEmpty;
      }).toList();
      if (matches.length == 1) {
        final card = matches.single;
        destinations[account] = card.id;
        instruments[account] = card.cardType == 'credit'
            ? TxnInstrument.creditCard
            : TxnInstrument.debitCard;
        destinationNotes[account] =
            'Matched to ${card.nickname?.isNotEmpty == true ? card.nickname : card.cardName} by card ending ${card.last4}.';
      } else if (bankMatches.length == 1) {
        final bank = bankMatches.single;
        destinations[account] = 'instrument:upi_bank';
        instruments[account] = TxnInstrument.upiBank;
        final issuer = bank.issuerShortName ?? bank.issuerName ?? 'bank';
        destinationNotes[account] =
            'Matched to your $issuer account ending ${bank.accountLast4}, seen in your imported bank messages.';
      } else if (RegExp(r'\bcash\b').hasMatch(lower)) {
        destinations[account] = 'instrument:cash';
        instruments[account] = TxnInstrument.cash;
        destinationNotes[account] = 'Detected cash from the statement source.';
      } else if (RegExp(r'\b(?:upi|vpa|imps|neft|rtgs)\b').hasMatch(lower)) {
        destinations[account] = 'instrument:upi_bank';
        instruments[account] = TxnInstrument.upiBank;
        destinationNotes[account] =
            'Detected UPI or bank payment from the statement source.';
      } else if (RegExp(
        r'\b(?:wallet|paytm|phonepe wallet|amazon pay)\b',
      ).hasMatch(lower)) {
        destinations[account] = 'instrument:wallet';
        instruments[account] = TxnInstrument.wallet;
        destinationNotes[account] =
            'Detected a digital wallet from the statement source.';
      } else if (matches.isEmpty &&
          RegExp(r'\b(?:bank|savings|current account|a/c)\b').hasMatch(lower)) {
        destinations[account] = 'instrument:upi_bank';
        instruments[account] = TxnInstrument.upiBank;
        destinationNotes[account] =
            'Detected a bank account from the statement source. You can change this if it was a card or another payment method.';
      } else if (matches.isEmpty &&
          RegExp(
            r'\b(?:hdfc|sbi|icici|axis|kotak|idfc|indusind|yes bank|union bank|canara|bob|bank of baroda|pnb|punjab national bank)\b',
          ).hasMatch(lower) &&
          suffixes.length == 1 &&
          !RegExp(r'\b(?:credit|debit|card)\b').hasMatch(lower)) {
        final last4 = suffixes.single;
        destinations[account] = 'instrument:upi_bank';
        instruments[account] = TxnInstrument.upiBank;
        destinationNotes[account] =
            'Recognized a bank account ending $last4 from the bank name and account number. Change it if this source is something else.';
      } else if (RegExp(r'\bcredit\b').hasMatch(lower) && matches.isEmpty) {
        destinations[account] = 'instrument:credit_card';
        instruments[account] = TxnInstrument.creditCard;
        destinationNotes[account] =
            'Detected a credit card, but no saved card matched its ending. It will stay unlinked.';
      } else if (RegExp(r'\bdebit\b').hasMatch(lower) && matches.isEmpty) {
        destinations[account] = 'instrument:debit_card';
        instruments[account] = TxnInstrument.debitCard;
        destinationNotes[account] =
            'Detected a debit card, but no saved card matched its ending. It will stay unlinked.';
      } else {
        destinations[account] = 'instrument:other';
        instruments[account] = TxnInstrument.other;
        destinationNotes[account] = matches.length > 1
            ? 'More than one card matches. Kept unlinked so you can choose safely.'
            : 'Could not identify this source confidently. It will be saved as an unlinked account; choose a type if you recognize it.';
      }
    }
  }

  bool eligible(int index) =>
      !savedDuplicates.containsKey(index) &&
      rows[index].reviewReasons.isEmpty &&
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

  void confirmSeparate(int index) {
    if (reviewLocked) {
      throw StateError('Finish or retry this import before editing rows.');
    }
    _confirmedSeparate.add(index);
    savedDuplicates.remove(index);
    if (eligible(index)) excluded.remove(index);
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
    entryKind: rows[index].isTransfer
        ? TxnEntryKind.transfer
        : rows[index].isInvestment
        ? TxnEntryKind.investment
        : rows[index].isCredit
        ? TxnEntryKind.income
        : TxnEntryKind.spend,
    instrument: instruments[accountFor(rows[index])],
    bankReference: rows[index].bankReference,
    categoryHint: rows[index].categoryHint,
    subcategoryHint: rows[index].subcategoryHint,
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
        'Select valid transactions and map every selected source account.',
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
          userCardId:
              destination.isEmpty || destination.startsWith('instrument:')
              ? null
              : destination,
          instrument: instruments[batch.account] ?? TxnInstrument.other,
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
    } catch (error) {
      // A received HTTP error means the server rejected the request and its
      // transaction was rolled back. If no earlier batch committed, let the
      // user correct the preview instead of leaving every edit control locked.
      // Keep the lock for transport failures/timeouts (the server may have
      // committed without the response reaching the device) and partial imports.
      if (_completed.isEmpty &&
          error is ApiException &&
          error.statusCode != null) {
        _submissionStarted = false;
      }
      rethrow;
    } finally {
      submitting = false;
    }
  }
}
