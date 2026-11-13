import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/crash_reporter.dart' show crashReporter;
import '../../app/providers.dart';
import 'known_connectivity.dart';
import 'online_stream.dart';
import 'reachability.dart';

/// App-root connectivity wiring (WP-C1). Watched once from `PandaPayApp.build`
/// so it lives for the whole process, signed in or not. It has no UI and no
/// state; it only does three things.
///
/// 1. **Subscribes `isOnlineProvider` early.** The provider is seeded with the
///    current connectivity, but nothing used to read it before the signed-in
///    shell's lifecycle providers started (500 ms after the first frame).
///    Reading it here means `_isKnownOffline()` and `KnownConnectivity` are
///    populated from the first moments of the process. The shell's own
///    `ref.listen`s still see exactly the same transitions: a provider that is
///    already alive hands a late listener its current value, never a
///    `false -> true` pair.
/// 2. **Keeps the reachability cache honest.** Any connectivity change and any
///    resume drops the cached `/app-status` probe result.
/// 3. **Re-checks `appStatusProvider`** (finding C-05). That provider fails
///    open to `null` and is cached for the process lifetime, so a
///    maintenance/forced-upgrade flag raised while the app was offline would
///    never be seen. On offline -> online, once the server answers a probe, the
///    provider is invalidated; on resume, a `null` (failed-open) status is
///    re-checked the same way. A re-check that fails is still fail-open
///    (`null`) and never blocks the app.
/// How often a known-offline app in the foreground asks the platform again
/// whether it is still offline (H1-8).
const connectivityRepollInterval = Duration(seconds: 60);

final connectivityBootstrapProvider = Provider<void>((ref) {
  var disposed = false;
  Timer? repollTimer;
  var foreground = true;
  ref.onDispose(() {
    disposed = true;
    repollTimer?.cancel();
    repollTimer = null;
  });

  /// H1-8: the plugin can miss an "online" event, leaving every gated path
  /// skipped until the next one. Ask it directly; if it says online while we
  /// believe offline, rebuild the stream (its seed emits online, so listeners
  /// see the usual offline -> online transition exactly once).
  Future<void> repoll() async {
    if (!KnownConnectivity.knownOffline) return;
    try {
      final results = await ref.read(connectivityProvider).checkConnectivity();
      if (disposed) return;
      if (connectivityResultToIsOnline(results) &&
          KnownConnectivity.knownOffline) {
        ref.invalidate(isOnlineProvider);
      }
    } catch (_) {
      // No answer: keep the current belief.
    }
  }

  // One lightweight timer, only while the app is in the foreground AND known
  // offline, so an online or backgrounded app (and widget tests that never go
  // offline) have no pending timer.
  void syncRepollTimer() {
    final want = !disposed && foreground && KnownConnectivity.knownOffline;
    if (want && repollTimer == null) {
      repollTimer = Timer.periodic(
        connectivityRepollInterval,
        (_) => unawaited(repoll()),
      );
    } else if (!want) {
      repollTimer?.cancel();
      repollTimer = null;
    }
  }

  final reachability = ref.watch(serverReachabilityProvider);

  Future<void> recheckAppStatus({required bool force}) async {
    final reachable = await reachability.check(force: force);
    if (disposed || !reachable) return;
    ref.invalidate(appStatusProvider);
  }

  ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
    reachability.invalidate();
    syncRepollTimer();
    final cameOnline =
        previous?.valueOrNull == false && next.valueOrNull == true;
    if (cameOnline) {
      unawaited(recheckAppStatus(force: true));
      // WP-C12b: send crash reports that queued while offline.
      crashReporter.start();
    }
  });

  final lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      foreground = state == AppLifecycleState.resumed;
      syncRepollTimer();
    },
    onResume: () {
      reachability.invalidate();
      if (KnownConnectivity.knownOffline) {
        unawaited(repoll());
        return;
      }
      if (!ref.exists(appStatusProvider)) return;
      final status = ref.read(appStatusProvider);
      if (!status.isLoading && status.valueOrNull == null) {
        unawaited(recheckAppStatus(force: false));
      }
    },
  );
  ref.onDispose(lifecycle.dispose);
});
