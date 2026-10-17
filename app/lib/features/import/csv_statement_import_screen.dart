import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/csv_statement_parser.dart';
import '../../data/import_repository.dart';
import '../../data/pdf_statement_parser.dart';
import '../../main.dart' show MoneyText;

enum _CsvStep { pick, parsing, preview, done, error }

/// Imports CSV exports from banks, wallets, card apps, and spreadsheets.
/// Column names and order are inferred; only rows with a credible date,
/// amount, and description reach the review screen.
class CsvStatementImportScreen extends ConsumerStatefulWidget {
  const CsvStatementImportScreen({super.key});

  @override
  ConsumerState<CsvStatementImportScreen> createState() =>
      _CsvStatementImportScreenState();
}

class _CsvStatementImportScreenState
    extends ConsumerState<CsvStatementImportScreen> {
  _CsvStep _step = _CsvStep.pick;
  String? _fileName;
  Uint8List? _fileBytes;
  ParsedStatement? _parsed;
  String? _errorMessage;
  String? _selectedCardId;

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    try {
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _fileName = picked.name;
        _fileBytes = bytes;
        _step = _CsvStep.parsing;
        _errorMessage = null;
      });
      await _parse(bytes);
    } catch (_) {
      if (mounted)
        setState(() {
          _step = _CsvStep.error;
          _errorMessage =
              "Couldn't read that CSV. Try exporting it again as UTF-8.";
        });
    }
  }

  Future<void> _parse(Uint8List bytes) async {
    try {
      final parsed = await Future(
        () =>
            parseFlexibleCsvStatement(utf8.decode(bytes, allowMalformed: true)),
      );
      if (!mounted) return;
      if (parsed.transactions.isEmpty) {
        setState(() {
          _step = _CsvStep.error;
          _errorMessage =
              'Couldn\'t find rows containing a date, amount, and description in this file.';
        });
        return;
      }
      setState(() {
        _parsed = parsed;
        _step = _CsvStep.preview;
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _step = _CsvStep.error;
          _errorMessage =
              "Couldn't understand that CSV. Check that it contains transaction rows.";
        });
    }
  }

  Future<void> _confirmImport() async {
    final repo = ref.read(importRepositoryProvider);
    final parsed = _parsed;
    final bytes = _fileBytes;
    if (repo == null ||
        parsed == null ||
        bytes == null ||
        _selectedCardId == null)
      return;
    final spends = parsed.transactions
        .where((transaction) => !transaction.isCredit)
        .toList();
    if (spends.isEmpty) {
      setState(() {
        _step = _CsvStep.error;
        _errorMessage = 'This file contains no debit transactions to import.';
      });
      return;
    }
    try {
      final dates = spends.map((transaction) => transaction.date).toList()
        ..sort();
      await repo.confirmStatementImport(
        userCardId: _selectedCardId!,
        statementFrom: dates.first,
        statementTo: dates.last,
        txnCount: spends.length,
        reconciledCount: spends.length,
        issuerFormatId: 'csv-generic',
        importSource: 'csv',
        importKey: sha256.convert(bytes).toString(),
        transactions: [
          for (final transaction in spends)
            StatementTransactionInput(
              occurredAt: transaction.date,
              amount: transaction.amount,
              merchantName: transaction.description,
            ),
        ],
      );
      ref.invalidate(statementImportsProvider);
      ref.invalidate(transactionsProvider);
      ref.invalidate(utilizationTransactionsProvider);
      ref.invalidate(homeSummaryProvider);
      if (mounted) setState(() => _step = _CsvStep.done);
    } catch (e) {
      if (mounted)
        setState(() {
          _step = _CsvStep.error;
          _errorMessage = userFacingErrorMessage(e);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Import CSV data',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _body(),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_step) {
      case _CsvStep.pick:
        return EmptyState(
          icon: Icons.table_view_outlined,
          title: 'Select a CSV export',
          message:
              'PandaPay finds transaction columns automatically. The file stays on this device until you confirm the import.',
          action: FilledButton(
            onPressed: _pickFile,
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
            ),
            child: const Text('Choose CSV file'),
          ),
        );
      case _CsvStep.parsing:
        return const Center(child: CircularProgressIndicator());
      case _CsvStep.error:
        return EmptyState(
          icon: Icons.error_outline,
          title: 'Couldn\'t import this CSV',
          message: _errorMessage ?? 'Try another export file.',
          action: OutlinedButton(
            onPressed: () => setState(() => _step = _CsvStep.pick),
            child: const Text('Try again'),
          ),
        );
      case _CsvStep.done:
        return EmptyState(
          icon: Icons.check_circle_outline_rounded,
          title: 'CSV imported',
          message:
              'The detected spending was added. Existing matching transactions were not added again.',
          action: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        );
      case _CsvStep.preview:
        final parsed = _parsed!;
        final cards = ref.watch(userCardsProvider);
        return ListView(
          children: [
            Text(
              _fileName ?? 'Review detected transactions',
              style: BambooFonts.heading(16, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              '${parsed.transactions.length} rows found · review before importing',
              style: BambooFonts.ui(13.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final txn in parsed.transactions.take(30))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${txn.date.day.toString().padLeft(2, '0')}/${txn.date.month.toString().padLeft(2, '0')} · ${txn.description}',
                              overflow: TextOverflow.ellipsis,
                              style: BambooFonts.ui(
                                12.5,
                                color: BambooInk.ink900,
                              ),
                            ),
                          ),
                          MoneyText(
                            txn.amount,
                            confidence: Confidence.estimated,
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (parsed.transactions.length > 30)
                    Text(
                      '+ ${parsed.transactions.length - 30} more',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            cards.when(
              loading: () => const CircularProgressIndicator(),
              error: (error, _) => Text(
                userFacingErrorMessage(error),
                style: BambooFonts.ui(13.5, color: BambooInk.clay),
              ),
              data: (items) => DropdownButtonFormField<String>(
                initialValue: _selectedCardId,
                decoration: const InputDecoration(
                  labelText: 'Import against which card?',
                ),
                items: [
                  for (final card in items)
                    DropdownMenuItem(
                      value: card.id,
                      child: Text(
                        card.nickname?.isNotEmpty == true
                            ? card.nickname!
                            : card.cardName,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _selectedCardId = value),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              onPressed: _selectedCardId == null ? null : _confirmImport,
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
              ),
              child: const Text('Import detected spending'),
            ),
          ],
        );
    }
  }
}
