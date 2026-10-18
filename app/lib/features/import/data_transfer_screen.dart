import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/import_repository.dart';
import 'document_import_screen.dart';
import 'screenshot_spending_import_screen.dart';
import 'data_export_screen.dart';

/// The single entry point for moving data into and out of PandaPay.
///
/// Keeping import and export together matters on the Spending screen: the
/// top-right action is a data action, not an export-only action.
class DataTransferScreen extends ConsumerWidget {
  const DataTransferScreen({super.key});

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Data transfer',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              'Move your spending data',
              style: BambooFonts.heading(20, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Import a statement from another app or export a copy of your PandaPay data. Imports are analysed on this device and reviewed before anything is added.',
              style: BambooFonts.ui(13.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.xl),
            _TransferSection(
              icon: Icons.upload_file_outlined,
              title: 'Import data',
              subtitle:
                  'Import PDF, CSV, TSV, Excel (.xlsx), JSON, or transaction screenshots.',
              actions: [
                _TransferAction(
                  icon: Icons.table_view_outlined,
                  label: 'Import file',
                  onTap: () => _open(context, const DocumentImportScreen()),
                ),
                _TransferAction(
                  icon: Icons.image_search_outlined,
                  label: 'Screenshots',
                  onTap: () =>
                      _open(context, const SpendingScreenshotImportScreen()),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            _RecentImportsSection(
              imports: ref.watch(statementImportsProvider),
              onRetry: () => ref.invalidate(statementImportsProvider),
            ),
            const SizedBox(height: AppSpace.lg),
            _TransferSection(
              icon: Icons.download_outlined,
              title: 'Export data',
              subtitle:
                  'Create a portable copy of your transactions, cards, or both.',
              actions: [
                _TransferAction(
                  icon: Icons.insert_drive_file_outlined,
                  label: 'CSV or PDF',
                  onTap: () => _open(context, const DataExportScreen()),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xl),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: BambooInk.ink500,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'Your files stay on this device while they are being read. PandaPay only receives the rows you approve.',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentImportsSection extends StatefulWidget {
  final AsyncValue<List<StatementImport>> imports;
  final VoidCallback onRetry;

  const _RecentImportsSection({required this.imports, required this.onRetry});

  @override
  State<_RecentImportsSection> createState() => _RecentImportsSectionState();
}

class _RecentImportsSectionState extends State<_RecentImportsSection> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final sortedImports =
        (widget.imports.valueOrNull ?? const <StatementImport>[]).toList()
          ..sort((a, b) => b.importedAt.compareTo(a.importedAt));
    final visibleImports = _showAll
        ? sortedImports
        : sortedImports.take(3).toList();

    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.history_rounded,
                color: BambooInk.jade,
                size: 21,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  'Recent imports',
                  style: BambooFonts.heading(16, color: BambooInk.ink900),
                ),
              ),
              if (sortedImports.length > 3)
                TextButton(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  child: Text(_showAll ? 'Show less' : 'Show all'),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            'See when a statement was imported and how many rows were processed.',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          widget.imports.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpace.md),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, stackTrace) => _ImportHistoryMessage(
              icon: Icons.cloud_off_outlined,
              message: 'Import history could not be loaded.',
              action: TextButton.icon(
                onPressed: widget.onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ),
            data: (imports) {
              if (sortedImports.isEmpty) {
                return const _ImportHistoryMessage(
                  icon: Icons.inbox_outlined,
                  message:
                      'Completed statement imports will appear here. Your original files are not stored.',
                );
              }
              return Column(
                children: [
                  for (final batch in visibleImports)
                    _ImportHistoryRow(
                      batch: batch,
                      onTap: () => _showDetails(context, batch),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showDetails(BuildContext context, StatementImport batch) {
    final date = DateFormat(
      'd MMM yyyy, h:mm a',
    ).format(batch.importedAt.toLocal());
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          AppSpace.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Statement import',
              style: BambooFonts.heading(20, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.md),
            _ImportDetailLine(label: 'Imported', value: date),
            _ImportDetailLine(
              label: 'Statement period',
              value:
                  '${_shortDate(batch.statementFrom)} – ${_shortDate(batch.statementTo)}',
            ),
            _ImportDetailLine(
              label: 'Rows sent for import',
              value: '${batch.txnCount}',
            ),
            _ImportDetailLine(
              label: 'Rows reconciled',
              value: '${batch.reconciledCount}',
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'The original PDF, CSV, or screenshot stays on your device.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
        ),
      ),
    );
  }

  String _shortDate(DateTime value) => DateFormat('d MMM yyyy').format(value);
}

class _ImportHistoryRow extends StatelessWidget {
  final StatementImport batch;
  final VoidCallback onTap;

  const _ImportHistoryRow({required this.batch, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final importedAt = DateFormat('d MMM').format(batch.importedAt.toLocal());
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Row(
            children: [
              const Icon(
                Icons.description_outlined,
                color: BambooInk.ink500,
                size: 19,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Statement import',
                      style: BambooFonts.ui(
                        13,
                        weight: FontWeight.w700,
                        color: BambooInk.ink900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${DateFormat('d MMM').format(batch.statementFrom)} – '
                      '${DateFormat('d MMM yyyy').format(batch.statementTo)}'
                      ' · ${batch.txnCount} ${batch.txnCount == 1 ? 'row' : 'rows'}',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                importedAt,
                style: BambooFonts.ui(11.5, color: BambooInk.ink500),
              ),
              const SizedBox(width: AppSpace.xs),
              const Icon(
                Icons.chevron_right_rounded,
                color: BambooInk.ink500,
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportHistoryMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final Widget? action;

  const _ImportHistoryMessage({
    required this.icon,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: BambooInk.ink500),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(
            message,
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ),
        ?action,
      ],
    );
  }
}

class _ImportDetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _ImportDetailLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: BambooFonts.ui(13, color: BambooInk.ink500),
            ),
          ),
          Text(
            value,
            style: BambooFonts.ui(
              13,
              weight: FontWeight.w700,
              color: BambooInk.ink900,
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<_TransferAction> actions;

  const _TransferSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  color: BambooInk.slate,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: BambooInk.lime, size: 21),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: BambooFonts.heading(16, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: actions,
          ),
        ],
      ),
    );
  }
}

class _TransferAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TransferAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: BambooInk.ink900,
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.md,
        ),
      ),
    );
  }
}
