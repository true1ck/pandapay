
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../shared_expenses/runtime/shared_attention.dart';
import 'queue_totals.dart';
import 'reachability_monitor.dart';

/// What the app-wide sync-status strip shows, in priority order (WP-banner,
/// owner decision D2). Exactly one is true at a time.
enum SyncStatusMode {
  /// Healthy and nothing to say: the strip has zero height.
  hidden,

  /// No network. Everything on screen is saved data.
  offline,

  /// The network is up but PandaPay does not answer (captive Wi-Fi, outage).
  unreachable,

  /// Online, reachable, and changes have been waiting for more than 2 s.
  syncing,

  /// Saved changes the server refused, or that are stuck: a person must act.
  needsAttention,
}

/// The one immutable value behind the strip and the Sync status sheet.
/// Override [syncStatusSummaryProvider] in tests to drive any state.
@immutable
class SyncStatusSummary {
  const SyncStatusSummary({
    required this.mode,
    this.pendingCount = 0,
    this.attentionCount = 0,
    this.lastSyncedAt,
  });

  final SyncStatusMode mode;

  /// Changes waiting to be sent for the signed-in account (0 when signed out).
  final int pendingCount;

  /// Changes that need attention: refused rows plus Split's own count.
  final int attentionCount;

  /// Newest cached server response. Only filled while the strip is showing,
  /// so a healthy app never runs the query.
  final DateTime? lastSyncedAt;

  bool get visible => mode != SyncStatusMode.hidden;

  @override
  bool operator ==(Object other) =>
      other is SyncStatusSummary &&
      other.mode == mode &&
      other.pendingCount == pendingCount &&
      other.attentionCount == attentionCount &&
      other.lastSyncedAt == lastSyncedAt;

  @override
  int get hashCode =>
      Object.hash(mode, pendingCount, attentionCount, lastSyncedAt);

  @override
  String toString() =>
      'SyncStatusSummary($mode, pending: $pendingCount, '
      'attention: $attentionCount, lastSyncedAt: $lastSyncedAt)';
}

/// How long changes must keep waiting (while online and reachable) before the
/// strip says "Syncing". A save that goes out in a moment never flashes it.
const Duration syncingStripDelay = Duration(seconds: 2);

final _hasAccountProvider = Provider<bool>(
  (ref) => isAccountNamespace(ref.watch(cacheNamespaceProvider)),
);

final _pendingCountProvider = Provider<int>((ref) {
  if (!ref.watch(_hasAccountProvider)) return 0;
  return ref.watch(
    syncQueueTotalsProvider.select((v) => v.valueOrNull?.pending ?? 0),
  );
});

final _attentionCountProvider = Provider<int>((ref) {
  if (!ref.watch(_hasAccountProvider)) return 0;
  final queues = ref.watch(
    syncQueueTotalsProvider.select((v) => v.valueOrNull?.attention ?? 0),
  );
  return queues + ref.watch(needsAttentionCountProvider);
});

/// Radio down is the only way to be "offline". Unknown (the connectivity
/// stream has not emitted yet) counts as online, as it does everywhere else.
final _radioDownProvider = Provider<bool>(
  (ref) => ref.watch(isOnlineProvider.select((v) => v.valueOrNull == false)),
);

final _serverDownProvider = Provider<bool>(
  (ref) => ref.watch(reachabilityMonitorProvider) == false,
);

/// The single, narrow input of the strip. Built from `isOnlineProvider`, the
/// debounced reachability monitor, [QueueRegistry] counts and Split's
/// `needsAttentionCountProvider`. Signed out (no account), only the first two
/// states exist and no counts are carried.
final syncStatusSummaryProvider = Provider<SyncStatusSummary>((ref) {
  final pending = ref.watch(_pendingCountProvider);
  final attention = ref.watch(_attentionCountProvider);

  final SyncStatusMode mode;
  if (ref.watch(_radioDownProvider)) {
    mode = SyncStatusMode.offline;
  } else if (ref.watch(_serverDownProvider)) {
    mode = SyncStatusMode.unreachable;
  // Syncing is background work: never shown. Only "offline" and "can't reach
  // PandaPay" ever reach the user.
  } else {
    // Local-first: a change the server refused stays saved on the phone. We
    // never ask the user to act on it from the strip (attention is still counted
    // for the details sheet), so this is hidden.
    mode = SyncStatusMode.hidden;
  }

  return SyncStatusSummary(
    mode: mode,
    pendingCount: pending,
    attentionCount: attention,
    lastSyncedAt: mode == SyncStatusMode.hidden
        ? null
        : ref.watch(lastSyncedAtProvider).valueOrNull,
  );
});
