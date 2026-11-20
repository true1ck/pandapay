import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/connectivity/api_answer_evidence.dart';
import '../../data/connectivity/reachability.dart';

/// Debounced "can this phone actually reach PandaPay?" for the sync-status
/// strip (WP-banner).
///
/// `isOnlineProvider` only says the radio is up; on captive or dead Wi-Fi that
/// reads as online. [ServerReachability] answers the real question with one
/// small `GET /health`, but nothing probes it continuously. This notifier is
/// the only thing that does, and only while the radio is up:
///
/// * nothing is probed at launch (the first probe waits [firstProbeDelay]);
/// * a real answer from the API (any response below 500, see
///   [ApiAnswerEvidence]) is better proof than a probe: while one arrived in
///   the last [evidenceFresh] no probe is sent, and a probe that fails while
///   one arrived is not a failure;
/// * `true` is reported at once on any success or answer;
/// * `false` needs [failuresToFlag] failures in a row whose first and latest
///   are at least [minOutage] apart, so a slow moment (the server answering
///   its own start-up burst late) never flashes the strip; a real outage is
///   reported within about 20 s;
/// * a healthy server is re-checked every [healthyInterval] (one tiny request
///   a minute while the app is in the foreground), an unreachable one every
///   [unreachableInterval] so recovery is noticed quickly;
/// * a resume re-probes after [resumeProbeDelay], not during the burst of
///   refreshes the app starts itself; going offline stops everything.
///
/// State: `true` reachable, `false` confirmed unreachable, `null` unknown
/// (radio down, not probed yet). Unknown is treated as fine by every reader.
/// Probing never blocks the UI: it is a timer plus a future.
class ReachabilityMonitor extends Notifier<bool?> {
  static const firstProbeDelay = Duration(seconds: 3);
  static const resumeProbeDelay = Duration(seconds: 3);
  static const confirmDelay = Duration(seconds: 4);
  static const unreachableInterval = Duration(seconds: 10);
  static const healthyInterval = Duration(seconds: 60);
  static const failuresToFlag = 3;
  static const minOutage = Duration(seconds: 15);
  static const evidenceFresh = Duration(seconds: 20);

  /// Wall clock for the outage span; tests drive their own.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  Timer? _timer;
  bool _paused = false;
  int _generation = 0;
  int _failures = 0;
  DateTime? _firstFailureAt;
  late ServerReachability _reachability;
  late ApiAnswerEvidence _evidence;

  @override
  bool? build() {
    final online = ref.watch(isOnlineProvider.select((v) => v.valueOrNull));
    _reachability = ref.watch(serverReachabilityProvider);
    _evidence = ref.watch(apiAnswerEvidenceProvider);
    final generation = ++_generation;
    _failures = 0;
    _firstFailureAt = null;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _generation++;
    });
    if (online != true) return null;
    _paused = false;
    // An answer from the API clears an outage at once, without waiting for the
    // next probe.
    final answers = _evidence.answers.listen((_) {
      if (generation != _generation) return;
      _failures = 0;
      _firstFailureAt = null;
      if (state != true) state = true;
    });
    ref.onDispose(answers.cancel);
    // H1-9: no polling while the app is paused, inactive or detached.
    final lifecycle = AppLifecycleListener(
      onStateChange: (lifecycleState) {
        if (lifecycleState == AppLifecycleState.resumed) {
          _paused = false;
          _schedule(generation, resumeProbeDelay);
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

  void _reachable(int generation) {
    _failures = 0;
    _firstFailureAt = null;
    state = true;
    _schedule(generation, healthyInterval);
  }

  Future<void> _probe(int generation) async {
    if (_evidence.answeredWithin(evidenceFresh)) {
      _reachable(generation);
      return;
    }
    final reachable = await _reachability.check(force: true);
    if (generation != _generation || _paused) return;
    if (reachable || _evidence.answeredWithin(evidenceFresh)) {
      _reachable(generation);
      return;
    }
    final at = clock();
    _failures += 1;
    _firstFailureAt ??= at;
    if (_failures >= failuresToFlag &&
        at.difference(_firstFailureAt!) >= minOutage) {
      state = false;
      _schedule(generation, unreachableInterval);
    } else {
      _schedule(generation, confirmDelay);
    }
  }
}

final reachabilityMonitorProvider =
    NotifierProvider<ReachabilityMonitor, bool?>(ReachabilityMonitor.new);
