import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

enum _Step { pickFile, password, parsing, preview, done, error }

/// ui-spec.md F2 Statement PDF Import.
///
/// Scope decision, per this task's own instructions: real on-device
/// password-protected-PDF parsing is genuinely non-trivial (needs a PDF
/// library capable of decrypting + extracting a bank statement's
/// transaction table entirely client-side) and no such package is a
/// pubspec dependency today. Rather than add an unverifiable new native
/// plugin in an environment with no Flutter SDK to `pub get`/compile
/// against (this sandbox — see this chunk's PROGRESS.md entry), this
/// screen builds the REAL UI flow (file step → password prompt → parse
/// progress → preview → confirm → `statement_imports` row) wired to a
/// STUB parser that fabricates a small, clearly-fake preview instead of
/// reading a real file. What real PDF parsing would still need: a
/// password-capable PDF text/table extraction package (e.g. something in
/// the `syncfusion_flutter_pdf`/`pdfx` family — needs an explicit package
/// choice + security review before adding, per this task's own
/// instructions), issuer-specific column-layout parsing per bank (mirrors
/// `parser_patterns` server-side, but PDF layouts are far less uniform
/// than SMS/email text), and wiring the result into D5's duplicate-check
/// logic once that exists (C/D plan).
///
/// Security: the "password" typed below is used only to simulate the
/// parse step in-memory — it is never sent to the backend, never logged,
/// never included in any error report (matches F2's own security note).
class StatementPdfImportScreen extends ConsumerStatefulWidget {
  const StatementPdfImportScreen({super.key});

  @override
  ConsumerState<StatementPdfImportScreen> createState() => _StatementPdfImportScreenState();
}

class _StatementPdfImportScreenState extends ConsumerState<StatementPdfImportScreen> {
  _Step _step = _Step.pickFile;
  String? _fakeFileName;
  final _passwordController = TextEditingController();
  String? _errorMessage;
  String? _selectedCardId;

  // Stub-parsed preview data — never derived from a real file.
  final _detectedTxnCount = 12;
  final _detectedClosingBalance = Money.fromRupees(24310);

  @override
  void dispose() {
    // Never retain the typed password past this screen's lifetime.
    _passwordController.dispose();
    super.dispose();
  }

  void _pickFile() {
    // Stub: a real implementation would use a file-picker package here
    // (see this file's doc-comment for why none is wired up this pass).
    setState(() {
      _fakeFileName = 'statement.pdf';
      _step = _Step.password;
    });
  }

  Future<void> _submitPassword() async {
    setState(() => _step = _Step.parsing);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    // Stub parser: never actually inspects the "password" for correctness
    // (there's no real file). An empty password is treated as the one
    // deliberately-modeled failure case so the error state is reachable.
    if (_passwordController.text.trim().isEmpty) {
      setState(() {
        _step = _Step.error;
        _errorMessage = 'That password didn\'t work for this statement.';
      });
      return;
    }
    setState(() => _step = _Step.preview);
  }

  Future<void> _confirmImport() async {
    final repo = ref.read(importRepositoryProvider);
    if (repo == null || _selectedCardId == null) return;
    try {
      final now = DateTime.now();
      await repo.confirmStatementImport(
        userCardId: _selectedCardId!,
        statementFrom: DateTime(now.year, now.month - 1, 1),
        statementTo: DateTime(now.year, now.month, 0),
        closingBalance: _detectedClosingBalance,
        txnCount: _detectedTxnCount,
        reconciledCount: _detectedTxnCount, // stub: treats every detected line as reconciled
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
      appBar: AppBar(title: const Text('Import statement PDF')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: _buildStep(context),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    switch (_step) {
      case _Step.pickFile:
        return EmptyState(
          icon: Icons.picture_as_pdf_outlined,
          title: 'Select a statement PDF',
          message: 'Processed entirely on your device — the file and its password are never uploaded.',
          action: ElevatedButton(onPressed: _pickFile, child: const Text('Choose file')),
        );

      case _Step.password:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$_fakeFileName', style: textTheme.titleSmall),
            const SizedBox(height: AppSpace.sm),
            Text(
              'This PDF is password-protected. Enter the password (usually your PAN or DOB per your bank\'s '
              'convention) — it stays on this device and is never sent anywhere.',
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Statement password', border: OutlineInputBorder()),
            ),
            const SizedBox(height: AppSpace.lg),
            ElevatedButton(onPressed: _submitPassword, child: const Text('Unlock & parse')),
          ],
        );

      case _Step.parsing:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: AppSpace.lg),
              Text('Parsing on-device…'),
            ],
          ),
        );

      case _Step.preview:
        final userCards = ref.watch(userCardsProvider);
        return ListView(
          children: [
            Text('Detected transactions', style: textTheme.titleMedium),
            const SizedBox(height: AppSpace.sm),
            Row(children: [Text('$_detectedTxnCount transactions found · closing balance ', style: textTheme.bodyMedium), MoneyText(_detectedClosingBalance, confidence: Confidence.estimated)]),
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
              child: Text(
                'This preview is a stub — no real PDF was parsed (see this screen\'s doc-comment). A real build '
                'would list each detected transaction here for review before import.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.ink500),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            userCards.when(
              loading: () => const CircularProgressIndicator(),
              error: (err, _) => Text(userFacingErrorMessage(err)),
              data: (cards) => DropdownButtonFormField<String>(
                initialValue: _selectedCardId,
                decoration: const InputDecoration(labelText: 'Import against which card?', border: OutlineInputBorder()),
                items: [
                  for (final c in cards)
                    DropdownMenuItem(value: c.id, child: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName)),
                ],
                onChanged: (v) => setState(() => _selectedCardId = v),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            ElevatedButton(
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
          action: OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
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
