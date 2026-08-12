import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local/sync_queue.dart';
import '../../data/sync_api.dart';

/// Plan Phase 4 — the client-side sync loop.
///
/// Push first, then pull, then acknowledge. That order is not arbitrary:
///
///   * Pushing first means the server has this device's edits before it
///     computes what to send back, so the pull reflects the merged state
///     rather than a state this device is about to contradict.
///   * Acknowledging only after applying means a dropped response costs a
///     repeated pull, never a skipped change. Advancing the cursor on receipt
///     would make a crash mid-apply permanently lose everything in that batch,
///     which is precisely the "silent data loss" 0005_sync.sql warns about.
///
/// The whole loop is best-effort and swallows network errors. A failed sync
/// leaves the local database exactly as it was, with the queue intact, and the
/// next trigger retries.
class SyncResult {
  final int pushed;
  final int pulled;
  final int conflicts;
  final bool ranToCompletion;

  const SyncResult({
    required this.pushed,
    required this.pulled,
    required this.conflicts,
    required this.ranToCompletion,
  });

  static const idle = SyncResult(pushed: 0, pulled: 0, conflicts: 0, ranToCompletion: true);
}

class SyncEngine {
  final Ref _ref;
  bool _running = false;

  SyncEngine(this._ref);

  static String get _platform {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'web';
  }

  /// Runs one full cycle. Re-entrant calls are dropped rather than queued: two
  /// concurrent cycles would push the same queued changes twice, and while the
  /// server is idempotent enough to survive that, the duplicate conflict rows
  /// it would generate are user-visible noise.
  Future<SyncResult> sync() async {
    if (_running) return SyncResult.idle;
    final api = _ref.read(syncApiProvider);
    if (api == null) return SyncResult.idle;

    _running = true;
    try {
      final queue = await _ref.read(syncQueueProvider.future);

      var deviceId = queue.deviceId;
      if (deviceId == null) {
        deviceId = await api.registerDevice(
          platform: _platform,
          appVersion: _ref.read(appVersionProvider).valueOrNull,
        );
        queue.deviceId = deviceId;
      }

      final pushed = await _push(api, queue, deviceId);
      final (pulled, conflicts) = await _pullAndApply(api, queue, deviceId);

      return SyncResult(
        pushed: pushed,
        pulled: pulled,
        conflicts: conflicts,
        ranToCompletion: true,
      );
    } catch (_) {
      // Offline, or the server is unreachable. Everything the user did is
      // still in the local queue; the next trigger tries again.
      return const SyncResult(pushed: 0, pulled: 0, conflicts: 0, ranToCompletion: false);
    } finally {
      _running = false;
    }
  }

  Future<int> _push(SyncApi api, SyncQueue queue, String deviceId) async {
    final pending = queue.pending();
    if (pending.isEmpty) return 0;

    final results = await api.push(deviceId: deviceId, changes: pending);
    var applied = 0;
    for (final result in results) {
      if (result.clientSeq == null) continue;
      if (result.applied) {
        queue.remove(result.clientSeq!);
        applied++;
      } else if (result.isPermanentFailure) {
        // The server will never accept this one. Dropping it is the only way
        // to stop it blocking everything queued behind it — see
        // SyncQueue.recordFailure for why that trade is the right way round.
        queue.remove(result.clientSeq!);
      } else {
        queue.recordFailure(result.clientSeq!, result.reason ?? 'unknown');
      }
    }
    return applied;
  }

  Future<(int, int)> _pullAndApply(SyncApi api, SyncQueue queue, String deviceId) async {
    var totalPulled = 0;
    var totalConflicts = 0;
    var since = queue.lastServerSeq;

    // Loops on `hasMore` so a device returning after a long absence catches up
    // fully instead of one page per trigger. Bounded so a pathological
    // backlog can't spin here forever holding the UI's refresh.
    for (var page = 0; page < 20; page++) {
      final batch = await api.pull(deviceId: deviceId, since: since);
      totalConflicts = batch.conflicts.length;

      if (batch.changes.isEmpty) break;

      // Applying means invalidating the providers that read the affected
      // entities, not writing into a local mirror: the app is
      // server-authoritative (see the response cache's own doc comment), so
      // "apply" correctly means "re-read from the server".
      _invalidateFor(batch.changes.map((c) => c['entity'] as String).toSet());

      since = batch.latestServerSeq;
      queue.lastServerSeq = since;
      await api.ack(deviceId: deviceId, serverSeq: since);
      totalPulled += batch.changes.length;

      if (!batch.hasMore) break;
    }

    _ref.read(unacknowledgedConflictsProvider.notifier).state = totalConflicts;
    return (totalPulled, totalConflicts);
  }

  void _invalidateFor(Set<String> entities) {
    if (entities.contains('transactions')) {
      _ref.invalidate(transactionsProvider);
    }
    if (entities.contains('user_cards')) {
      _ref.invalidate(userCardsProvider);
      _ref.invalidate(myCardsProvider);
    }
    if (entities.contains('card_overrides')) {
      _ref.invalidate(cardOverridesProvider);
    }
    // The ranking depends on all three, so it is refreshed whenever any of
    // them moved rather than being enumerated per entity.
    _ref.invalidate(rankedRecommendationsProvider);
  }
}

final syncEngineProvider = Provider<SyncEngine>(SyncEngine.new);

/// How many automatically-resolved conflicts the user hasn't seen yet. Drives
/// the badge on Sync & Backup — a conflict that resolved silently and was
/// never surfaced is the failure mode this whole subsystem exists to avoid.
final unacknowledgedConflictsProvider = StateProvider<int>((ref) => 0);

/// Drives the loop. Watched from `_AppShell` (router.dart) alongside the other
/// lifecycle providers.
///
/// Triggers on sign-in and on regaining connectivity — the two moments when
/// there is either something new to fetch or a queue that can finally drain.
/// Deliberately not on a timer: a periodic poll costs battery on a device
/// where nothing changed, and the two events below already cover every case
/// that matters for a single-user-multi-device product. A push notification
/// would be the right addition when one device needs to learn about another's
/// change immediately, which no screen currently requires.
final syncLifecycleProvider = Provider<void>((ref) {
  ref.listen<String?>(accessTokenProvider, (previous, next) async {
    if (previous == null && next != null) {
      await ref.read(syncEngineProvider).sync();
    }
    if (previous != null && next == null) {
      // Sign-out: the queue and cursor belong to the account that just left.
      final queue = await ref.read(syncQueueProvider.future);
      queue.clear();
    }
  });

  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) async {
    final cameOnline = previous?.valueOrNull == false && next.valueOrNull == true;
    if (cameOnline) {
      await ref.read(syncEngineProvider).sync();
    }
  });
});
