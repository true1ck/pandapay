import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';

/// ui-spec.md F6 Data Export. "Your data is yours."
///
/// CSV/JSON exports come from the authenticated API. PDF is generated locally
/// from the CSV rows, keeping the server format-agnostic while still giving
/// the user a shareable document.
class DataExportScreen extends ConsumerStatefulWidget {
  const DataExportScreen({super.key});

  @override
  ConsumerState<DataExportScreen> createState() => _DataExportScreenState();
}

class _DataExportScreenState extends ConsumerState<DataExportScreen> {
  String _scope = 'all';
  String _format = 'json';
  bool _generating = false;
  String? _preview;
  List<int>? _exportBytes;
  String? _exportFilename;
  String? _exportMime;

  Future<void> _generate() async {
    final repo = ref.read(importRepositoryProvider);
    if (repo == null) return;
    setState(() {
      _generating = true;
      _preview = null;
      _exportBytes = null;
    });
    try {
      // The API's canonical interchange formats are JSON and CSV. PDF is a
      // presentation export built locally from the same CSV rows, so the
      // server never needs a PDF-specific table schema.
      final sourceFormat = _format == 'pdf' ? 'csv' : _format;
      final (body, _, _) = await repo.fetchExport(
        scope: _scope,
        format: sourceFormat,
      );
      final bytes = _format == 'pdf' ? _buildPdf(body) : utf8.encode(body);
      setState(() {
        _preview = _format == 'pdf' ? 'PDF export ready' : body;
        _exportBytes = bytes;
        _exportFilename = 'pandapay-export-$_scope.$_format';
        _exportMime = _format == 'pdf'
            ? 'application/pdf'
            : (_format == 'csv' ? 'text/csv' : 'application/json');
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _shareExport() async {
    final bytes = _exportBytes;
    final filename = _exportFilename;
    final mime = _exportMime;
    if (bytes == null || filename == null || mime == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mime)],
          text: 'My PandaPay data export',
        ),
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
    }
  }

  List<int> _buildPdf(String csv) {
    final document = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 8);
    var page = document.pages.add();
    final size = page.getClientSize();
    var y = 24.0;
    for (final rawLine in csv.split('\n')) {
      final line = rawLine.length > 150
          ? '${rawLine.substring(0, 147)}…'
          : rawLine;
      if (y > size.height - 24) {
        page = document.pages.add();
        y = 24;
      }
      page.graphics.drawString(
        line,
        font,
        bounds: Rect.fromLTWH(24, y, size.width - 48, 14),
      );
      y += 14;
    }
    final bytes = document.saveSync();
    document.dispose();
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(importRepositoryProvider);
    if (repo == null) {
      return Scaffold(
        backgroundColor: BambooInk.paper,
        appBar: AppBar(
          backgroundColor: BambooInk.paper,
          foregroundColor: BambooInk.ink900,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(
            'Export your data',
            style: BambooFonts.heading(17, color: BambooInk.ink900),
          ),
        ),
        body: const EmptyState(
          icon: Icons.download_outlined,
          title: 'Sign in to export your data',
        ),
      );
    }
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Export your data',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your data is yours.',
                style: BambooFonts.heading(17, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                'Export a copy of your transactions and/or cards. Nothing here is shared with anyone else.',
                style: BambooFonts.ui(13.5, color: BambooInk.ink500),
              ),
              const SizedBox(height: AppSpace.lg),
              Text(
                'Scope',
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
              const SizedBox(height: AppSpace.xs),
              Wrap(
                spacing: AppSpace.sm,
                children: [
                  for (final s in const ['transactions', 'cards', 'all'])
                    ChoiceChip(
                      label: Text(s),
                      labelStyle: BambooFonts.ui(
                        13,
                        weight: FontWeight.w600,
                        color: _scope == s
                            ? BambooInk.onSlate
                            : BambooInk.ink900,
                      ),
                      selected: _scope == s,
                      selectedColor: BambooInk.slate,
                      backgroundColor: BambooInk.paperMuted,
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      onSelected: (_) => setState(() => _scope = s),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.lg),
              Text(
                'Format',
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
              const SizedBox(height: AppSpace.xs),
              Wrap(
                spacing: AppSpace.sm,
                children: [
                  for (final f in const ['csv', 'pdf', 'json'])
                    ChoiceChip(
                      label: Text(f.toUpperCase()),
                      labelStyle: BambooFonts.ui(
                        13,
                        weight: FontWeight.w600,
                        color: _format == f
                            ? BambooInk.onSlate
                            : BambooInk.ink900,
                      ),
                      selected: _format == f,
                      selectedColor: BambooInk.slate,
                      backgroundColor: BambooInk.paperMuted,
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      onSelected: (_) => setState(() => _format = f),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.lg),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  textStyle: BambooFonts.ui(14.5, weight: FontWeight.w700),
                ),
                icon: const Icon(Icons.download_outlined),
                label: Text(_generating ? 'Generating…' : 'Generate export'),
                onPressed: _generating ? null : _generate,
              ),
              const SizedBox(height: AppSpace.lg),
              if (_preview != null) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _format == 'pdf'
                            ? 'PDF export ready'
                            : 'Export ready (${_preview!.length} chars)',
                        style: BambooFonts.heading(
                          14.5,
                          color: BambooInk.ink900,
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_format != 'pdf')
                          IconButton(
                            icon: const Icon(
                              Icons.copy_rounded,
                              color: BambooInk.ink900,
                            ),
                            tooltip: 'Copy to clipboard',
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: _preview!),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Copied — paste it wherever you want to save it',
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.ios_share_rounded,
                            color: BambooInk.ink900,
                          ),
                          tooltip: 'Share export file',
                          onPressed: _shareExport,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpace.md),
                    decoration: BoxDecoration(
                      color: BambooInk.paperMuted,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        _preview!,
                        style: BambooFonts.ui(
                          12.5,
                          color: BambooInk.ink900,
                        ).copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
