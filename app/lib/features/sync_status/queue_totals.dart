import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local/queue_registry.dart';

/// Queue counts behind the sync-status strip (WP-banner, decision D2).
///
/// Everything here is read-only SQL through [QueueRegistry], which already
/// knows every durable queue, which rows are applied, and which are parked.
/// Nothing in this file writes, sends or retries.

/// What the strip needs from the queues: how many changes are waiting and how
/// many were refused and need a person.
@immutable
class SyncQueueTotals {
  const SyncQueueTotals({this.pending = 0, this.attention = 0});

  /// Changes that will go out by themselves (waiting, or in a backoff).
  final int pending;

  /// Parked or blocked rows: refused for good, or stuck behind something.
  final int attention;

  static const zero = SyncQueueTotals();

  @override
  bool operator ==(Object other) =>
      other is SyncQueueTotals &&
      other.pending == pending &&
      other.attention == attention;

  @override
  int get hashCode => Object.hash(pending, attention);

  @override
  String toString() => 'SyncQueueTotals(pending: $pending, attention: $attention)';
}

/// Queues the strip does not call "changes waiting to sync". Raw SMS waiting
/// to be read is local work, and the SMS-facts upload is a background
/// pipeline that can legitimately hold thousands of rows: showing it as
/// "Syncing 4,812 changes" would be noise, and every new message would make
/// the strip flicker. They still appear, in plain words, in the Sync status
/// sheet.
const Set<String> syncStatusBackgroundQueues = {'sms_intake', 'v2_outbox'};

/// Queues whose refused rows `needsAttentionCountProvider` already counts
/// (Split commands and private per-transaction splits). Counting their parked
/// rows here too would show every one of them twice.
const Set<String> syncStatusAttentionCountedElsewhere = {
  'shared_commands',
  'split_documents',
};

/// Plain-language name of each queue, for the Sync status sheet.
const Map<String, String> syncQueueLabels = {
  'sync_pending_changes': 'Edits',
  'transaction_outbox_entries': 'New transactions',
  'duplicate_resolution_outbox': 'Duplicate reviews',
  'command_outbox': 'Other changes',
  'transaction_tag_outbox': 'Tags',
  'foreign_payments_outbox': 'Foreign payments',
  'statement_import': 'Statement imports',
  'shared_commands': 'Split changes',
  'split_documents': 'Split details',
  'v2_outbox': 'Bank message uploads',
  'sms_intake': 'Messages to read',
};

/// Totals for the strip, for one account. Cheap: one small COUNT per queue.
SyncQueueTotals computeSyncQueueTotals(
  QueueRegistry registry,
  String namespace,
) {
  var pending = 0;
  var attention = 0;
  for (final spec in registry.queues) {
    if (spec.kind != QueueKind.outbox) continue;
    if (syncStatusBackgroundQueues.contains(spec.name)) continue;
    final counts = registry.countsFor(spec.name, namespace);
    pending += counts.pending;
    if (!syncStatusAttentionCountedElsewhere.contains(spec.name)) {
      attention += counts.parked + counts.blocked;
    }
  }
  return SyncQueueTotals(pending: pending, attention: attention);
}

/// One row of the Sync status sheet.
@immutable
class SyncQueueLine {
  const SyncQueueLine(this.queue, this.label, this.counts);

  /// Registry name, e.g. `command_outbox`.
  final String queue;
  final String label;
  final QueueCounts counts;

  /// "2 waiting to send, 1 not accepted".
  String get description {
    final parts = <String>[
      if (counts.pending > 0) '${counts.pending} waiting to send',
      if (counts.parked > 0) '${counts.parked} not accepted',
      if (counts.blocked > 0) '${counts.blocked} waiting for sign-in',
    ];
    return parts.join(', ');
  }
}

/// Every send queue that holds something for [namespace], in registry order.
List<SyncQueueLine> buildSyncQueueLines(
  QueueRegistry registry,
  String namespace,
) {
  final lines = <SyncQueueLine>[];
  for (final spec in registry.queues) {
    if (spec.kind != QueueKind.outbox) continue;
    final counts = registry.countsFor(spec.name, namespace);
    if (counts.isEmpty) continue;
    lines.add(
      SyncQueueLine(spec.name, syncQueueLabels[spec.name] ?? spec.name, counts),
    );
  }
  return lines;
}

bool isAccountNamespace(String namespace) => namespace != 'signed-out';

final queueRegistryProvider = FutureProvider<QueueRegistry>((ref) async {
  return QueueRegistry(await ref.watch(appDatabaseProvider.future));
});

/// Bump to recount straight away (after a Retry, say).
final syncStatusRefreshProvider = StateProvider<int>((ref) => 0);

/// Live totals for the signed-in account. Recounts on queue-change events
/// (coalesced), on reconnect, and on a slow timer as a safety net for queues
/// that do not announce changes (3 s while something is waiting so a drain is
/// noticed, 10 s otherwise). Nothing runs while the app is in the background
/// or while signed out. All reads are small and indexed by account; no row
/// data is loaded.
final syncQueueTotalsProvider = StreamProvider<SyncQueueTotals>((ref) {
  final namespace = ref.watch(cacheNamespaceProvider);
  if (!isAccountNamespace(namespace)) return Stream.value(SyncQueueTotals.zero);

  const firstCount = Duration(milliseconds: 1500);
  const coalesce = Duration(milliseconds: 300);
  const busyTick = Duration(seconds: 3);
  const idleTick = Duration(seconds: 10);

  final controller = StreamController<SyncQueueTotals>();
  QueueRegistry? registry;
  SyncQueueTotals? last;
  Timer? timer;
  var disposed = false;

  bool appActive() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  // Declared first so `schedule` and `count` can call each other.
  late final void Function() countNow;

  void schedule(Duration after) {
    timer?.cancel();
    if (disposed) return;
    timer = Timer(after, () => countNow());
  }

  void count() {
    final reg = registry;
    if (disposed || reg == null) return;
    if (appActive()) {
      try {
        final totals = computeSyncQueueTotals(reg, namespace);
        if (totals != last) {
          last = totals;
          controller.add(totals);
        }
      } catch (_) {
        // A locked or half-migrated database must never break the app shell.
      }
    }
    schedule((last?.pending ?? 0) > 0 ? busyTick : idleTick);
  }

  countNow = count;

  void soon() => schedule(coalesce);

  ref.onDispose(() {
    disposed = true;
    timer?.cancel();
    unawaited(controller.close());
  });

  ref.watch(queueRegistryProvider.future).then((value) {
    if (disposed) return;
    registry = value;
    schedule(firstCount);
  }, onError: (_) {});

  ref.listen(financialStoreRevisionProvider('transactions'), (_, _) => soon());
  ref.listen(commandOutboxRevisionProvider, (_, _) => soon());
  ref.listen(syncStatusRefreshProvider, (_, _) => soon());
  ref.listen<AsyncValue<bool>>(isOnlineProvider, (_, _) => soon());
  final lifecycle = AppLifecycleListener(onResume: soon);
  ref.onDispose(lifecycle.dispose);

  return controller.stream;
});

/// Per-queue lines for the Sync status sheet; read once when it opens.
final syncQueueBreakdownProvider =
    FutureProvider.autoDispose<List<SyncQueueLine>>((ref) async {
      final namespace = ref.watch(cacheNamespaceProvider);
      if (!isAccountNamespace(namespace)) return const [];
      final registry = await ref.watch(queueRegistryProvider.future);
      return buildSyncQueueLines(registry, namespace);
    });
