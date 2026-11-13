import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/connectivity/reachability.dart';
import 'package:pandapay/features/sync_status/reachability_monitor.dart';

class _Harness {
  _Harness({required this.results, this.online = true});

  /// What each probe answers, in order; the last answer repeats.
  final List<bool> results;
  final bool online;
  int probes = 0;
  final states = <bool?>[];

  late final ServerReachability reachability = ServerReachability(
    probe: () async {
      final index = probes < results.length ? probes : results.length - 1;
      probes += 1;
      return results[index];
    },
    radioUp: () => true,
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isOnlineProvider.overrideWith((_) => Stream.value(online)),
          serverReachabilityProvider.overrideWithValue(reachability),
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
}

Future<void> _elapse(WidgetTester tester, Duration d) async {
  await tester.pump(d);
  await tester.pump();
}

void main() {
  testWidgets('one failed probe does not flash; the confirming probe does', (
    tester,
  ) async {
    final h = _Harness(results: [false, false]);
    await h.pump(tester);
    expect(h.probes, 0, reason: 'nothing is probed at launch');

    await _elapse(tester, ReachabilityMonitor.firstProbeDelay);
    expect(h.probes, 1);
    expect(h.states, isEmpty, reason: 'a single failure is not reported');

    await _elapse(tester, ReachabilityMonitor.confirmDelay);
    expect(h.probes, 2);
    expect(h.states, [false]);
  });

  testWidgets('a failure that the confirming probe contradicts is dropped', (
    tester,
  ) async {
    final h = _Harness(results: [false, true]);
    await h.pump(tester);
    await _elapse(tester, ReachabilityMonitor.firstProbeDelay);
    await _elapse(tester, ReachabilityMonitor.confirmDelay);
    expect(h.probes, 2);
    expect(h.states, [true]);
    expect(h.states, isNot(contains(false)));
  });

  testWidgets('an unreachable server is re-probed and recovery is reported', (
    tester,
  ) async {
    final h = _Harness(results: [false, false, false, true]);
    await h.pump(tester);
    await _elapse(tester, ReachabilityMonitor.firstProbeDelay);
    await _elapse(tester, ReachabilityMonitor.confirmDelay);
    expect(h.states, [false]);

    await _elapse(tester, ReachabilityMonitor.unreachableInterval);
    expect(h.probes, 3);
    expect(h.states, [false]);
    await _elapse(tester, ReachabilityMonitor.unreachableInterval);
    expect(h.probes, 4);
    expect(h.states, [false, true]);
  });

  testWidgets('a healthy server is only re-probed on the slow interval', (
    tester,
  ) async {
    final h = _Harness(results: [true]);
    await h.pump(tester);
    await _elapse(tester, ReachabilityMonitor.firstProbeDelay);
    expect(h.probes, 1);
    await _elapse(tester, const Duration(seconds: 30));
    expect(h.probes, 1);
    await _elapse(tester, ReachabilityMonitor.healthyInterval);
    expect(h.probes, 2);
  });

  testWidgets('never probes while the radio is down', (tester) async {
    final h = _Harness(results: [false], online: false);
    await h.pump(tester);
    await _elapse(tester, const Duration(minutes: 3));
    expect(h.probes, 0);
    expect(h.states, isEmpty);
  });

  testWidgets('disposing the scope cancels the pending probe timer', (
    tester,
  ) async {
    final h = _Harness(results: [true]);
    await h.pump(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 2));
    expect(h.probes, 0);
  });

  testWidgets('polling pauses in the background and probes on resume', (
    tester,
  ) async {
    final h = _Harness(results: [true]);
    await h.pump(tester);
    await _elapse(tester, ReachabilityMonitor.firstProbeDelay);
    expect(h.probes, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _elapse(tester, const Duration(minutes: 5));
    expect(h.probes, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _elapse(tester, Duration.zero);
    expect(h.probes, 2);
  });
}
