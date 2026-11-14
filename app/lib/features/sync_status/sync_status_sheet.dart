import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../shared_expenses/runtime/shared_attention.dart';
import '../shared_expenses/runtime/shared_providers.dart';
import '../shared_expenses/ui/shared_attention_sheet.dart';
import '../sync/split_sync.dart';
import 'queue_totals.dart';
import 'sync_retry.dart';
import 'sync_status_providers.dart';

/// Opens the Sync status sheet above the app. [context] must be below the root
/// Navigator (the strip itself sits above it, so it passes the Navigator's).
Future<void> showSyncStatusSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const SyncStatusSheet(),
    );

/// "Sync status": the connection, when data was last refreshed, what is
/// waiting in plain words, and a Retry for anything the server refused.
/// Read-only apart from Retry. Counts are read once when the sheet opens (and
/// again after a Retry), never per frame.
class SyncStatusSheet extends ConsumerStatefulWidget {
  const SyncStatusSheet({super.key});

  @override
  ConsumerState<SyncStatusSheet> createState() => _SyncStatusSheetState();
}

class _SyncStatusSheetState extends ConsumerState<SyncStatusSheet> {
  final _busy = <String>{};

  Future<void> _retry(String queue, ParkedRetry action) async {
    if (!_busy.add(queue)) return;
    setState(() {});
    try {
      await action();
      ref.read(syncNudgeProvider)();
    } catch (_) {
      // The rows stay parked with their reason; the list is read again below.
    } finally {
      _busy.remove(queue);
      ref.invalidate(syncQueueBreakdownProvider);
      if (mounted) setState(() {});
    }
  }

  Future<void> _reviewSplit() async {
    try {
      final runtime = await ref.read(sharedExpensesRuntimeProvider.future);
      if (!mounted) return;
      await SharedNeedsAttentionSheet.show(
        context,
        runtime: runtime,
        blockedPrivate: ref.read(blockedSplitCountProvider).valueOrNull ?? 0,
      );
    } catch (_) {
      // Split is not available (signed out, switched off): nothing to review.
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(syncStatusSummaryProvider.select((s) => s.mode));
    final lines = ref.watch(syncQueueBreakdownProvider).valueOrNull ?? const [];
    final retry = ref.watch(syncRetryActionsProvider);
    final discard = ref.watch(syncDiscardActionsProvider);
    final lastSynced = ref.watch(lastSyncedAtProvider).valueOrNull;
    final splitAttention = ref.watch(needsAttentionCountProvider);

    final (connection, detail) = switch (mode) {
      SyncStatusMode.offline => (
        'Offline',
        'No network. What you see is saved on this phone, and your changes '
            'will send when you are back online.',
      ),
      SyncStatusMode.unreachable => (
        "Can't reach PandaPay",
        'Your network is up, but PandaPay did not answer. Showing saved data; '
            'changes will send when it does.',
      ),
      _ => ('Connected', 'PandaPay is reachable.'),
    };

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sync status', style: BambooFonts.heading(20)),
            const SizedBox(height: 16),
            Semantics(
              container: true,
              label: '$connection. $detail',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connection,
                    style: BambooFonts.ui(16, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _lastSyncedText(lastSynced, DateTime.now()),
              style: BambooFonts.ui(13, color: BambooInk.ink700),
            ),
            const SizedBox(height: 20),
            if (lines.isEmpty && splitAttention == 0)
              Text(
                'Everything is up to date.',
                style: BambooFonts.ui(14, color: BambooInk.ink700),
              ),
            for (final line in lines)
              _QueueRow(
                line: line,
                busy: _busy.contains(line.queue),
                onRetry: line.counts.parked > 0 && retry[line.queue] != null
                    ? () => _retry(line.queue, retry[line.queue]!)
                    : null,
                onDiscard: line.counts.parked > 0 && discard[line.queue] != null
                    ? () => _retry(line.queue, discard[line.queue]!)
                    : null,
              ),
            if (splitAttention > 0)
              _SplitRow(count: splitAttention, onReview: _reviewSplit),
          ],
        ),
      ),
    );
  }

  /// "Last synced today, 6:40 PM", "...yesterday, ..." or "...9 Mar 2020, ...".
  static String _lastSyncedText(DateTime? at, DateTime now) {
    if (at == null) return 'Last synced: not yet';
    final time = DateFormat('h:mm a').format(at);
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(at.year, at.month, at.day);
    final days = today.difference(day).inDays;
    if (days == 0) return 'Last synced today, $time';
    if (days == 1) return 'Last synced yesterday, $time';
    return 'Last synced ${DateFormat('d MMM y').format(at)}, $time';
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.line,
    required this.busy,
    this.onRetry,
    this.onDiscard,
  });

  final SyncQueueLine line;
  final bool busy;
  final VoidCallback? onRetry;

  /// Gives up on what the server refused; its own copy then shows.
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.label,
                  style: BambooFonts.ui(15, weight: FontWeight.w600),
                ),
                Text(
                  line.description,
                  style: BambooFonts.ui(13, color: BambooInk.ink700),
                ),
                if (onDiscard != null)
                  Text(
                    'Some changes could not be saved. Retry them, or discard '
                    'them to go back to what PandaPay has.',
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
              ],
            ),
          ),
          if (onDiscard != null)
            TextButton(
              key: Key('sync-discard-${line.queue}'),
              onPressed: busy ? null : onDiscard,
              child: const Text('Discard'),
            ),
          if (onRetry != null)
            TextButton(
              key: Key('sync-retry-${line.queue}'),
              onPressed: busy ? null : onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}

class _SplitRow extends StatelessWidget {
  const _SplitRow({required this.count, required this.onReview});

  final int count;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Split changes need attention',
                  style: BambooFonts.ui(15, weight: FontWeight.w600),
                ),
                Text(
                  '$count not accepted by the server',
                  style: BambooFonts.ui(13, color: BambooInk.ink700),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('sync-review-split'),
            onPressed: onReview,
            child: const Text('Review'),
          ),
        ],
      ),
    );
  }
}
