import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/sync_api.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sync/sync_engine.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

class _Api implements SyncApi {
  final bool changes;
  final void Function()? onAck;
  int acknowledgments = 0;
  _Api({this.changes = true, this.onAck});
  @override
  Future<List<SyncPushResult>> push({
    required String deviceId,
    required List<SyncChange> changes,
  }) async => [
    for (final change in changes)
      SyncPushResult(clientSeq: change.clientSeq, applied: true, conflicts: 0),
  ];
  @override
  Future<SyncPullBatch> pull({
    required String deviceId,
    required int since,
    int limit = 500,
  }) async => SyncPullBatch(
    changes: changes
        ? [
            {'entity': 'transactions', 'entity_id': 'id', 'op': 'update'},
          ]
        : [],
    conflicts: [],
    hasMore: false,
    latestServerSeq: 42,
  );
  @override
  Future<void> ack({required String deviceId, required int serverSeq}) async {
    onAck?.call();
    acknowledgments++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repository implements UserCardsRepository {
  final bool fail;
  _Repository({this.fail = false});
  @override
  Future<List<TransactionEntry>> fetchTransactions({
    DateTime? from,
    DateTime? to,
    String? cardId,
    String? categoryId,
    String? source,
    String? query,
  }) async {
    if (fail) throw StateError('network unavailable');
    return [
      TransactionEntry(
        id: 'id',
        amount: Money.fromRupees(50),
        occurredAt: DateTime(2026, 10, 18),
        note: 'server accepted',
        source: 'manual',
        status: 'active',
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  ProviderContainer container(_Api api, {bool fail = false}) =>
      ProviderContainer(
        overrides: [
          cacheNamespaceProvider.overrideWithValue('user:a'),
          appDatabaseProvider.overrideWith((ref) async => db),
          isOnlineProvider.overrideWith((ref) => Stream.value(false)),
          responseCacheProvider.overrideWith((ref) async => cache),
          syncQueueProvider.overrideWith((ref) async => queue),
          syncApiProvider.overrideWithValue(api),
          userCardsRepositoryProvider.overrideWithValue(
            _Repository(fail: fail),
          ),
        ],
      );
  test('pull acknowledgment follows a durable entity commit', () async {
    final api = _Api(
      onAck: () => expect(
        cache.financialStore
            .transactions('user:a', const TransactionQuery())!
            .rows
            .single
            .id,
        'id',
      ),
    );
    final scope = container(api);
    addTearDown(scope.dispose);
    final result = await scope.read(syncEngineProvider).sync();
    expect(result.ranToCompletion, isTrue);
    expect(queue.lastServerSeq, 42);
    expect(api.acknowledgments, 1);
  });
  test(
    'failed materialization neither advances nor acknowledges the cursor',
    () async {
      final api = _Api();
      final scope = container(api, fail: true);
      addTearDown(scope.dispose);
      final result = await scope.read(syncEngineProvider).sync();
      expect(result.ranToCompletion, isFalse);
      expect(queue.lastServerSeq, 0);
      expect(api.acknowledgments, 0);
    },
  );
  test(
    'successful push persists the accepted row before removing its pending overlay',
    () async {
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'id',
        fields: {'note': 'edited offline'},
      );
      final scope = container(_Api(changes: false));
      addTearDown(scope.dispose);
      await scope.read(syncEngineProvider).sync();
      expect(queue.pendingCount, 0);
      expect(
        cache.financialStore
            .transactions('user:a', const TransactionQuery())!
            .rows
            .single
            .note,
        'server accepted',
      );
    },
  );
}
