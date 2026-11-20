import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/connectivity/api_answer_evidence.dart';
import 'package:pandapay/data/connectivity/reachability.dart';
import 'package:pandapay/features/sync_status/reachability_monitor.dart';

class _Harness {
  _Harness({required this.results, this.online = true});

  /// What each probe answers, in order; the last answer repeats.
  final List<bool> results;
  final bool online;
  int probes = 0;
  final states = <bool?>[];
  DateTime now = DateTime.utc(2026, 11, 20, 12);

  late final ApiAnswerEvidence evidence = ApiAnswerEvidence(now: () => now);

  late final ServerReachability reachability = ServerReachability(
    probe: () async {
      final index = probes < results.length ? probes : results.length - 1;
      probes += 1;
      return results[index];
    },
    radioUp: () => true,
  );

  Future<void> pump(WidgetTester tester) async {
    ReachabilityMonitor.clock = () => now;
    addTearDown(() => ReachabilityMonitor.clock = DateTime.now);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isOnlineProvider.overrideWith((_) => Stream.value(online)),
          serverReachabilityProvider.overrideWithValue(reachability),
          apiAnswerEvidenceProvider.overrideWithValue(evidence),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            ref.listen<bool?>(
              reachabilityMonitorProvider,
              (_, next) => states.add(next),
            );
            ref.watch(reachabilityMonitorProvider);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> elapse(WidgetTester tester, Duration d) async {
    now = now.add(d);
    await tester.pump(d);
    await tester.pump();
  }
}

void main() {
  testWidgets('failures are not reported until three in a row span the outage window', (
    tester,
  ) async {
    final h = _Harness(results: [false]);
    await h.pump(tester);
    expect(h.probes, 0, reason: 'nothing is probed at launch');

    await h.elapse(tester, ReachabilityMonitor.firstProbeDelay);
    expect(h.probes, 1);
    await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    expect(h.probes, 2);
    await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    expect(h.probes, 3, reason: 'three failures, but only 8 s apart');
    expect(h.states, isEmpty, reason: 'a short blip is never reported');

    // Keep failing until the first and the latest failure are far enough apart.
    for (var i = 0; i < 6 && h.states.isEmpty; i++) {
      await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    }
    expect(h.states, [false]);
    expect(
      h.now.difference(DateTime.utc(2026, 11, 20, 12)) >=
          ReachabilityMonitor.firstProbeDelay + ReachabilityMonitor.minOutage,
      isTrue,
    );
  });

  testWidgets('a failure that a later probe contradicts is dropped', (tester) async {
    final h = _Harness(results: [false, false, true]);
    await h.pump(tester);
    await h.elapse(tester, ReachabilityMonitor.firstProbeDelay);
    await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    expect(h.probes, 3);
    expect(h.states, [true]);
    expect(h.states, isNot(contains(false)));
  });

  testWidgets('an unreachable server is re-probed and recovery is reported', (
    tester,
  ) async {
    final h = _Harness(results: [false, false, false, false, false, false, true]);
    await h.pump(tester);
    await h.elapse(tester, ReachabilityMonitor.firstProbeDelay);
    for (var i = 0; i < 10 && h.states.isEmpty; i++) {
      await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    }
    expect(h.states, [false]);
    for (var i = 0; i < 4 && h.states.length < 2; i++) {
      await h.elapse(tester, ReachabilityMonitor.unreachableInterval);
    }
    expect(h.states, [false, true]);
  });

  testWidgets('a healthy server is only re-probed on the slow interval', (tester) async {
    final h = _Harness(results: [true]);
    await h.pump(tester);
    await h.elapse(tester, ReachabilityMonitor.firstProbeDelay);
    expect(h.probes, 1);
    await h.elapse(tester, const Duration(seconds: 30));
    expect(h.probes, 1);
    await h.elapse(tester, ReachabilityMonitor.healthyInterval);
    expect(h.probes, 2);
  });

  testWidgets('a real answer from the API stands in for the probe', (tester) async {
    final h = _Harness(results: [false]);
    await h.pump(tester);
    h.evidence.note(200);
    await h.elapse(tester, ReachabilityMonitor.firstProbeDelay);
    expect(h.probes, 0, reason: 'the app already knows the server answered');
    expect(h.states, [true]);
  });

  testWidgets('a probe that fails while the API answered is not a failure', (tester) async {
    final h = _Harness(results: [false]);
    await h.pump(tester);
    await h.elapse(tester, ReachabilityMonitor.firstProbeDelay);
    expect(h.probes, 1);
    h.evidence.note(304);
    await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    expect(h.states, [true]);
  });

  testWidgets('an answer during a reported outage clears it at once', (tester) async {
    final h = _Harness(results: [false]);
    await h.pump(tester);
    await h.elapse(tester, ReachabilityMonitor.firstProbeDelay);
    for (var i = 0; i < 10 && h.states.isEmpty; i++) {
      await h.elapse(tester, ReachabilityMonitor.confirmDelay);
    }
    expect(h.states, [false]);
    h.evidence.note(200);
    await tester.pump();
    expect(h.states, [false, true]);
  });

  testWidgets('never probes while the radio is down', (tester) async {
    final h = _Harness(results: [false], online: false);
    await h.pump(tester);
    await h.elapse(tester, const Duration(minutes: 3));
    expect(h.probes, 0);
    expect(h.states, isEmpty);
  });

  testWidgets('disposing the scope cancels the pending probe timer', (tester) async {
    final h = _Harness(results: [true]);
    await h.pump(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 2));
    expect(h.probes, 0);
  });

  testWidgets('polling pauses in the background; resume waits for the start-up burst', (
    tester,
  ) async {
    final h = _Harness(results: [true]);
    await h.pump(tester);
    await h.elapse(tester, ReachabilityMonitor.firstProbeDelay);
    expect(h.probes, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await h.elapse(tester, const Duration(minutes: 5));
    expect(h.probes, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await h.elapse(tester, Duration.zero);
    expect(h.probes, 1, reason: 'not while the app is refreshing everything');
    await h.elapse(tester, ReachabilityMonitor.resumeProbeDelay);
    expect(h.probes, 2);
  });
}
