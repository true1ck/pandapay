import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/connectivity/reachability.dart';

/// Debounced "can this phone actually reach PandaPay?" for the sync-status
/// strip (WP-banner).
///
/// `isOnlineProvider` only says the radio is up; on captive or dead Wi-Fi that
/// reads as online. [ServerReachability] answers the real question with one
/// small `GET /app-status`, but nothing probes it continuously. This notifier
/// is the only thing that does, and only while the radio is up:
///
/// * nothing is probed at launch (the first probe waits [firstProbeDelay], so
///   it never competes with the cold start);
/// * a failed probe is not reported. It is confirmed by a second probe
///   [confirmDelay] later, so one dropped packet never flashes the strip;
///   two failures in a row report `false`;
/// * `true` is reported at once on any success;
/// * a healthy server is re-checked every [healthyInterval] (one tiny request
///   a minute while the app is in the foreground), an unreachable one every
///   [unreachableInterval] so recovery is noticed quickly;
/// * a resume re-probes straight away; going offline stops everything.
///
/// State: `true` reachable, `false` confirmed unreachable, `null` unknown
/// (radio down, not probed yet). Unknown is treated as fine by every reader.
/// Probing never blocks the UI: it is a timer plus a future.
class ReachabilityMonitor extends Notifier<bool?> {
  static const firstProbeDelay = Duration(seconds: 3);
  static const confirmDelay = Duration(milliseconds: 1500);
  static const unreachableInterval = Duration(seconds: 10);
  static const healthyInterval = Duration(seconds: 60);

  Timer? _timer;
  bool _paused = false;
  int _generation = 0;
  int _failures = 0;
  late ServerReachability _reachability;

  @override
  bool? build() {
    final online = ref.watch(isOnlineProvider.select((v) => v.valueOrNull));
    _reachability = ref.watch(serverReachabilityProvider);
    final generation = ++_generation;
    _failures = 0;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _generation++;
    });
    if (online != true) return null;
    _paused = false;
    // H1-9: no polling while the app is paused, inactive or detached.
    final lifecycle = AppLifecycleListener(
      onStateChange: (lifecycleState) {
        if (lifecycleState == AppLifecycleState.resumed) {
          _paused = false;
          _schedule(generation, Duration.zero);
        } else {
          _paused = true;
          _timer?.cancel();
          _timer = null;
        }
      },
    );
    ref.onDispose(lifecycle.dispose);
    _schedule(generation, firstProbeDelay);
    return null;
  }

  void _schedule(int generation, Duration after) {
    if (generation != _generation || _paused) return;
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(_probe(generation)));
  }

  Future<void> _probe(int generation) async {
    final reachable = await _reachability.check(force: true);
    if (generation != _generation || _paused) return;
    if (reachable) {
      _failures = 0;
      state = true;
      _schedule(generation, healthyInterval);
      return;
    }
    _failures += 1;
    if (_failures >= 2) {
      state = false;
      _schedule(generation, unreachableInterval);
    } else {
      _schedule(generation, confirmDelay);
    }
  }
}

final reachabilityMonitorProvider =
    NotifierProvider<ReachabilityMonitor, bool?>(ReachabilityMonitor.new);
