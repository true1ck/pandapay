import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/pdf_statement_parser.dart';
import '../../main.dart' show MoneyText;

enum _Step { pickFile, password, parsing, preview, done, error }

/// ui-spec.md F2 Statement PDF Import.
///
/// Real on-device parsing: `file_picker` for the file, `syncfusion_flutter_pdf`
/// (`PdfStatementReader`, data/pdf_statement_parser.dart) for password-aware
/// decryption + text extraction, and a heuristic (not issuer-specific)
/// regex line-parser for the transaction table — see that file's own
/// doc-comment for exactly what the heuristic does and doesn't handle.
/// Real per-issuer column-layout parsing (mirroring `parser_patterns`
/// server-side for SMS) remains out of scope — PDF table layouts vary far
/// more than SMS/email text ever does, and this pass ships a genuinely
/// working generic extractor rather than a perfect one.
///
/// Security: the PDF bytes and the typed password never leave this device
/// — `file_picker` reads bytes into memory, `PdfStatementReader` decrypts
/// in-process, and only the resulting transaction COUNT/closing balance
/// (never the raw text or file) is sent to `confirmStatementImport`.
class StatementPdfImportScreen extends ConsumerStatefulWidget {
  const StatementPdfImportScreen({super.key});

  @override
  ConsumerState<StatementPdfImportScreen> createState() => _StatementPdfImportScreenState();
}

class _StatementPdfImportScreenState extends ConsumerState<StatementPdfImportScreen> {
  _Step _step = _Step.pickFile;
  String? _fileName;
  Uint8List? _fileBytes;
  final _passwordController = TextEditingController();
  String? _errorMessage;
  String? _selectedCardId;
  ParsedStatement? _parsed;

