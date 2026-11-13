import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/split_repository.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/sync_api.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sync/split_sync.dart';
import 'package:pandapay/features/sync/sync_engine.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// A sync API whose push/pull/register behaviour a test scripts.
class _ScriptedApi implements SyncApi {
  _ScriptedApi({this.onPush, this.onPull, this.onRegister});

  /// Returns the results for one push request, or throws. Defaults to
  /// accepting everything.
  final FutureOr<List<SyncPushResult>> Function(
    String deviceId,
    List<SyncChange> changes,
  )?
  onPush;
  final FutureOr<SyncPullBatch> Function(String deviceId, int since)? onPull;
  final FutureOr<String> Function(String? deviceId)? onRegister;

  final List<List<SyncChange>> pushes = [];
  final List<int> pushBytes = [];
  final List<String> pushDevices = [];
  final List<String?> registrations = [];
  final List<String> pullDevices = [];
  int acknowledgments = 0;

  @override
  Future<List<SyncPushResult>> push({
    required String deviceId,
    required List<SyncChange> changes,
  }) async {
    pushes.add(changes);
    pushDevices.add(deviceId);
    pushBytes.add(
      utf8
          .encode(
            jsonEncode({
              'deviceId': deviceId,
              'changes': changes.map((c) => c.toJson()).toList(),
            }),
          )
          .length,
    );
    final handler = onPush;
    if (handler != null) return await handler(deviceId, changes);
    return [for (final change in changes) _applied(change)];
  }

  @override
  Future<SyncPullBatch> pull({
    required String deviceId,
    required int since,
    int limit = 500,
  }) async {
    pullDevices.add(deviceId);
    final handler = onPull;
    if (handler != null) return await handler(deviceId, since);
    return _emptyBatch;
  }

  @override
  Future<String> registerDevice({
    required String platform,
    String? label,
    String? appVersion,
    String? deviceId,
  }) async {
    registrations.add(deviceId);
    final handler = onRegister;
    if (handler != null) return await handler(deviceId);
    return deviceId ?? 'registered-device';
  }

  @override
  Future<void> ack({required String deviceId, required int serverSeq}) async {
    acknowledgments++;
  }

  @override
  Future<List<Map<String, dynamic>>?> fetchSelfTransferRules() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _emptyBatch = SyncPullBatch(
  changes: [],
  conflicts: [],
  hasMore: false,
  latestServerSeq: 0,
);

SyncPushResult _applied(SyncChange change) =>
    SyncPushResult(clientSeq: change.clientSeq, applied: true, conflicts: 0);

SyncPushResult _failed(SyncChange change, String reason) => SyncPushResult(
  clientSeq: change.clientSeq,
  applied: false,
  conflicts: 0,
  reason: reason,
);

/// A split repository whose sync never finishes, like a hung server.
class _HangingSplitRepository implements SplitRepository {
  final List<String> events;
  _HangingSplitRepository(this.events);
  @override
  Future<void> sync({bool reconnect = false}) {
    events.add('split-sync');
    return Completer<void>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repository implements UserCardsRepository {
  bool fail;
  int fullFetches = 0;
  _Repository({this.fail = false});

  @override
  Future<TransactionEntry> fetchTransaction(String id) async {
    if (fail) throw StateError('network unavailable');
    return _server(id);
  }

  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? userCategoryId,
    String? source,
    String? query,
  }) async {
    fullFetches++;
    if (fail) throw StateError('network unavailable');
    return [_server('t1')];
  }

