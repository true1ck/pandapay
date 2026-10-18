import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../app/design/widgets.dart';
import '../../data/import_models.dart';
import '../../data/pdf_statement_parser.dart' show StatementParseException;
import '../../data/spending_screenshot_parser.dart';
import '../../data/spending_screenshot_ocr.dart';
import '../../data/transaction_import_pipeline.dart';
import 'import_review_panel.dart';
import 'import_file_prompt.dart';

class SpendingScreenshotImportScreen extends StatefulWidget {
  const SpendingScreenshotImportScreen({super.key});
  @override
  State<SpendingScreenshotImportScreen> createState() =>
      _SpendingScreenshotImportScreenState();
}

class _SpendingScreenshotImportScreenState
    extends State<SpendingScreenshotImportScreen> {
  TransactionImportSession? _session;
  bool _reading = false;
  String? _error;
  Future<void> _pick() async {
    List<XFile> images;
    try {
      images = await ImagePicker().pickMultiImage(imageQuality: 100);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not open the photo library. Check photo access and try again.',
        );
      }
      return;
    }
    if (!mounted || images.isEmpty) return;
    setState(() {
      _reading = true;
      _error = null;
    });
    final ocr = SpendingScreenshotOcr();
    try {
      if (images.length > 50) {
        throw const StatementParseException(
          'Choose up to 50 screenshots at a time.',
        );
      }
      final sources = <String, XFile>{};
      for (final image in images) {
        if (await image.length() > ImportDocument.maxFileBytes) {
          throw const StatementParseException(
            'A screenshot exceeds 20 MB. Choose a smaller image.',
          );
        }
        sources[sha256.convert(await image.readAsBytes()).toString()] = image;
      }
      final rows = <ParsedStatementLine>[];
      final rejected = <ImportRejectedRow>[];
      final hashes = sources.keys.toList()..sort();
      for (final hash in hashes) {
        final text = await ocr.recognize(sources[hash]!.path);
        final result = parseSpendingScreenshotText(text);
        for (var i = 0; i < result.transactions.length; i++) {
          final row = result.transactions[i];
          rows.add(
            ParsedStatementLine(
              date: row.date,
              description: row.description,
              amount: row.amount,
              isCredit: row.isCredit,
              isTransfer: row.isTransfer,
              sourceAccount: row.sourceAccount,
              sourceRowId: 'image:$hash:${row.sourceRowId ?? i}',
              reviewReasons: row.reviewReasons,
            ),
          );
        }
        if (result.transactions.isEmpty) {
          rejected.add(
            ImportRejectedRow(
              'image:$hash:unrecognized',
              [text],
              result.isSummaryOnly
                  ? 'This image has summaries rather than transaction rows. Choose screenshots with dates, merchants and amounts.'
                  : 'OCR did not recognize a complete transaction. Correct the row or choose a clearer screenshot.',
            ),
          );
        }
      }
      if (!mounted) return;
      setState(
        () => _session = TransactionImportSession(
          fileDigest: sha256.convert(utf8.encode(hashes.join(':'))).toString(),
          importSource: 'screenshot',
          statement: ParsedStatement(
            transactions: rows,
            rejectedRows: rejected,
            warnings: const [
              'OCR can misread digits and dates. Check the original screenshots before confirming.',
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StatementParseException
              ? error.message
              : 'Could not read these screenshots. Try clear images with dates, merchants and amounts.',
        );
      }
    } finally {
      try {
        await ocr.dispose();
      } catch (_) {
        /* Do not hide the extraction error. */
      }
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Import spending screenshots')),
    body: AppBackground(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: _reading
            ? const Center(child: CircularProgressIndicator())
            : _session != null
            ? ImportReviewPanel(key: ObjectKey(_session), session: _session!)
            : ImportFilePrompt(
                icon: Icons.image_search,
                title: 'Select transaction screenshots',
                message:
                    _error ??
                    'Choose clear screenshots from your old app. OCR stays on this device; you review the same transaction model used for files.',
                action: FilledButton(
                  onPressed: _pick,
                  child: const Text('Choose screenshots'),
                ),
              ),
      ),
    ),
  );
}
