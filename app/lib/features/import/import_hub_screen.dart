import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/device_permissions.dart';
import '../../app/providers.dart';
import '../../data/import_repository.dart';
import '../sms_import/sms_backup_import_screen.dart';
import '../sms_import/ios_sms_import_screen.dart';
import 'auto_sms_sync_screen.dart';
import 'statement_pdf_import_screen.dart';
import 'screenshot_spending_import_screen.dart';
import 'pending_statement_imports_card.dart';

/// ui-spec.md F1 Import Hub — implementation-plan-group-e-f-g.md §3, "build
/// this LAST among the F screens, once F2/F3/F4/F7 exist enough to have a
/// real status to report." Built last in this pass, per that guidance.
///
/// The hub keeps the visible import choices focused while retaining the
/// existing import routes and showing completed-import history below them.
class ImportHubScreen extends ConsumerStatefulWidget {
  final bool embedded;

  const ImportHubScreen({super.key, this.embedded = false});

  @override
  ConsumerState<ImportHubScreen> createState() => _ImportHubScreenState();
}

class _ImportHubScreenState extends ConsumerState<ImportHubScreen>
    with WidgetsBindingObserver {
  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
  bool get _isIos => !kIsWeb && Platform.isIOS;
  bool _smsPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    if (!_isAndroid) {
      if (mounted) setState(() => _smsPermissionGranted = false);
      return;
    }
    try {
      final status = await readDevicePermissionStatus(Permission.sms);
      if (mounted) {
        setState(() => _smsPermissionGranted = status.isGranted);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _smsPermissionGranted = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final statementImports = ref.watch(statementImportsProvider);
    final smsBatches = ref.watch(smsImportBatchesProvider);
    // Fails open: an unreachable app-status endpoint must not withdraw a
    // working feature, only a deliberate flag flip should.
    final smsBackupEnabled = ref
        .watch(appStatusProvider)
        .maybeWhen(
          data: (s) => s?.smsBackupImportEnabled ?? true,
          orElse: () => true,
        );

    final body = AppBackground(
      child: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(
            'Bring your existing spending history into PandaPay, or keep it flowing automatically.',
            style: BambooFonts.ui(13.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.lg),
          _ChannelCard(
            icon: Icons.sms_outlined,
            title: 'Auto SMS detection',
            status: _smsPermissionGranted
                ? const _Status(
                    'Active · Reading bank alerts',
                    BambooInk.jade,
                  )
                : _Status(
                    _isAndroid
                        ? 'Not enabled · Tap to set up'
                        : _isIos ? 'Shortcuts · Live alerts and monthly history' : 'Available on Android',
                    BambooInk.ink500,
                  ),
            trailing: _smsPermissionGranted
                ? Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      color: BambooInk.jade,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  )
                : null,
            onTap: () async {
              if (_isIos) {
                await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const IosSmsImportScreen(),
                ));
                return;
              }
              if (!_isAndroid) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Automatic SMS detection is supported on Android devices.',
                    ),
                  ),
                );
                return;
              }
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AutoSmsSyncScreen(),
                ),
              );
              if (mounted) _checkPermission();
            },
          ),
          const SizedBox(height: AppSpace.md),
          _ChannelCard(
            icon: Icons.picture_as_pdf_outlined,
            title: 'Import spending file',
            status: const _Status(
              'PDF, CSV, TSV, Excel XLSX, or JSON',
              BambooInk.ink500,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const StatementPdfImportScreen(),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          _ChannelCard(
            icon: Icons.image_search_outlined,
            title: 'Import from screenshots',
            status: const _Status(
              'On-device OCR — transaction rows only',
              BambooInk.ink500,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SpendingScreenshotImportScreen(),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          if (smsBackupEnabled)
            _ChannelCard(
              icon: Icons.upload_file_outlined,
              title: 'Import SMS backup file',
              status: smsBatches.when(
                data: (batches) => batches.isEmpty
                    ? const _Status(
                        'One-off action — tap to import a backup export',
                        BambooInk.ink500,
                      )
                    : _Status(
                        'Imported ${batches.length} time${batches.length == 1 ? '' : 's'}',
                        BambooInk.jade,
                      ),
                loading: () => const _Status('Checking…', BambooInk.ink500),
                error: (_, _) => const _Status(
                  'One-off action — tap to import a backup export',
                  BambooInk.ink500,
                ),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SmsBackupImportScreen(),
                ),
              ),
            ),
          if (smsBackupEnabled) const SizedBox(height: AppSpace.md),
          const SizedBox(height: AppSpace.xxl),
          const PendingStatementImportsCard(),
          _ImportHistorySection(
            statementImports: statementImports,
            smsBatches: smsBatches,
            onRetry: () {
              ref.invalidate(statementImportsProvider);
              ref.invalidate(smsImportBatchesProvider);
            },
          ),
        ],
      ),
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Import & Sync',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: body,
    );
  }
}