  TransactionEntry _server(String id) => TransactionEntry(
    id: id,
    amount: Money.fromRupees(50),
    occurredAt: DateTime(2026, 10, 18),
    note: 'server accepted',
    source: 'manual',
    status: 'active',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ApiException _http(int status, [String body = '{}']) =>
    ApiException('POST /sync/push failed: $status $body');

void main() {
  late AppDatabase db;
  late ResponseCache cache;
  late SyncQueue queue;

  setUp(() {
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
    queue = SyncQueue(db, namespace: 'user:a');
    queue.deviceId = 'device';
  });
  tearDown(() {
    cache.financialStore.dispose();
    db.close();
  });

  ProviderContainer scripted(
    _ScriptedApi api, {
    _Repository? repository,
    List<Override> extra = const [],
  }) => ProviderContainer(
    overrides: [
      cacheNamespaceProvider.overrideWithValue('user:a'),
      appDatabaseProvider.overrideWith((ref) async => db),
      isOnlineProvider.overrideWith((ref) => Stream.value(false)),
      responseCacheProvider.overrideWith((ref) async => cache),
      syncQueueProvider.overrideWith((ref) async => queue),
      syncApiProvider.overrideWithValue(api),
      transactionsProvider.overrideWith((ref) async => []),
      utilizationTransactionsProvider.overrideWith((ref) async => []),
      userCardsRepositoryProvider.overrideWithValue(repository ?? _Repository()),
      ...extra,
    ],
  );

  void enqueue(String id, {String note = 'edit'}) => queue.enqueueUpdate(
    entity: 'transactions',
    entityId: id,
    fields: {'note': note},
  );

  String big() => List.filled(16 * 1024, 'x').join();

  group('push chunking (SRV-06 client half)', () {
    test('200 changes of 16 KiB are sent in chunks under 60 KiB, none lost',
        () async {
      for (var i = 0; i < 200; i++) {
        enqueue('t$i', note: big());
      }
      final api = _ScriptedApi();
      final scope = scripted(api);
      addTearDown(scope.dispose);

      var syncs = 0;
      while (queue.pendingCount > 0 && syncs < 100) {
        await scope.read(syncEngineProvider).sync();
        syncs++;
      }
      expect(queue.pendingCount, 0);
      expect(api.pushes.expand((c) => c), hasLength(200));
      for (final bytes in api.pushBytes) {
        expect(bytes, lessThanOrEqualTo(62 * 1024), reason: 'request size');
      }
      expect(api.pushes.every((c) => c.length <= 200), isTrue);
      expect(api.pushes.length, greaterThan(5));
      // Ordering by client_seq is preserved across chunks.
      final seqs = api.pushes.expand((c) => c).map((c) => c.clientSeq).toList();
      expect(seqs, [...seqs]..sort());
    });

    test('one sync sends at most five requests', () async {
      for (var i = 0; i < 100; i++) {
        enqueue('t$i', note: big());
      }
      final api = _ScriptedApi();
      final scope = scripted(api);
      addTearDown(scope.dispose);
      await scope.read(syncEngineProvider).sync();
      expect(api.pushes, hasLength(5));
      expect(queue.pendingCount, lessThan(100));
      expect(queue.pendingCount, greaterThan(0));
    });

    test('small changes still go in one request of up to 200', () async {
      for (var i = 0; i < 150; i++) {
        enqueue('t$i');
      }
      final api = _ScriptedApi();
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(api.pushes, hasLength(1));
      expect(result.pushed, 150);
    });

    test('an oversize change (413) is rejected alone, the rest go through',
        () async {
      enqueue('ok-1');
      enqueue('huge', note: 'HUGE');
      enqueue('ok-2');
      final api = _ScriptedApi(
        onPush: (device, changes) {
          if (changes.any((c) => c.payload['note'] == 'HUGE')) {
            throw _http(413, '{"error":"payload too large"}');
          }
          return [for (final c in changes) _applied(c)];
        },
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.pushed, 2);
      // The bad one stays saved but leaves the automatic retry set.
      expect(queue.pendingCount, 1);
      expect(queue.pending(), isEmpty);
    });

    test('a 400 for a chunk does not mark every item failed', () async {
      for (var i = 0; i < 6; i++) {
        enqueue('t$i', note: i == 3 ? 'BAD' : 'fine');
      }
      final api = _ScriptedApi(
        onPush: (device, changes) {
          if (changes.any((c) => c.payload['note'] == 'BAD')) {
            throw _http(400, '{"error":"invalid"}');
          }
          return [for (final c in changes) _applied(c)];
        },
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.pushed, 5);
      expect(queue.pendingCount, 1);
      expect(queue.pending(), isEmpty);
    });

    test('a 500 caused by one poison change is isolated and counted once',
        () async {
      for (var i = 0; i < 4; i++) {
        enqueue('t$i', note: i == 1 ? 'POISON' : 'fine');
      }
      final api = _ScriptedApi(
        onPush: (device, changes) {
          if (changes.any((c) => c.payload['note'] == 'POISON')) {
            throw _http(500, '{"error":"internal_error"}');
          }
          return [for (final c in changes) _applied(c)];
        },
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.pushed, 3);
      final left = db.db.select('SELECT attempts FROM sync_pending_changes');
      expect(left.single['attempts'], 1);
    });

    test('a network error aborts the sync and counts nothing', () async {
      for (var i = 0; i < 3; i++) {
        enqueue('t$i');
      }
      final api = _ScriptedApi(
        onPush: (device, changes) => throw const SocketException('offline'),
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isFalse);
      expect(api.pushes, hasLength(1));
      final rows = db.db.select(
        'SELECT attempts, in_flight FROM sync_pending_changes',
      );
      expect(rows.map((r) => r['attempts']), [0, 0, 0]);
      expect(rows.map((r) => r['in_flight']), [0, 0, 0]);
    });

    test('401, 429 and 503 abort without recording failures', () async {
      for (final status in [401, 429, 503]) {
        db.db.execute('DELETE FROM sync_pending_changes');
        enqueue('t$status');
        final api = _ScriptedApi(onPush: (device, changes) => throw _http(status));
        final scope = scripted(api);
        addTearDown(scope.dispose);
        final result = await scope.read(syncEngineProvider).sync();
        expect(result.ranToCompletion, isFalse, reason: '$status');
        expect(
          db.db
              .select('SELECT attempts FROM sync_pending_changes')
              .single['attempts'],
          0,
          reason: '$status',
        );
      }
    });
  });

  group('ack before materialize (Q-06)', () {
    test('acked rows leave the queue even when materialize then throws',
        () async {
      enqueue('t1');
      final repository = _Repository(fail: true);
      final api = _ScriptedApi();
      final scope = scripted(api, repository: repository);
      addTearDown(scope.dispose);

      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isFalse);
      expect(queue.pendingCount, 0, reason: 'applied rows must not stay queued');
      expect(api.pushes.expand((c) => c), hasLength(1));

      // The next sync does not re-push them, and still reconciles the
      // entities whose materialize failed.
      repository.fail = false;
      final second = await scope.read(syncEngineProvider).sync();
      expect(second.ranToCompletion, isTrue);
      expect(api.pushes.expand((c) => c), hasLength(1));
      expect(repository.fullFetches, greaterThanOrEqualTo(1));
      expect(
        cache.financialStore
            .transactions('user:a', const TransactionQuery())!
            .rows
            .single
            .note,
        'server accepted',
      );
    });
  });

  group('split sync (Q-07)', () {
    test('a hung split sync cannot block the edit push', () async {
      enqueue('t1');
      final events = <String>[];
      final api = _ScriptedApi(
        onPush: (device, changes) {
          events.add('push');
          return [for (final c in changes) _applied(c)];
        },
      );
      final scope = scripted(
        api,
        extra: [
          splitRepositoryProvider.overrideWith(
            (ref) async => _HangingSplitRepository(events),
          ),
        ],
      );
      addTearDown(scope.dispose);
      final result = await scope
          .read(syncEngineProvider)
          .sync()
          .timeout(const Duration(seconds: 5));
      expect(result.ranToCompletion, isTrue);
      expect(result.pushed, 1);
      // The edit push comes first; the split sync is started after it.
      expect(events.first, 'push');
    });

    test('a throwing split sync cannot abort the edit push', () async {
      enqueue('t1');
      final api = _ScriptedApi();
      final scope = scripted(
        api,
        extra: [
          splitRepositoryProvider.overrideWith(
            (ref) async => throw StateError('split unavailable'),
          ),
        ],
      );
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isTrue);
      expect(result.pushed, 1);
    });

    test('split sync still starts when the edit push fails', () async {
      enqueue('t1');
      final events = <String>[];
      final api = _ScriptedApi(
        onPush: (device, changes) => throw _http(503),
      );
      final scope = scripted(
        api,
        extra: [
          splitRepositoryProvider.overrideWith(
            (ref) async => _HangingSplitRepository(events),
          ),
        ],
      );
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['split-sync']);
    });
  });

