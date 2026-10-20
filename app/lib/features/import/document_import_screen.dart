import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../data/api_exception.dart';
import '../../data/import_models.dart';
import '../../data/pdf_statement_parser.dart'
    show PdfStatementReader, StatementParseException;
import '../../data/pdf_statement_ocr.dart';
import '../../data/transaction_import_pipeline.dart';
import 'import_mapping_dialog.dart';
import 'import_review_panel.dart';
import 'import_file_prompt.dart';

enum _Step { pick, password, parsing, review, error }

/// Every financial-document entry point lands in this same format-aware flow.
class DocumentImportScreen extends StatefulWidget {
  final bool pdfEntry;
  const DocumentImportScreen({super.key, this.pdfEntry = false});
  @override
  State<DocumentImportScreen> createState() => _DocumentImportScreenState();
}

class _DocumentImportScreenState extends State<DocumentImportScreen> {
  _Step _step = _Step.pick;
  ImportDocument? _document;
  TransactionImportSession? _session;
  Map<String, StatementTableOptions> _options = {};
  final _password = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'csv', 'tsv', 'txt', 'xlsx', 'json'],
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      if (picked.size > ImportDocument.maxFileBytes) {
        throw const StatementParseException(
          'This file exceeds 20 MB. Export a smaller date range.',
        );
      }
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final document = await compute(_openDocument, (bytes, picked.name));
      setState(() {
        _document = document;
        _session = null;
        _options = {};
        _password.clear();
        _error = null;
      });
      await _parse();
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (!mounted) return;
    setState(() {
      _step = _Step.error;
      _error = error is StatementParseException
          ? error.message
          : error is FormatException
          ? 'This file has invalid text or structure. Export it again as UTF-8 CSV or XLSX.'
          : userFacingErrorMessage(error);
    });
  }

  Future<void> _parse() async {
    final document = _document;
    if (document == null) return;
    setState(() => _step = _Step.parsing);
    try {
      if (document.kind == ImportDocumentKind.pdf && document.pdfText == null) {
        final password = _password.text.isEmpty ? null : _password.text;
        final pages = await compute(_readPdfPages, (document.bytes, password));
        document.pdfText = pages.join('\n');
        final scanned = [
          for (var i = 0; i < pages.length; i++)
            if (pages[i].replaceAll(RegExp(r'\s'), '').length < 32) i + 1,
        ];
        if (scanned.isNotEmpty) {
          final ocr = PdfStatementOcr();
          try {
            final text = await ocr.extractText(
              document.bytes,
              password: password,
              pageNumbers: scanned,
            );
            document.pdfText = '${document.pdfText}\n$text';
            document.extractionWarnings.add(
              'Scanned pages were read with OCR. Check digits, dates, and the source totals.',
            );
          } on StateError {
            rethrow;
          } catch (_) {
            document.extractionWarnings.add(
              'Some pages appear scanned and could not be read on this device. This preview may be incomplete. Export CSV/XLSX or use a device with OCR support.',
            );
          } finally {
            try {
              await ocr.dispose();
            } catch (_) {
              /* Keep the extraction error or warning. */
            }
          }
        }
        _password.clear();
      }
      final parsed = await compute(_parseDocument, (document, _options));
      if (!mounted) return;
      // A rejected-row preview is useful: it provides correction and mapping.
      setState(() {
        _session = TransactionImportSession(
          fileDigest: document.digest,
          importSource: document.importSource,
          statement: parsed,
        );
        _step = _Step.review;
      });
    } catch (error) {
      if (error is StatementParseException &&
          document.kind == ImportDocumentKind.pdf &&
          document.pdfText == null &&
          mounted) {
        setState(() {
          _step = _Step.password;
          _error = _password.text.isEmpty ? null : error.message;
        });
      } else {
        _fail(error);
      }
    }
  }

  Future<void> _configure() async {
    final document = _document!;
    final options = await showDialog<Map<String, StatementTableOptions>>(
      context: context,
      builder: (_) =>
          ImportMappingDialog(tables: document.tables, options: _options),
    );
    if (options == null || !mounted) return;
    _options = options;
    await _parse();
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final importTheme = baseTheme.copyWith(
      colorScheme: baseTheme.colorScheme.copyWith(
        primary: BambooInk.slate,
        onPrimary: BambooInk.lime,
        secondary: BambooInk.jade,
        onSecondary: Colors.white,
        surface: BambooInk.paper,
        onSurface: BambooInk.ink900,
        onSurfaceVariant: BambooInk.ink500,
        error: BambooInk.clayInk,
      ),
      scaffoldBackgroundColor: BambooInk.paper,
      appBarTheme: baseTheme.appBarTheme.copyWith(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: BambooFonts.heading(20, color: BambooInk.ink900),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: BambooInk.slate,
          foregroundColor: BambooInk.lime,
          disabledBackgroundColor: BambooInk.slate.withValues(alpha: .12),
          disabledForegroundColor: BambooInk.ink500,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: BambooFonts.ui(16, weight: FontWeight.w600),
        ),
      ),
      chipTheme: baseTheme.chipTheme.copyWith(
        backgroundColor: BambooInk.paperMuted,
        selectedColor: BambooInk.slate,
        labelStyle: BambooFonts.ui(14, color: BambooInk.ink700),
        secondaryLabelStyle: BambooFonts.ui(14, color: BambooInk.lime),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: BambooInk.paperMuted,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: BambooInk.jade, width: 1.5),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: BambooInk.jade,
        linearTrackColor: BambooInk.paperMuted,
      ),
    );
    return Theme(
      data: importTheme,
      child: Scaffold(
        backgroundColor: BambooInk.paper,
        appBar: AppBar(
          title: Text(
            widget.pdfEntry
                ? 'Import statement PDF'
                : 'Import spending history',
          ),
        ),
        body: AppBackground(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: switch (_step) {
              _Step.pick => ImportFilePrompt(
                icon: Icons.upload_file,
                title: 'Bring your spending history',
                message:
                    'Choose a PDF, CSV, TSV, Excel XLSX, or JSON export. Formats are detected on your device. You review and correct the data before importing.',
                action: FilledButton(
                  onPressed: _pick,
                  child: const Text('Choose file'),
                ),
              ),
              _Step.password => ListView(
                children: [
                  Text(_document!.name),
                  if (_error != null) Text(_error!),
                  const Text(
                    'If this PDF is protected, enter its password. Leave blank otherwise. Files and passwords stay on this device.',
                  ),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Statement password (optional)',
                    ),
                  ),
                  FilledButton(
                    onPressed: _parse,
                    child: const Text('Unlock & parse'),
                  ),
                ],
              ),
              _Step.parsing => const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    Text('Reading on-device…'),
                  ],
                ),
              ),
              _Step.review => Column(
                children: [
                  if (_session!.rows.isEmpty)
                    const Text(
                      'No spending rows were recognized automatically. Use Columns and formats, or correct the unrecognized rows below. Summary-only documents cannot recreate transaction history.',
                    ),
                  Expanded(
                    child: ImportReviewPanel(
                      key: ObjectKey(_session),
                      session: _session!,
                      configure: _configure,
                      doneTitle: widget.pdfEntry
                          ? 'Statement imported'
                          : 'Import complete',
                    ),
                  ),
                ],
              ),
              _Step.error => SingleChildScrollView(
                child: Column(
                  children: [
                    Text(_error ?? 'Could not read this file.'),
                    if (_document?.kind == ImportDocumentKind.pdf)
                      TextButton(
                        onPressed: () => setState(() => _step = _Step.password),
                        child: const Text('Try password again'),
                      ),
                    FilledButton(
                      onPressed: _pick,
                      child: const Text('Choose another file'),
                    ),
                  ],
                ),
              ),
            },
          ),
        ),
      ),
    );
  }
}

ImportDocument _openDocument((Uint8List, String) data) {
  final document = ImportDocument.open(data.$1, data.$2);
  if (document.kind != ImportDocumentKind.pdf) document.tables;
  return document;
}

ParsedStatement _parseDocument(
  (ImportDocument, Map<String, StatementTableOptions>) data,
) => data.$1.parse(
  options: data.$2['pdf'] ?? const StatementTableOptions(),
  tableOptions: data.$2,
);

List<String> _readPdfPages((Uint8List, String?) data) =>
    PdfStatementReader().extractPages(data.$1, password: data.$2);
