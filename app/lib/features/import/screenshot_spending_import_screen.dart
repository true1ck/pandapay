import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/import_repository.dart';
import '../../data/spending_screenshot_parser.dart';
import '../../data/spending_screenshot_ocr.dart';
import '../../main.dart' show MoneyText;

enum _ScreenshotStep { pick, parsing, preview, done, error }

/// Imports row-level transaction screenshots from another spending app.
/// OCR stays on-device; only the user-reviewed structured rows are sent.
class SpendingScreenshotImportScreen extends ConsumerStatefulWidget {
  const SpendingScreenshotImportScreen({super.key});

  @override
  ConsumerState<SpendingScreenshotImportScreen> createState() => _SpendingScreenshotImportScreenState();
}

class _SpendingScreenshotImportScreenState extends ConsumerState<SpendingScreenshotImportScreen> {
  final _picker = ImagePicker();
  _ScreenshotStep _step = _ScreenshotStep.pick;
  List<XFile> _images = const [];
  ParsedSpendingScreenshot? _parsed;
  String? _errorMessage;
  String? _selectedCardId;

  Future<void> _pickImages() async {
    final images = await _picker.pickMultiImage(imageQuality: 100);
    if (!mounted || images.isEmpty) return;
    setState(() {
      _images = images;
      _step = _ScreenshotStep.parsing;
      _errorMessage = null;
    });
    await _parseImages();
  }

  Future<void> _parseImages() async {
    final ocr = SpendingScreenshotOcr();
    try {
      final text = StringBuffer();
      for (final image in _images) {
        final recognized = await ocr.recognize(image.path);
        if (recognized.trim().isNotEmpty) text.writeln(recognized);
      }
      final parsed = parseSpendingScreenshotText(text.toString());
      if (!mounted) return;
      if (parsed.transactions.isEmpty) {
        setState(() {
          _step = _ScreenshotStep.error;
          _errorMessage = parsed.isSummaryOnly
              ? 'This screenshot contains totals and categories, not individual transaction rows. '
                  'Open the old app\'s Transactions tab and capture screenshots that show each date, merchant, and amount.'
              : 'Couldn\'t find transaction rows. Use clear screenshots showing the date, merchant, and amount for each spend.';
        });
        return;
      }
      setState(() {
        _parsed = parsed;
        _step = _ScreenshotStep.preview;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _step = _ScreenshotStep.error;
          _errorMessage = 'Couldn\'t read those screenshots. Try clearer images with visible dates and amounts.';
        });
      }
    } finally {
      await ocr.dispose();
    }
  }

  Future<void> _confirmImport() async {
    final repo = ref.read(importRepositoryProvider);
    final parsed = _parsed;
    if (repo == null || parsed == null || _selectedCardId == null) return;
    final spends = parsed.transactions.where((transaction) => !transaction.isCredit).toList();
    if (spends.isEmpty) {
      setState(() {
        _step = _ScreenshotStep.error;
        _errorMessage = 'These screenshots contain no debit transactions to import.';
      });
      return;
    }
    try {
      final dates = spends.map((transaction) => transaction.date).toList()..sort();
      final bytes = <int>[];
      for (final image in _images) {
        bytes.addAll(await image.readAsBytes());
      }
      await repo.confirmStatementImport(
        userCardId: _selectedCardId!,
        statementFrom: dates.first,
        statementTo: dates.last,
        txnCount: spends.length,
        reconciledCount: spends.length,
        issuerFormatId: 'screenshot',
        importSource: 'screenshot',
        importKey: sha256.convert(Uint8List.fromList(bytes)).toString(),
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
      if (mounted) setState(() => _step = _ScreenshotStep.done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _ScreenshotStep.error;
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
        title: Text('Import spending screenshots', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(child: Padding(padding: const EdgeInsets.all(AppSpace.lg), child: _body(context))),
    );
  }

  Widget _body(BuildContext context) {
    switch (_step) {
      case _ScreenshotStep.pick:
        return EmptyState(
          icon: Icons.image_search_outlined,
          title: 'Select transaction screenshots',
          message:
              'Choose one or more clear screenshots from your old app. OCR runs on this device; screenshots are never uploaded.',
          action: FilledButton(
            onPressed: _pickImages,
            style: FilledButton.styleFrom(backgroundColor: BambooInk.slate, foregroundColor: BambooInk.lime),
            child: const Text('Choose screenshots'),
          ),
        );
      case _ScreenshotStep.parsing:
        return const Center(child: CircularProgressIndicator());
      case _ScreenshotStep.error:
        return EmptyState(
          icon: Icons.error_outline,
          title: 'Couldn\'t import those screenshots',
          message: _errorMessage ?? 'Try again with clearer screenshots.',
          action: OutlinedButton(onPressed: () => setState(() => _step = _ScreenshotStep.pick), child: const Text('Try again')),
        );
      case _ScreenshotStep.done:
        return EmptyState(
          icon: Icons.check_circle_outline,
          title: 'Import complete',
          message: 'The detected spending was added. Existing matching transactions were not added again.',
          action: FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
        );
      case _ScreenshotStep.preview:
        final parsed = _parsed!;
        final userCards = ref.watch(userCardsProvider);
        return ListView(
          children: [
            Text('Review detected spending', style: BambooFonts.heading(16, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.sm),
            Text(
              '${parsed.transactions.length} row${parsed.transactions.length == 1 ? '' : 's'} found'
              '${parsed.totalSpendRupees == null ? '' : ' · summary total ₹${parsed.totalSpendRupees!.toStringAsFixed(2)}'}',
              style: BambooFonts.ui(13.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
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
                              style: BambooFonts.ui(12.5, color: BambooInk.ink900),
                            ),
                          ),
                          MoneyText(txn.amount, confidence: Confidence.estimated, style: BambooFonts.ui(12.5, color: BambooInk.ink900)),
                        ],
                      ),
                    ),
                  if (parsed.transactions.length > 30)
                    Text('+ ${parsed.transactions.length - 30} more', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            userCards.when(
              loading: () => const CircularProgressIndicator(),
              error: (error, _) => Text(userFacingErrorMessage(error), style: BambooFonts.ui(13.5, color: BambooInk.clay)),
              data: (cards) => DropdownButtonFormField<String>(
                initialValue: _selectedCardId,
                decoration: const InputDecoration(labelText: 'Import against which card?'),
                items: [
                  for (final card in cards)
                    DropdownMenuItem(
                      value: card.id,
                      child: Text(card.nickname?.isNotEmpty == true ? card.nickname! : card.cardName),
                    ),
                ],
                onChanged: (value) => setState(() => _selectedCardId = value),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              onPressed: _selectedCardId == null ? null : _confirmImport,
              style: FilledButton.styleFrom(backgroundColor: BambooInk.slate, foregroundColor: BambooInk.lime),
              child: const Text('Import detected spending'),
            ),
          ],
        );
    }
  }
}