  group('device registration (SRV-05 client half)', () {
    test('409 device_not_registered re-registers and retries the push once',
        () async {
      enqueue('t1');
      var first = true;
      final api = _ScriptedApi(
        onPush: (device, changes) {
          if (first) {
            first = false;
            throw _http(409, '{"error":"device_not_registered"}');
          }
          return [for (final c in changes) _applied(c)];
        },
        onRegister: (_) => 'device-2',
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isTrue);
      expect(result.pushed, 1);
      expect(api.registrations, ['device']);
      expect(queue.deviceId, 'device-2');
      expect(api.pushDevices, ['device', 'device-2']);
      expect(queue.pendingCount, 0);
    });

    test('an old server answering not_found for every item re-registers first',
        () async {
      enqueue('t1');
      enqueue('t2');
      final api = _ScriptedApi(
        onPush: (device, changes) => [
          for (final c in changes)
            device == 'device' ? _failed(c, 'not_found') : _applied(c),
        ],
        onRegister: (_) => 'device-2',
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.pushed, 2);
      expect(api.registrations, hasLength(1));
      expect(queue.pendingCount, 0, reason: 'nothing was rejected');
    });

    test('genuinely rejected items are rejected after one re-registration',
        () async {
      enqueue('t1');
      final api = _ScriptedApi(
        onPush: (device, changes) => [
          for (final c in changes) _failed(c, 'rejected'),
        ],
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      await scope.read(syncEngineProvider).sync();
      expect(api.registrations, hasLength(1));
      expect(api.pushes, hasLength(2));
      expect(queue.pendingCount, 1);
      expect(queue.pending(), isEmpty, reason: 'rejected leaves auto-retry');
    });

    test('a mixed result is not mistaken for an unregistered device', () async {
      enqueue('t1');
      enqueue('t2');
      final api = _ScriptedApi(
        onPush: (device, changes) => [
          _failed(changes[0], 'not_found'),
          _applied(changes[1]),
        ],
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      await scope.read(syncEngineProvider).sync();
      expect(api.registrations, isEmpty);
    });

    test('409 device_not_registered on pull re-registers and retries', () async {
      var first = true;
      final api = _ScriptedApi(
        onPull: (device, since) {
          if (first) {
            first = false;
            throw ApiException(
              'GET /sync/pull failed: 409 {"error":"device_not_registered"}',
            );
          }
          return _emptyBatch;
        },
        onRegister: (_) => 'device-2',
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isTrue);
      expect(api.pullDevices, ['device', 'device-2']);
      expect(api.registrations, hasLength(1));
    });

    test('re-registers at most once per sync', () async {
      enqueue('t1');
      final api = _ScriptedApi(
        onPush: (device, changes) =>
            throw _http(409, '{"error":"device_not_registered"}'),
        onRegister: (_) => 'device-2',
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isFalse);
      expect(api.registrations, hasLength(1));
      expect(api.pushes, hasLength(2));
      expect(queue.pending(), hasLength(1), reason: 'nothing was rejected');
    });
  });

  group('pull cursor guard (Q-10)', () {
    const stale = SyncPullBatch(
      changes: [
        {'entity': 'transactions', 'entity_id': 'id', 'op': 'update'},
      ],
      conflicts: [],
      hasMore: false,
      latestServerSeq: 5,
    );

    test('a server behind the local cursor resets it instead of throwing',
        () async {
      queue.lastServerSeq = 500;
      final api = _ScriptedApi(onPull: (device, since) => stale);
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isTrue);
      expect(queue.lastServerSeq, 0, reason: 'full resync from the start');
      expect(api.acknowledgments, 0);
    });

    test('a stuck server at cursor 0 still fails loudly (no resync loop)',
        () async {
      queue.lastServerSeq = 0;
      final api = _ScriptedApi(
        onPull: (device, since) => const SyncPullBatch(
          changes: [
            {'entity': 'transactions', 'entity_id': 'id', 'op': 'update'},
          ],
          conflicts: [],
          hasMore: false,
          latestServerSeq: 0,
        ),
      );
      final scope = scripted(api);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isFalse);
      expect(api.pullDevices, hasLength(1));
    });
  });
}
