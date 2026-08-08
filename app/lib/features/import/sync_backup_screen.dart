import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/import_repository.dart';

/// ui-spec.md F5 Sync & Backup.
///
/// Scope decision (Task F-0 + the plan's own recommendation for F5,
/// implementation-plan-group-e-f-g.md §3): this app has NO client-side
/// sync engine at all today — every screen talks straight to REST routes,
/// no offline write queue, no `change_log` producer. Building a "last
/// sync / pending changes / manual sync" UI over that would mean either
/// fabricating a fake "0 pending changes" figure (explicitly forbidden by
/// the plan and by the Cross-Cutting "never a number the app can't
/// justify" rule) or blocking this whole screen on a genuinely separate,
/// larger "build the sync engine" effort. Scoped down to backup/restore
/// STATUS only, which `backup_runs`/`restore_drills` (ops-facing tables,
/// 0009_platform_ops.sql) can back honestly, plus the per-user
/// `sync_conflicts` log (real rows if any exist, from whatever
/// server-side conflict resolution has produced — never resolved from
/// this screen, only displayed, per spec's "never resolve silently
/// without a record").
class SyncBackupScreen extends ConsumerWidget {
  const SyncBackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(backupStatusProvider);
    final repo = ref.watch(importRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sync & backup')),
      body: status.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) =>
            ErrorState(message: userFacingErrorMessage(err), onRetry: () => ref.invalidate(backupStatusProvider)),
        data: (backupStatus) {
          if (backupStatus == null || repo == null) {
            return const EmptyState(icon: Icons.cloud_off_outlined, title: 'Sign in to see backup status');
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.md)),
                child: Text(
                  'Multi-device sync (pending-change count, live conflict resolution) isn\'t built yet — this app '
                  'talks directly to the server today, with no offline queue. This screen only shows real backup/'
                  'restore status and any conflicts already on record.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink500),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              _StatusCard(
                icon: Icons.backup_outlined,
                title: 'Last backup',
                value: backupStatus.latestBackupRanAt == null
                    ? 'No backup on record'
                    : '${_fmt(backupStatus.latestBackupRanAt!)} · ${backupStatus.latestBackupStatus ?? 'unknown'}',
              ),
              const SizedBox(height: AppSpace.md),
              _StatusCard(
                icon: Icons.restore_outlined,
                title: 'Last restore drill',
                value: backupStatus.latestRestoreDrillRanAt == null
                    ? 'No restore drill on record'
                    : '${_fmt(backupStatus.latestRestoreDrillRanAt!)} · ${backupStatus.latestRestoreDrillOk == true ? 'OK' : 'failed'}',
              ),
              const SizedBox(height: AppSpace.lg),
              ElevatedButton.icon(
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Back up now'),
                onPressed: () async {
                  try {
                    await repo.triggerBackupNow();
                    ref.invalidate(backupStatusProvider);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Backup requested (stub — see this screen\'s doc-comment)')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
                    }
                  }
                },
              ),
              const SizedBox(height: AppSpace.xxl),
              Text('Conflict log', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: AppSpace.sm),
              if (backupStatus.conflicts.isEmpty)
                Text('No conflicts on record.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.ink500))
              else
                for (final c in backupStatus.conflicts) _ConflictTile(conflict: c),
              const SizedBox(height: AppSpace.xxl),
              Text('Restore', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.error, side: const BorderSide(color: AppColors.errorBg, width: 1.5)),
                icon: const Icon(Icons.warning_amber_rounded),
                label: const Text('Restore from backup'),
                onPressed: () => _confirmRestore(context),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _confirmRestore(BuildContext context) async {
    // Destructive action — double-confirmed, no shortcut, per spec. No real
    // restore engine is wired up this pass (matches the rest of this
    // screen's scope-down); this only demonstrates the confirmation UX.
    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from backup?'),
        content: const Text('This will overwrite data on this device with the last backup. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Continue')),
        ],
      ),
    );
    if (firstConfirm != true || !context.mounted) return;
    final typed = TextEditingController();
    final secondConfirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Type RESTORE to confirm'),
        content: TextField(controller: typed, decoration: const InputDecoration(hintText: 'RESTORE')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(typed.text.trim() == 'RESTORE'),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (secondConfirm == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No restore engine is wired up this pass — nothing was changed.')),
      );
    }
  }
}

class _StatusCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  const _StatusCard({required this.icon, required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(AppRadius.md), border: Border.all(color: AppColors.ink100)),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.navy800),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.ink500)),
                Text(value, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConflictTile extends StatelessWidget {
  final SyncConflict conflict;
  const _ConflictTile({required this.conflict});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppRadius.md)),
        child: Text(
          '${conflict.entity}.${conflict.field} — resolved via ${conflict.strategy}'
          '${conflict.userAcknowledged ? '' : ' (not yet acknowledged)'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