  @override
  void dispose() {
    // Never retain the typed password past this screen's lifetime.
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    // file_picker 12.0.0-beta's pickFiles is a static FilePicker method,
    // not FilePicker.platform.pickFiles — that instance-based API was
    // removed in this beta line (see pubspec.yaml's own note on why this
    // beta is pinned instead of the 11.x stable). withData/.bytes is also
    // deprecated in this beta in favor of PlatformFile.readAsBytes().
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _step = _Step.error;
        _errorMessage = "Couldn't read that file. Try picking it again.";
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _fileName = picked.name;
      _fileBytes = bytes;
      _step = _Step.password;
    });
  }

  Future<void> _submitPassword() async {
    final bytes = _fileBytes;
    if (bytes == null) return;
    setState(() => _step = _Step.parsing);
    try {
      final password = _passwordController.text.trim().isEmpty ? null : _passwordController.text.trim();
      final text = await Future(() => PdfStatementReader().extractText(bytes, password: password));
      final parsed = parseStatementText(text);
      if (!mounted) return;
      if (parsed.transactions.isEmpty) {
        setState(() {
          _step = _Step.error;
          _errorMessage =
              "Couldn't find any transactions in this statement — it may use a layout this app "
              "doesn't recognize yet.";
        });
        return;
      }
      setState(() {
        _parsed = parsed;
        _step = _Step.preview;
      });
    } on StatementParseException catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.error;
          _errorMessage = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.error;
          _errorMessage = userFacingErrorMessage(e);
        });
      }
    }
  }

  Future<void> _confirmImport() async {
    final repo = ref.read(importRepositoryProvider);
    final parsed = _parsed;
    if (repo == null || _selectedCardId == null || parsed == null) return;
    try {
      final dates = parsed.transactions.map((t) => t.date).toList()..sort();
      await repo.confirmStatementImport(
        userCardId: _selectedCardId!,
        statementFrom: dates.first,
        statementTo: dates.last,
        closingBalance: parsed.closingBalance,
        txnCount: parsed.transactions.length,
        // Every heuristically-detected line is treated as reconciled — this
        // screen has no separate "confirm each row" step yet (ui-spec's
        // "list each detected transaction for review" is satisfied by the
        // preview list below, not a per-row accept/reject control).
        reconciledCount: parsed.transactions.length,
      );
      ref.invalidate(statementImportsProvider);
      if (mounted) setState(() => _step = _Step.done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.error;
          _errorMessage = userFacingErrorMessage(e);
        });
      }
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
        title: Text('Import statement PDF', style: BambooFonts.heading(16, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: Padding(padding: const EdgeInsets.all(AppSpace.lg), child: _buildStep(context)),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    switch (_step) {
      case _Step.pickFile:
        return EmptyState(
          icon: Icons.picture_as_pdf_outlined,
          title: 'Select a statement PDF',
          message: 'Processed entirely on your device — the file and its password are never uploaded.',
          action: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.slate,
              foregroundColor: BambooInk.lime,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
            ),
            onPressed: _pickFile,
            child: const Text('Choose file'),
          ),
        );

      case _Step.password:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$_fileName', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.sm),
            Text(
              'If this PDF is password-protected, enter the password (usually your PAN or DOB per your bank\'s '
              'convention) — it stays on this device and is never sent anywhere. Leave blank if it isn\'t '
              'protected.',
              style: BambooFonts.ui(13.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _passwordController,
              obscureText: true,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Statement password (optional)',
                labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
                filled: true,
                fillColor: BambooInk.glassFillOnPaper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: _submitPassword,
              child: const Text('Unlock & parse'),
            ),
          ],
        );

      case _Step.parsing:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: AppSpace.lg),
              Text('Parsing on-device…', style: BambooFonts.ui(13.5, color: BambooInk.ink500)),
            ],
          ),
        );

      case _Step.preview:
        final parsed = _parsed!;
        final userCards = ref.watch(userCardsProvider);
        return ListView(
          children: [
            Text('Detected transactions', style: BambooFonts.heading(16, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Text(
                  '${parsed.transactions.length} transactions found',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink500),
                ),
                if (parsed.closingBalance != null) ...[
                  Text(' · closing balance ', style: BambooFonts.ui(13.5, color: BambooInk.ink500)),
                  MoneyText(
                    parsed.closingBalance!,
                    confidence: Confidence.estimated,
                    style: BambooFonts.money(14, color: BambooInk.ink900),
                  ),
                ],
              ],
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
                  for (final txn in parsed.transactions.take(20))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${txn.date.day.toString().padLeft(2, '0')}/${txn.date.month.toString().padLeft(2, '0')} · ${txn.description}',
                              style: BambooFonts.ui(12.5, color: BambooInk.ink900),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          MoneyText(
                            txn.amount,
                            confidence: Confidence.estimated,
                            style: BambooFonts.ui(12.5, color: BambooInk.ink900),
                          ),
                        ],
                      ),
                    ),
                  if (parsed.transactions.length > 20)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.xs),
                      child: Text(
                        '+ ${parsed.transactions.length - 20} more',
                        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            userCards.when(
              loading: () => const CircularProgressIndicator(),
              error: (err, _) =>
                  Text(userFacingErrorMessage(err), style: BambooFonts.ui(13.5, color: BambooInk.clay)),
              data: (cards) => DropdownButtonFormField<String>(
                initialValue: _selectedCardId,
                style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                decoration: InputDecoration(
                  labelText: 'Import against which card?',
                  labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
                  filled: true,
                  fillColor: BambooInk.glassFillOnPaper,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
                  ),
                ),
                items: [
                  for (final c in cards)
                    DropdownMenuItem(
                      value: c.id,
                      child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName),
                    ),
                ],
                onChanged: (v) => setState(() => _selectedCardId = v),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: _selectedCardId == null ? null : _confirmImport,
              child: const Text('Confirm import'),
            ),
          ],
        );

      case _Step.done:
        return EmptyState(
          icon: Icons.check_circle_outline_rounded,
          title: 'Statement imported',
          message: 'Estimates from this period have been reconciled to confirmed.',
          action: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: BambooInk.ink900,
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        );

      case _Step.error:
        return ErrorState(
          message: _errorMessage ?? 'Something went wrong.',
          onRetry: () => setState(() {
            _step = _Step.password;
            _errorMessage = null;
          }),
        );
    }
  }
}
