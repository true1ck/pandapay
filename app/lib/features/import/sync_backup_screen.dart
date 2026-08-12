import 'dart:convert';

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
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Sync & backup', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: status.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(backupStatusProvider),
          ),
          data: (backupStatus) {
            if (backupStatus == null || repo == null) {
              return const EmptyState(icon: Icons.cloud_off_outlined, title: 'Sign in to see backup status');
            }
            return ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(
                    color: BambooInk.paperMuted,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Text(
                    // Corrected: this said "with no offline queue", which
                    // stopped being true when the B6 outbox landed. There IS
                    // a queue — it is shown below — what does not exist is a
                    // multi-device sync engine with live conflict resolution.
                    // Those are different claims and the screen was making
                    // the wrong one.
                    'Multi-device sync (live conflict resolution across devices) isn\'t built yet. Anything you '
                    'save while offline is queued on this phone and sent when you reconnect — that queue is '
                    'shown below. This screen also shows real backup/restore status and any conflicts on record.',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                // Plan Phase 1.5. `pendingOutboxCountProvider` has existed
                // since the B6 outbox landed and nothing ever displayed it,
                // so a quick-add saved offline was invisible until it either
                // synced or didn't. Worth saying plainly, because a queued
                // entry is the one piece of a user's data that genuinely does
                // NOT survive losing this device — it has never reached the
                // server, so no amount of signing in elsewhere recovers it.
                const _PendingOutboxCard(),
                const SizedBox(height: AppSpace.md),
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
                // The "Back up now" button was removed rather than disabled.
                //
                // It called POST /backup-runs, which inserted a row claiming
                // success while performing no backup, and then told the user
                // "Backup requested and logged." In a personal-finance app
                // that is the worst possible affordance: it manufactures
                // confidence in a safety net that did not exist.
                //
                // Backups are real now, but they run on a schedule as ops
                // infrastructure (db/scripts/backup.sh, verified by
                // restore_drill.sh) — not something a phone can or should
                // trigger. The status rows above already show when one last
                // actually succeeded, which is the information the user
                // wanted from the button in the first place.
                Text(
                  'Backups run automatically. The times above come from real backup and '
                  'restore-test runs, not from this screen.',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.5),
                ),
                const SizedBox(height: AppSpace.xxl),
                Text(
                  'Conflict log',
                  style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
                ),
                const SizedBox(height: AppSpace.sm),
                if (backupStatus.conflicts.isEmpty)
                  Text('No conflicts on record.', style: BambooFonts.ui(13.5, color: BambooInk.ink500))
                else
                  for (final c in backupStatus.conflicts) _ConflictTile(conflict: c),
                const SizedBox(height: AppSpace.xxl),
                Text(
                  'Restore',
                  style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
                ),
                const SizedBox(height: AppSpace.sm),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BambooInk.clay,
                    side: const BorderSide(color: BambooInk.warningBorder, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.warning_amber_rounded),
                  label: const Text('Restore from backup'),
                  onPressed: () => _confirmRestore(context),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _confirmRestore(BuildContext context) async {
    // Destructive action — double-confirmed, no shortcut, per spec. No real
    // restore engine is wired up this pass (matches the rest of this
    // screen's scope-down); this only demonstrates the confirmation UX.
    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from backup?'),
        content: const Text(
          'This will overwrite data on this device with the last backup. This cannot be undone.',
        ),
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
        content: TextField(
          controller: typed,
          decoration: const InputDecoration(hintText: 'RESTORE'),
        ),
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
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: BambooInk.ink900),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                Text(value, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Plan Phase 4 — F5's conflict log, rendered as something a person can read.
///
/// This previously showed `transactions.merchant_name — resolved via
/// last_write_wins`: table name, column name, and an internal strategy
/// identifier. That is a debug line, not a disclosure. `sync_conflicts` goes
/// to the trouble of storing the LOSING value precisely so the user can be
/// told what was discarded, and the tile is the only place that promise gets
/// kept.
class _ConflictTile extends ConsumerWidget {
  final SyncConflict conflict;
  const _ConflictTile({required this.conflict});

  /// Column name -> what the user calls it. An unmapped field falls back to
  /// the raw name rather than being hidden: showing `autopay_mode` is ugly,
  /// showing nothing about a change to the user's data is worse.
  static const _fieldLabels = <String, String>{
    'note': 'note',
    'merchant_name': 'merchant',
    'category_id': 'category',
    'amount_inr': 'amount',
    'occurred_at': 'date',
    'nickname': 'card nickname',
    'credit_limit_inr': 'credit limit',
    'statement_day': 'statement day',
    'due_day': 'due date',
    'autopay_mode': 'autopay setting',
    'is_default': 'default card',
    'reason_note': 'override note',
  };

  static String _display(Object? value) {
    if (value == null) return 'empty';
    final s = value is String ? value : jsonEncode(value);
    final unquoted = s.startsWith('"') && s.endsWith('"') ? s.substring(1, s.length - 1) : s;
    return unquoted.isEmpty ? 'empty' : unquoted;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = _fieldLabels[conflict.field] ?? conflict.field;
    final discarded = conflict.discardedValue;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.warningBg,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Two devices changed the $label',
              style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.ink900),
            ),
            const SizedBox(height: 4),
            Text(
              discarded == null
                  ? 'Kept "${_display(conflict.chosenValue)}".'
                  : 'Kept "${_display(conflict.chosenValue)}" and discarded '
                        '"${_display(discarded)}" — the most recent edit won.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.45),
            ),
            if (!conflict.userAcknowledged)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () async {
                    final api = ref.read(syncApiProvider);
                    if (api == null) return;
                    try {
                      await api.acknowledgeConflict(conflict.id);
                      ref.invalidate(backupStatusProvider);
                    } catch (_) {
                      // Acknowledging is a courtesy, not a transaction. If it
                      // fails the row simply stays in the list.
                    }
                  },
                  child: const Text('Got it'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Plan Phase 1.5 — the offline write queue, made visible.
class _PendingOutboxCard extends ConsumerWidget {
  const _PendingOutboxCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Two separate queues, deliberately summed for display. The B6 outbox
    // holds quick-adds that were never created server-side at all; the Phase 4
    // sync queue holds edits to rows that already exist. The distinction
    // matters to the code and not at all to the user, who just wants to know
    // whether anything is still stuck on this phone.
    final outbox = ref.watch(pendingOutboxCountProvider).valueOrNull ?? 0;
    final edits = ref.watch(pendingSyncCountProvider).valueOrNull ?? 0;
    final pending = outbox + edits;
    return _StatusCard(
      icon: pending > 0 ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
      title: 'Waiting to sync',
      value: pending == 0
          ? 'Nothing queued — everything you\'ve saved has reached the server'
          : '$pending ${pending == 1 ? 'change' : 'changes'} saved offline, still on this phone only',
    );
  }
}
