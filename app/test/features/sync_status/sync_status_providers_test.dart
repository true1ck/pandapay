import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_attention.dart';
import 'package:pandapay/features/sync_status/queue_totals.dart';
import 'package:pandapay/features/sync_status/reachability_monitor.dart';
import 'package:pandapay/features/sync_status/sync_status_providers.dart';

const _signedIn = 'user:11111111-1111-4111-8111-111111111111';

/// Reachability as the debounced monitor would report it.
class _FixedMonitor extends ReachabilityMonitor {
  _FixedMonitor(this.value);
  final bool? value;
  @override
  bool? build() => value;
}

final _totals = StateProvider<SyncQueueTotals>((_) => SyncQueueTotals.zero);

/// `online == null` is "not known yet" (the connectivity stream has not
/// emitted), which must behave like online.
List<Override> _overrides({
  bool? online = true,
  bool? reachable = true,
  String namespace = _signedIn,
  int shared = 0,
  DateTime? lastSynced,
}) => [
  isOnlineProvider.overrideWith(
    (_) => online == null ? const Stream<bool>.empty() : Stream.value(online),
  ),
  reachabilityMonitorProvider.overrideWith(() => _FixedMonitor(reachable)),
  cacheNamespaceProvider.overrideWithValue(namespace),
  // Like the real provider: one long-lived stream that emits new totals,
  // never a provider that rebuilds on every change.
  syncQueueTotalsProvider.overrideWith((ref) {
    final controller = StreamController<SyncQueueTotals>();
    ref.onDispose(controller.close);
    ref.listen(_totals, (_, next) => controller.add(next), fireImmediately: true);
    return controller.stream;
  }),
  needsAttentionCountProvider.overrideWithValue(shared),
  lastSyncedAtProvider.overrideWith((_) async => lastSynced),
];

Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<Override> overrides,
) async {
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: Consumer(
        builder: (context, ref, _) {
          ref.watch(syncStatusSummaryProvider);
          return const SizedBox();
        },
      ),
    ),
  );
  await _tick(tester);
  return ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
}

