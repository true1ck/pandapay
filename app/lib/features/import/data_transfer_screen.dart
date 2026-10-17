import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import 'csv_statement_import_screen.dart';
import 'data_export_screen.dart';
import 'statement_pdf_import_screen.dart';

/// The single entry point for moving data into and out of PandaPay.
///
/// Keeping import and export together matters on the Spending screen: the
/// top-right action is a data action, not an export-only action.
class DataTransferScreen extends StatelessWidget {
  const DataTransferScreen({super.key});

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
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
                  'Bring in transactions from almost any CSV layout or bank statement PDF.',
              actions: [
                _TransferAction(
                  icon: Icons.table_view_outlined,
                  label: 'CSV file',
                  onTap: () => _open(context, const CsvStatementImportScreen()),
                ),
                _TransferAction(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'PDF statement',
                  onTap: () => _open(context, const StatementPdfImportScreen()),
                ),
              ],
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
