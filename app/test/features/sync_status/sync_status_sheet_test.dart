import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/queue_registry.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_attention.dart';
import 'package:pandapay/features/sync_status/queue_totals.dart';
import 'package:pandapay/features/sync_status/sync_retry.dart';
import 'package:pandapay/features/sync_status/sync_status_providers.dart';
import 'package:pandapay/features/sync_status/sync_status_sheet.dart';

/// A queue as the retry action sees it: records each retryParked call.
class _FakeQueue {
  int retried = 0;
  Future<void> retryParked() async => retried += 1;
}

Future<void> _open(
  WidgetTester tester, {
  SyncStatusSummary summary = const SyncStatusSummary(
    mode: SyncStatusMode.needsAttention,
    attentionCount: 1,
  ),
  List<SyncQueueLine> lines = const [],
  Map<String, ParkedRetry> retry = const {},
  DateTime? lastSynced,
  int shared = 0,
  void Function()? onNudge,
  Size size = const Size(400, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncStatusSummaryProvider.overrideWithValue(summary),
        syncQueueBreakdownProvider.overrideWith((_) async => lines),
        syncRetryActionsProvider.overrideWithValue(retry),
        syncNudgeProvider.overrideWithValue(onNudge ?? () {}),
        lastSyncedAtProvider.overrideWith((_) async => lastSynced),
        needsAttentionCountProvider.overrideWithValue(shared),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: SyncStatusSheet()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => BambooFonts.useSystemFontsForTests = true);
  tearDown(() => BambooFonts.useSystemFontsForTests = false);

  testWidgets('shows the title and the connection state', (tester) async {
    await _open(tester, summary: const SyncStatusSummary(mode: SyncStatusMode.offline));
    expect(find.text('Sync status'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.textContaining('saved on this phone'), findsOneWidget);
  });

  testWidgets('says when PandaPay cannot be reached although the network is up', (
    tester,
  ) async {
    await _open(
      tester,
      summary: const SyncStatusSummary(mode: SyncStatusMode.unreachable),
    );
    expect(find.text("Can't reach PandaPay"), findsOneWidget);
  });

  testWidgets('connected when the strip would be hidden', (tester) async {
    await _open(
      tester,
      summary: const SyncStatusSummary(mode: SyncStatusMode.hidden),
    );
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Everything is up to date.'), findsOneWidget);
  });

  testWidgets('last synced time, or a plain "not yet"', (tester) async {
    final now = DateTime.now();
    await _open(tester, lastSynced: DateTime(now.year, now.month, now.day, 18, 40));
    expect(find.text('Last synced today, 6:40 PM'), findsOneWidget);
  });

  testWidgets('no sync yet', (tester) async {
    await _open(tester);
    expect(find.text('Last synced: not yet'), findsOneWidget);
  });

  testWidgets('older sync shows the date', (tester) async {
    await _open(tester, lastSynced: DateTime(2020, 3, 9, 7, 5));
    expect(find.text('Last synced 9 Mar 2020, 7:05 AM'), findsOneWidget);
  });

  testWidgets('per queue counts in plain words', (tester) async {
    await _open(
      tester,
      lines: [
        SyncQueueLine(
          'transaction_outbox_entries',
          'New transactions',
          const QueueCounts(pending: 2),
        ),
        SyncQueueLine(
          'command_outbox',
          'Other changes',
          const QueueCounts(pending: 1, parked: 1),
        ),
      ],
    );
    expect(find.text('New transactions'), findsOneWidget);
    expect(find.text('2 waiting to send'), findsOneWidget);
    expect(find.text('Other changes'), findsOneWidget);
    expect(find.text('1 waiting to send, 1 not accepted'), findsOneWidget);
  });

  testWidgets('Retry on a parked queue calls its retryParked and then nudges', (
    tester,
  ) async {
    final queue = _FakeQueue();
    var nudges = 0;
    await _open(
      tester,
      lines: [
        SyncQueueLine(
          'command_outbox',
          'Other changes',
          const QueueCounts(parked: 2),
        ),
      ],
      retry: {'command_outbox': queue.retryParked},
      onNudge: () => nudges += 1,
    );
    await tester.tap(find.byKey(const Key('sync-retry-command_outbox')));
    await tester.pumpAndSettle();
    expect(queue.retried, 1);
    expect(nudges, 1);
  });

  testWidgets('a queue with nothing parked has no Retry button', (tester) async {
    final queue = _FakeQueue();
    await _open(
      tester,
      lines: [
        SyncQueueLine(
          'command_outbox',
          'Other changes',
          const QueueCounts(pending: 2),
        ),
      ],
      retry: {'command_outbox': queue.retryParked},
    );
    expect(find.byKey(const Key('sync-retry-command_outbox')), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a parked queue that cannot be retried offers no button', (
    tester,
  ) async {
    await _open(
      tester,
      lines: [
        SyncQueueLine(
          'duplicate_resolution_outbox',
          'Duplicate reviews',
          const QueueCounts(parked: 1),
        ),
      ],
    );
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Duplicate reviews'), findsOneWidget);
  });

  testWidgets('a failing retry does not crash the sheet', (tester) async {
    await _open(
      tester,
      lines: [
        SyncQueueLine(
          'command_outbox',
          'Other changes',
          const QueueCounts(parked: 1),
        ),
      ],
      retry: {'command_outbox': () async => throw StateError('boom')},
    );
    await tester.tap(find.byKey(const Key('sync-retry-command_outbox')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Sync status'), findsOneWidget);
  });

  testWidgets('Split changes that need attention link to the existing sheet', (
    tester,
  ) async {
    await _open(tester, shared: 2);
    expect(find.byKey(const Key('sync-review-split')), findsOneWidget);
    expect(find.text('Split changes need attention'), findsOneWidget);
  });

  testWidgets('no Split link when nothing needs attention', (tester) async {
    await _open(tester);
    expect(find.byKey(const Key('sync-review-split')), findsNothing);
  });

  testWidgets('scales with a large text size without overflowing', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _open(
      tester,
      size: const Size(360, 640),
      shared: 2,
      lines: [
        SyncQueueLine(
          'command_outbox',
          'Other changes',
          const QueueCounts(pending: 12, parked: 3),
        ),
      ],
      retry: {'command_outbox': () async {}},
    );
    expect(tester.takeException(), isNull);
  });
}
