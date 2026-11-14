import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local_first/command_outbox.dart';
import 'user_state_sync.dart';

/// WP-C17: fetches the server's synced state and merges it into the phone by
/// last-writer-wins on `clientEditedAt`. Applying an item never queues a push.
///
/// The cursor lives in memory per namespace: the first pull of an app run asks
/// for everything (a few small rows per person), so a wiped or restored phone
/// can never be left with a stale cursor. A newer local edit is kept, whether
/// it is stored or still queued.
class UserStatePuller {
  UserStatePuller({
    required this.api,
    required this.local,
    required this.commands,
    this.stillCurrent,
    this.maxPages = 20,
  });

  final UserStateApi api;
  final UserStateLocal local;
  final CommandOutbox commands;

  /// Returns false when the account changed under a running pull.
  final bool Function()? stillCurrent;
  final int maxPages;

  static final Map<String, String> _cursors = {};

  /// Test hook.
  static void resetCursors() => _cursors.clear();

  /// Returns how many items changed the phone. Throws like the api does.
  Future<int> pull() async {
    if (!kSyncLocalState || userStateUnsupported) return 0;
    final pending = <String, int>{};
    for (final c in commands.pendingOf(UserStateCommand.kinds)) {
      final at = DateTime.tryParse('${c.payload['clientEditedAt']}');
      if (at != null) pending[c.target] = at.millisecondsSinceEpoch;
    }
    var applied = 0;
    var cursor = _cursors[local.ns];
    for (var page = 0; page < maxPages; page++) {
      final result = await api.pull(since: cursor);
      if (stillCurrent?.call() == false) return applied;
      for (final item in result.items) {
        if (applyUserStateItem(
          local,
          item,
          pendingMs: pending['${item.kind}/${item.key}'],
        )) {
          applied++;
        }
      }
      final next = result.cursor;
      if (next != null) _cursors[local.ns] = next;
      if (result.items.length < 500 || next == null || next == cursor) break;
      cursor = next;
    }
    return applied;
  }
}

/// Pulls on sign-in, when the network comes back and on resume (at most once a
/// minute for resume). Read once from the outbox flush provider.
final userStatePullProvider = Provider<void>((ref) {
  if (!kSyncLocalState) return;
  var running = false;
  var disposed = false;
  DateTime? last;
  final startup = ref.read(startupWorkSchedulerProvider);

  Future<void> run({bool force = false}) async {
    if (running || disposed || userStateUnsupported) return;
    final namespace = ref.read(cacheNamespaceProvider);
    if (!namespace.startsWith('user:') ||
        ref.read(isOnlineProvider).valueOrNull == false) {
      return;
    }
    if (!force &&
        last != null &&
        DateTime.now().difference(last!) < const Duration(minutes: 1)) {
      return;
    }
    running = true;
    try {
      final api = userStateApiFor(ref);
      final l = await userStateLocalFor(ref);
      if (api == null || l == null || disposed) return;
      final commands = await ref.read(commandOutboxProvider.future);
      last = DateTime.now();
      final changed = await UserStatePuller(
        api: api,
        local: l,
        commands: commands,
        stillCurrent: () => !disposed && ref.read(cacheNamespaceProvider) == namespace,
      ).pull();
      if (changed > 0 && !disposed) {
        ref.invalidate(bankAccountSummariesProvider);
        ref.invalidate(cardBillLedgerProvider);
        ref.invalidate(cardBillReviewItemsProvider);
        ref.invalidate(recurringReportProvider);
        ref.read(commandOutboxRevisionProvider.notifier).state++;
      }
    } catch (_) {
      // Offline, an old server or a busy account: the next trigger retries.
    } finally {
      running = false;
    }
  }

  ref.listen(isOnlineProvider, (previous, next) {
    if (previous?.valueOrNull == false && next.valueOrNull == true) {
      unawaited(run(force: true));
    }
  });
  ref.listen(cacheNamespaceProvider, (_, next) {
    if (next.startsWith('user:')) {
      startup.enqueue('user-state-pull', () => run(force: true));
    }
  });
  final lifecycle = AppLifecycleListener(onResume: () => unawaited(run()));
  ref.onDispose(() {
    disposed = true;
    startup.cancel('user-state-pull');
    lifecycle.dispose();
  });
  startup.enqueue('user-state-pull', () => run(force: true));
});
