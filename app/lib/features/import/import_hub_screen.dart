import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../sms_import/sms_import_screen.dart';
import 'data_export_screen.dart';
import 'email_forwarding_screen.dart';
import 'imap_connection_screen.dart';
import 'statement_pdf_import_screen.dart';
import 'sync_backup_screen.dart';

/// ui-spec.md F1 Import Hub — implementation-plan-group-e-f-g.md §3, "build
/// this LAST among the F screens, once F2/F3/F4/F7 exist enough to have a
/// real status to report." Built last in this pass, per that guidance.
///
/// Offline behaviour: every status card below needs a network round-trip
/// to say anything real (forwarding-address issuance, IMAP config) — this
/// screen requires connectivity and shows ErrorState rather than hanging
/// silently, matching the Cross-Cutting Requirements' offline-first
/// discipline for screens that legitimately can't work offline.
class ImportHubScreen extends ConsumerWidget {
  const ImportHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forwarding = ref.watch(forwardingAddressProvider);
    final imap = ref.watch(imapConnectionProvider);
    final smsBatches = ref.watch(smsImportBatchesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Import & Sync')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(
            'Bring your existing spending history into PandaPay, or keep it flowing automatically.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.ink500),
          ),
          const SizedBox(height: AppSpace.lg),
          _ChannelCard(
            icon: Icons.sms_outlined,
            title: 'SMS import',
            status: smsBatches.when(
              data: (batches) => batches.isEmpty
                  ? const _Status('Not set up', AppColors.ink500)
                  : _Status('Active — ${batches.length} import${batches.length == 1 ? '' : 's'}', AppColors.success),
              loading: () => const _Status('Checking…', AppColors.ink500),
              error: (_, __) => const _Status('Error', AppColors.error),
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SmsImportScreen())),
          ),
          const SizedBox(height: AppSpace.md),
          _ChannelCard(
            icon: Icons.picture_as_pdf_outlined,
            title: 'Statement PDF import',
            status: const _Status('One-off action — tap to import a statement', AppColors.ink500),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StatementPdfImportScreen())),
          ),
          const SizedBox(height: AppSpace.md),
          _ChannelCard(
            icon: Icons.email_outlined,
            title: 'Email forwarding',
            status: forwarding.when(
              data: (addr) {
                if (addr == null) return const _Status('Not set up', AppColors.ink500);
                if (addr.emailCount > 0) return _Status('Connected — ${addr.emailCount} received', AppColors.success);
                return const _Status('Waiting for first email…', AppColors.warning);
              },
              loading: () => const _Status('Checking…', AppColors.ink500),
              error: (_, __) => const _Status('Error', AppColors.error),
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EmailForwardingScreen())),
          ),
          const SizedBox(height: AppSpace.md),
          _ChannelCard(
            icon: Icons.alternate_email_rounded,
            title: 'IMAP connection (fallback)',
            status: imap.when(
              data: (conn) {
                if (conn == null) return const _Status('Not set up', AppColors.ink500);
                if (conn.verifiedAt != null) return const _Status('Connected', AppColors.success);
                return const _Status('Set up — not yet verified', AppColors.warning);
              },
              loading: () => const _Status('Checking…', AppColors.ink500),
              error: (_, __) => const _Status('Error', AppColors.error),
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImapConnectionScreen())),
          ),
          const SizedBox(height: AppSpace.xxl),
          Text('Data', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: AppSpace.sm),
          _ChannelCard(
            icon: Icons.cloud_sync_outlined,
            title: 'Sync & backup',
            status: const _Status('Backup status & conflict log', AppColors.ink500),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncBackupScreen())),
          ),
          const SizedBox(height: AppSpace.md),
          _ChannelCard(
            icon: Icons.download_outlined,
            title: 'Export your data',
            status: const _Status('Your data is yours', AppColors.ink500),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DataExportScreen())),
          ),
        ],
      ),
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

  const _ChannelCard({required this.icon, required this.title, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppRadius.md), border: Border.all(color: AppColors.ink100)),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(color: AppColors.surfaceMuted, shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: AppColors.navy800),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.titleSmall),
                    const SizedBox(height: 2),
                    // Never colour-alone: status text always carries the
                    // word itself, colour is a reinforcement only.
                    Text(status.label, style: textTheme.bodySmall?.copyWith(color: status.color)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.ink300),
            ],
          ),
        ),
      ),
    );
  }
}