class _ImportHistorySection extends StatelessWidget {
  final AsyncValue<List<StatementImport>> statementImports;
  final AsyncValue<List<SmsImportBatch>> smsBatches;
  final VoidCallback onRetry;

  const _ImportHistorySection({
    required this.statementImports,
    required this.smsBatches,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final entries = <_ImportHistoryEntry>[
      for (final batch in statementImports.valueOrNull ?? const [])
        _ImportHistoryEntry(
          title: 'Spending import',
          detail:
              '${batch.txnCount} ${batch.txnCount == 1 ? 'row' : 'rows'} processed',
          importedAt: batch.importedAt,
          icon: Icons.description_outlined,
        ),
      for (final batch in smsBatches.valueOrNull ?? const [])
        _ImportHistoryEntry(
          title: 'SMS backup import',
          detail:
              '${batch.parsedCount} ${batch.parsedCount == 1 ? 'message' : 'messages'} processed',
          importedAt: batch.importedAt,
          icon: Icons.sms_outlined,
        ),
    ]..sort((a, b) => b.importedAt.compareTo(a.importedAt));

    final isLoading =
        (statementImports.isLoading && statementImports.valueOrNull == null) ||
        (smsBatches.isLoading && smsBatches.valueOrNull == null);
    final hasError = statementImports.hasError || smsBatches.hasError;

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
              Text(
                'Import history',
                style: BambooFonts.heading(16, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            'Your latest completed imports, with the time they were added.',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          if (isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpace.md),
                child: CircularProgressIndicator(),
              ),
            )
          else if (entries.isEmpty && hasError)
            _ImportHistoryMessage(onRetry: onRetry)
          else if (entries.isEmpty)
            Text(
              'Completed imports will appear here.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            )
          else
            for (final entry in entries.take(5)) _ImportHistoryRow(entry: entry),
        ],
      ),
    );
  }
}

class _ImportHistoryEntry {
  final String title;
  final String detail;
  final DateTime importedAt;
  final IconData icon;

  const _ImportHistoryEntry({
    required this.title,
    required this.detail,
    required this.importedAt,
    required this.icon,
  });
}

class _ImportHistoryRow extends StatelessWidget {
  final _ImportHistoryEntry entry;

  const _ImportHistoryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final importedAt = DateFormat(
      'd MMM yyyy, h:mm a',
    ).format(entry.importedAt.toLocal());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(entry.icon, color: BambooInk.ink500, size: 19),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  style: BambooFonts.ui(
                    13,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.detail} · $importedAt',
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportHistoryMessage extends StatelessWidget {
  final VoidCallback onRetry;

  const _ImportHistoryMessage({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.cloud_off_outlined, size: 18, color: BambooInk.ink500),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(
            'Import history could not be loaded.',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}

class _Status {
  final String label;
  final Color color;
  const _Status(this.label, this.color);
}

class _ChannelCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final _Status status;
  final VoidCallback onTap;
  final Widget? trailing;

  const _ChannelCard({
    required this.icon,
    required this.title,
    required this.status,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: BambooInk.slate,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 20, color: BambooInk.lime),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    // Never colour-alone: status text always carries the
                    // word itself, colour is a reinforcement only.
                    Text(
                      status.label,
                      style: BambooFonts.ui(12.5, color: status.color),
                    ),
                  ],
                ),
              ),
              trailing ??
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: BambooInk.ink300,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
