import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/env.dart';
import '../../app/providers.dart';
import '../sms_import/sms_backup_import_screen.dart';
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
    // Fails open: an unreachable app-status endpoint must not withdraw a
    // working feature, only a deliberate flag flip should.
    final smsBackupEnabled = ref
        .watch(appStatusProvider)
        .maybeWhen(data: (s) => s?.smsBackupImportEnabled ?? true, orElse: () => true);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Import & Sync', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              'Bring your existing spending history into PandaPay, or keep it flowing automatically.',
              style: BambooFonts.ui(13.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            // Task S-1b: the backup-file import needs NO SMS permission —
            // the user exports their own messages and picks the file — so
            // it ships in every flavor, including the one Play Console
            // releases come from. It used to be reachable only THROUGH the
            // live auto-read screen below, which meant the `!Env.isProd`
            // gate on that tile hid the compliant path along with the
            // non-compliant one. Two separate tiles, deliberately: merging
            // them is what caused the bug.
            //
            // `smsBackupImportEnabled` is the server-side kill switch
            // (migration 0036) — a bad import's blast radius is the user's
            // whole transaction history, and the input is a file format
            // this codebase doesn't control. Fails open when app-status is
            // unreachable, same as every other read of it.
            if (smsBackupEnabled) ...[
              _ChannelCard(
                icon: Icons.upload_file_outlined,
                title: 'Import SMS backup file',
                status: smsBatches.when(
                  data: (batches) => batches.isEmpty
                      ? const _Status('One-off action — tap to import a backup export', BambooInk.ink500)
                      : _Status(
                          'Imported ${batches.length} time${batches.length == 1 ? '' : 's'}',
                          BambooInk.jade,
                        ),
                  loading: () => const _Status('Checking…', BambooInk.ink500),
                  error: (_, _) => const _Status('One-off action — tap to import a backup export', BambooInk.ink500),
                ),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SmsBackupImportScreen())),
              ),
              const SizedBox(height: AppSpace.md),
            ],
            // The LIVE auto-read path is a different thing and stays gated:
            // the prod flavor has no READ_SMS/RECEIVE_SMS (see
            // app/android/app/src/prod/AndroidManifest.xml) — Google Play's
            // SMS/Call Log policy doesn't allow it for this optional
            // feature. Tapping through to a permission request that can
            // only fail is worse than not showing the tile.
            _ChannelCard(
              icon: Icons.sms_outlined,
              title: 'SMS auto-import (live)',
              status: smsBatches.when(
                data: (batches) => batches.isEmpty
                    ? const _Status('Not set up', BambooInk.ink500)
                    : _Status(
                        'Active — ${batches.length} import${batches.length == 1 ? '' : 's'}',
                        BambooInk.jade,
                      ),
                loading: () => const _Status('Checking…', BambooInk.ink500),
                error: (_, _) => const _Status('Error', BambooInk.clay),
              ),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SmsImportScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ChannelCard(
              icon: Icons.picture_as_pdf_outlined,
              title: 'Statement PDF import',
              status: const _Status('One-off action — tap to import a statement', BambooInk.ink500),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const StatementPdfImportScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ChannelCard(
              icon: Icons.email_outlined,
              title: 'Email forwarding',
              status: forwarding.when(
                data: (addr) {
                  if (addr == null) return const _Status('Not set up', BambooInk.ink500);
                  if (addr.emailCount > 0) {
                    return _Status('Connected — ${addr.emailCount} received', BambooInk.jade);
                  }
                  return const _Status('Waiting for first email…', BambooInk.amber);
                },
                loading: () => const _Status('Checking…', BambooInk.ink500),
                error: (_, _) => const _Status('Error', BambooInk.clay),
              ),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const EmailForwardingScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            // Task F-10: this tile used to read "IMAP connection
            // (fallback)" with a "Connected" status, which implied a
            // working sync. There is no poller behind it — it can test a
            // login and nothing else — and none is planned: Google has
            // ended basic-auth IMAP for Workspace and is deprecating app
            // passwords, so building one would mean building on a
            // foundation being removed. Email forwarding covers the same
            // need without holding anyone's credentials. Labelled for what
            // it actually does until it's removed outright.
            _ChannelCard(
              icon: Icons.alternate_email_rounded,
              title: 'IMAP connection (test only)',
              status: imap.when(
                data: (conn) {
                  if (conn == null) return const _Status('Not set up — use Email forwarding instead', BambooInk.ink500);
                  if (conn.verifiedAt != null) {
                    return const _Status('Login verified — does not sync mail', BambooInk.ink500);
                  }
                  return const _Status('Set up — not yet verified', BambooInk.amber);
                },
                loading: () => const _Status('Checking…', BambooInk.ink500),
                error: (_, _) => const _Status('Error', BambooInk.clay),
              ),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImapConnectionScreen())),
            ),
            const SizedBox(height: AppSpace.xxl),
            Text(
              'Data',
              style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            _ChannelCard(
              icon: Icons.cloud_sync_outlined,
              title: 'Sync & backup',
              status: const _Status('Backup status & conflict log', BambooInk.ink500),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncBackupScreen())),
            ),
            const SizedBox(height: AppSpace.md),
            _ChannelCard(
              icon: Icons.download_outlined,
              title: 'Export your data',
              status: const _Status('Your data is yours', BambooInk.ink500),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DataExportScreen())),
            ),
          ],
        ),
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
                decoration: const BoxDecoration(color: BambooInk.slate, shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: BambooInk.lime),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                    const SizedBox(height: 2),
                    // Never colour-alone: status text always carries the
                    // word itself, colour is a reinforcement only.
                    Text(status.label, style: BambooFonts.ui(12.5, color: status.color)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20, color: BambooInk.ink300),
            ],
          ),
        ),
      ),
    );
  }
}