/// A stream emission and the widget rebuild it causes each need a frame, and
/// timers started during a frame must exist before the clock is advanced.
Future<void> _tick(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

SyncStatusSummary _read(ProviderContainer c) =>
    c.read(syncStatusSummaryProvider);

void main() {
  testWidgets('healthy and nothing queued: hidden', (tester) async {
    final c = await _pump(tester, _overrides());
    expect(_read(c).mode, SyncStatusMode.hidden);
    expect(_read(c).visible, isFalse);
  });

  testWidgets('no network: offline, with the waiting count', (tester) async {
    final c = await _pump(tester, _overrides(online: false));
    c.read(_totals.notifier).state = const SyncQueueTotals(pending: 3);
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).mode, SyncStatusMode.offline);
    expect(_read(c).pendingCount, 3);
  });

  testWidgets('offline outranks unreachable, syncing and attention', (
    tester,
  ) async {
    final c = await _pump(
      tester,
      _overrides(online: false, reachable: false, shared: 4),
    );
    c.read(_totals.notifier).state = const SyncQueueTotals(
      pending: 2,
      attention: 1,
    );
    await _tick(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(_read(c).mode, SyncStatusMode.offline);
  });

  testWidgets('radio up but PandaPay unreachable', (tester) async {
    final c = await _pump(tester, _overrides(reachable: false));
    c.read(_totals.notifier).state = const SyncQueueTotals(pending: 1);
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).mode, SyncStatusMode.unreachable);
    expect(_read(c).pendingCount, 1);
  });

  testWidgets('unknown connectivity and unknown reachability act as online', (
    tester,
  ) async {
    final c = await _pump(tester, _overrides(online: null, reachable: null));
    expect(_read(c).mode, SyncStatusMode.hidden);
  });

  testWidgets('syncing shows only after the queue persisted for 2 seconds', (
    tester,
  ) async {
    final c = await _pump(tester, _overrides());
    c.read(_totals.notifier).state = const SyncQueueTotals(pending: 2);
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).mode, SyncStatusMode.hidden);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(_read(c).mode, SyncStatusMode.hidden);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_read(c).mode, SyncStatusMode.syncing);
    expect(_read(c).pendingCount, 2);
    // A shrinking queue keeps the state; an empty one hides it at once.
    c.read(_totals.notifier).state = const SyncQueueTotals(pending: 1);
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).mode, SyncStatusMode.syncing);
    expect(_read(c).pendingCount, 1);
    c.read(_totals.notifier).state = SyncQueueTotals.zero;
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).mode, SyncStatusMode.hidden);
  });

  testWidgets('a queue that drains inside 2 seconds never flashes', (
    tester,
  ) async {
    final c = await _pump(tester, _overrides());
    c.read(_totals.notifier).state = const SyncQueueTotals(pending: 2);
    await _tick(tester);
    await tester.pump(const Duration(milliseconds: 1500));
    c.read(_totals.notifier).state = SyncQueueTotals.zero;
    await _tick(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(_read(c).mode, SyncStatusMode.hidden);
    // A new burst starts its own 2 second wait.
    c.read(_totals.notifier).state = const SyncQueueTotals(pending: 1);
    await _tick(tester);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(_read(c).mode, SyncStatusMode.hidden);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_read(c).mode, SyncStatusMode.syncing);
  });

  testWidgets('parked rows plus shared attention need attention', (
    tester,
  ) async {
    final c = await _pump(tester, _overrides(shared: 2));
    c.read(_totals.notifier).state = const SyncQueueTotals(attention: 1);
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).mode, SyncStatusMode.needsAttention);
    expect(_read(c).attentionCount, 3);
  });

  testWidgets('syncing outranks needs attention', (tester) async {
    final c = await _pump(tester, _overrides(shared: 2));
    c.read(_totals.notifier).state = const SyncQueueTotals(
      pending: 4,
      attention: 1,
    );
    await _tick(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(_read(c).mode, SyncStatusMode.syncing);
    expect(_read(c).attentionCount, 3);
  });

  testWidgets('signed out: offline and unreachable only, no counts', (
    tester,
  ) async {
    const queued = SyncQueueTotals(pending: 5, attention: 2);
    var c = await _pump(
      tester,
      _overrides(online: false, namespace: 'signed-out', shared: 3),
    );
    c.read(_totals.notifier).state = queued;
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).mode, SyncStatusMode.offline);
    expect(_read(c).pendingCount, 0);
    expect(_read(c).attentionCount, 0);

    c = await _pump(
      tester,
      _overrides(reachable: false, namespace: 'signed-out'),
    );
    c.read(_totals.notifier).state = queued;
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).mode, SyncStatusMode.unreachable);
    expect(_read(c).pendingCount, 0);

    // Online and reachable: the queue and shared counts are never shown.
    c = await _pump(tester, _overrides(namespace: 'signed-out', shared: 3));
    c.read(_totals.notifier).state = queued;
    await _tick(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(_read(c).mode, SyncStatusMode.hidden);
  });

  testWidgets('last synced is read only while the strip is showing', (
    tester,
  ) async {
    final at = DateTime(2026, 11, 14, 18, 40);
    var c = await _pump(tester, _overrides(online: false, lastSynced: at));
    await _tick(tester);
    await _tick(tester);
    expect(_read(c).lastSyncedAt, at);

    c = await _pump(tester, _overrides(lastSynced: at));
    await _tick(tester);
    expect(_read(c).lastSyncedAt, isNull);
  });

  test('summaries compare by value', () {
    expect(
      const SyncStatusSummary(mode: SyncStatusMode.offline, pendingCount: 1),
      const SyncStatusSummary(mode: SyncStatusMode.offline, pendingCount: 1),
    );
    expect(
      const SyncStatusSummary(mode: SyncStatusMode.offline, pendingCount: 1),
      isNot(
        const SyncStatusSummary(mode: SyncStatusMode.offline, pendingCount: 2),
      ),
    );
  });
}
