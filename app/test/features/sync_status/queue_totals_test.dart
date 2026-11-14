import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/queue_registry.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:pandapay/features/sync_status/queue_totals.dart';

const _a = 'user:11111111-1111-4111-8111-111111111111';
const _b = 'user:22222222-2222-4222-8222-222222222222';

void main() {
  late AppDatabase db;
  late QueueRegistry registry;
  var targets = 0;
  setUp(() {
    targets = 0;
    db = openInMemoryForTesting();
    registry = QueueRegistry(db);
  });
  tearDown(() => db.close());

  void enqueueCommands(String namespace, int count) {
    final commands = CommandOutbox(db, namespace: namespace);
    for (var i = 0; i < count; i += 1) {
      commands.enqueue(
        kind: 'ignore_transaction',
        target: 'tx-$namespace-${targets++}',
      );
    }
  }

  group('computeSyncQueueTotals', () {
    test('an empty phone counts nothing', () {
      expect(computeSyncQueueTotals(registry, _a), SyncQueueTotals.zero);
    });

    test('counts waiting rows as pending and parked rows as attention', () {
      enqueueCommands(_a, 3);
      db.db.execute(
        'UPDATE command_outbox SET parked = 1 WHERE namespace = ? AND id = '
        '(SELECT MIN(id) FROM command_outbox WHERE namespace = ?)',
        [_a, _a],
      );
      expect(
        computeSyncQueueTotals(registry, _a),
        const SyncQueueTotals(pending: 2, attention: 1),
      );
    });

    test('only the current account is counted', () {
      enqueueCommands(_a, 2);
      enqueueCommands(_b, 5);
      expect(computeSyncQueueTotals(registry, _a).pending, 2);
      expect(computeSyncQueueTotals(registry, _b).pending, 5);
    });

    test('background SMS queues are not "changes waiting to sync"', () {
      SmsV2Schema.ensure(db.db);
      db.db.execute(
        'INSERT INTO v2_outbox (namespace, id, kind, payload) '
        "VALUES (?, 'f1', 'fact', '{}')",
        [_a],
      );
      expect(registry.countsFor('v2_outbox', _a).pending, 1);
      expect(computeSyncQueueTotals(registry, _a), SyncQueueTotals.zero);
    });

    test('shared queues count as pending but never double up attention', () {
      // The Split queue's refused rows are already counted by
      // needsAttentionCountProvider; counting them here too would show 2x.
      var n = 0;
      for (final state in const [
        'pending',
        'pending',
        'rejected',
        'awaitingAuth',
      ]) {
        n += 1;
        db.db.execute(
          'INSERT INTO shared_commands '
          '(namespace, operation_id, context_id, kind, request_json, '
          'request_hash, state, created_at) '
          "VALUES (?, ?, 'c', 'k', '{}', 'h', ?, 1)",
          [_a, 'op-$n', state],
        );
      }
      final scoped = registry;
      expect(
        computeSyncQueueTotals(scoped, _a),
        const SyncQueueTotals(pending: 2, attention: 0),
      );
    });
  });

  group('buildSyncQueueLines', () {
    test('lists only queues that hold something, in plain words', () {
      enqueueCommands(_a, 2);
      db.db.execute(
        'UPDATE command_outbox SET parked = 1 WHERE namespace = ? AND id = '
        '(SELECT MAX(id) FROM command_outbox WHERE namespace = ?)',
        [_a, _a],
      );
      final lines = buildSyncQueueLines(registry, _a);
      expect(lines, hasLength(1));
      final line = lines.single;
      expect(line.queue, 'command_outbox');
      expect(line.label, 'Other changes');
      expect(line.counts, const QueueCounts(pending: 1, parked: 1));
      expect(line.description, '1 waiting to send, 1 not accepted');
    });

    test('has a label for every queue the registry knows', () {
      for (final spec in QueueRegistry.defaultQueues.where(
        (spec) => spec.kind == QueueKind.outbox,
      )) {
        expect(
          syncQueueLabels.containsKey(spec.name),
          isTrue,
          reason: '${spec.name} needs a plain-language label',
        );
      }
    });

    test('descriptions read naturally for each combination', () {
      expect(
        SyncQueueLine('q', 'Tags', const QueueCounts(pending: 3)).description,
        '3 waiting to send',
      );
      expect(
        SyncQueueLine('q', 'Tags', const QueueCounts(parked: 2)).description,
        '2 not accepted',
      );
      expect(
        SyncQueueLine('q', 'Tags', const QueueCounts(blocked: 1)).description,
        '1 waiting for sign-in',
      );
    });
  });

  group('syncQueueTotalsProvider', () {
    Future<List<SyncQueueTotals>> run(
      WidgetTester tester, {
      required String namespace,
      required Future<void> Function(ProviderContainer, List<SyncQueueTotals>)
      body,
    }) async {
      final seen = <SyncQueueTotals>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cacheNamespaceProvider.overrideWithValue(namespace),
            queueRegistryProvider.overrideWith((_) async => registry),
            isOnlineProvider.overrideWith((_) => Stream.value(true)),
            financialStoreRevisionProvider.overrideWith(
              (ref, entity) => const Stream<int>.empty(),
            ),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              ref.listen<AsyncValue<SyncQueueTotals>>(
                syncQueueTotalsProvider,
                (_, next) {
                  final value = next.valueOrNull;
                  if (value != null) seen.add(value);
                },
              );
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      await body(
        ProviderScope.containerOf(tester.element(find.byType(SizedBox))),
        seen,
      );
      await tester.pumpWidget(const SizedBox());
      return seen;
    }

    testWidgets('counts shortly after start, then on a queue-change event', (
      tester,
    ) async {
      enqueueCommands(_a, 2);
      await run(
        tester,
        namespace: _a,
        body: (container, seen) async {
          expect(seen, isEmpty, reason: 'nothing is counted during launch');
          await tester.pump(const Duration(milliseconds: 1600));
          expect(seen.last, const SyncQueueTotals(pending: 2));

          enqueueCommands(_a, 3);
          // The command outbox announces its changes: recount within ~300 ms
          // instead of waiting for the slow timer.
          container.read(commandOutboxRevisionProvider.notifier).state++;
          await tester.pump(const Duration(milliseconds: 400));
          expect(seen.last.pending, 5);
        },
      );
    });

    testWidgets('keeps polling slowly as a safety net, and only emits changes', (
      tester,
    ) async {
      enqueueCommands(_a, 1);
      await run(
        tester,
        namespace: _a,
        body: (container, seen) async {
          await tester.pump(const Duration(milliseconds: 1600));
          final first = seen.length;
          // No change: the timer runs but nothing is emitted.
          await tester.pump(const Duration(seconds: 4));
          expect(seen.length, first);
          db.db.execute('DELETE FROM command_outbox');
          await tester.pump(const Duration(seconds: 4));
          expect(seen.last, SyncQueueTotals.zero);
        },
      );
    });

    testWidgets('signed out: zero, and the database is never read', (
      tester,
    ) async {
      enqueueCommands(_a, 4);
      await run(
        tester,
        namespace: 'signed-out',
        body: (container, seen) async {
          await tester.pump(const Duration(seconds: 12));
          expect(seen, [SyncQueueTotals.zero]);
        },
      );
    });
  });
}
