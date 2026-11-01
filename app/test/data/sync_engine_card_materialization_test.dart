import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/sync_api.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sync/sync_engine.dart';

class _CardApi implements SyncApi {
  int acknowledgments = 0;

  @override
  Future<SyncPullBatch> pull({
    required String deviceId,
    required int since,
    int limit = 500,
  }) async => SyncPullBatch(
    changes: [
      {'entity': 'user_cards', 'entity_id': 'active', 'op': 'update'},
    ],
    conflicts: [],
    hasMore: false,
    latestServerSeq: 42,
  );

  @override
  Future<void> ack({required String deviceId, required int serverSeq}) async {
    acknowledgments++;
  }

  @override
  Future<List<Map<String, dynamic>>?> fetchSelfTransferRules() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserCard card(String id, {bool archived = false, String? nickname}) => UserCard(
  id: id,
  cardProductId: 'product-$id',
  cardName: '$id card',
  isDefault: !archived,
  isArchived: archived,
  nickname: nickname,
);

class _CardRepository implements UserCardsRepository {
  final void Function()? onArchivedFetch;
  _CardRepository({this.onArchivedFetch});

  @override
  Future<List<UserCard>> fetchUserCards({bool includeArchived = false}) async {
    if (includeArchived) onArchivedFetch?.call();
    return [
      card('active', nickname: 'server update'),
      if (includeArchived) card('archived', archived: true),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;
  late ResponseCache cache;
  late SyncQueue queue;
  final namespace = StateProvider<String>((ref) => 'user:a');

  setUp(() async {
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
    queue = SyncQueue(db, namespace: 'user:a')..deviceId = 'device';
    cache.financialStore.replaceCards('user:a', [card('active')]);
    cache.financialStore.replaceCards('user:a', [
      card('active'),
      card('archived', archived: true),
    ], archived: true);
    // Count actual replacement work in SQLite, rather than mocked calls.
    // Each of the two authoritative snapshots should replace its scope once.
    db.db.execute('''
      CREATE TABLE card_replacement_audit (id TEXT NOT NULL);
      CREATE TRIGGER audit_card_replacement AFTER DELETE ON financial_entities
      WHEN old.namespace = 'user:a' AND old.entity = 'cards'
      BEGIN
        INSERT INTO card_replacement_audit(id) VALUES (old.id);
      END;
    ''');
  });
  tearDown(() {
    cache.financialStore.dispose();
    db.close();
  });

  ProviderContainer container(_CardApi api, _CardRepository repository) =>
      ProviderContainer(
        overrides: [
          cacheNamespaceProvider.overrideWith((ref) => ref.watch(namespace)),
          appDatabaseProvider.overrideWith((ref) async => db),
          isOnlineProvider.overrideWith((ref) => Stream.value(false)),
          responseCacheProvider.overrideWith((ref) async => cache),
          syncQueueProvider.overrideWith((ref) async => queue),
          syncApiProvider.overrideWithValue(api),
          userCardsRepositoryProvider.overrideWithValue(repository),
          // Display invalidation can independently revalidate these providers;
          // isolate the sync owner's authoritative replacement work here.
          userCardsProvider.overrideWith((ref) async => []),
          myCardsProvider.overrideWith((ref) async => []),
        ],
      );

  test(
    'card sync writes each authoritative snapshot once before ack',
    () async {
      final api = _CardApi();
      final scope = container(api, _CardRepository());
      addTearDown(scope.dispose);

      final result = await scope.read(syncEngineProvider).sync();

      expect(result.ranToCompletion, isTrue);
      expect(queue.lastServerSeq, 42);
      expect(api.acknowledgments, 1);
      final cards = cache.financialStore.entities('user:a', 'cards');
      expect(cards.map((row) => row['id']).toSet(), {'active', 'archived'});
      expect(
        cards.singleWhere((row) => row['id'] == 'active')['nickname'],
        'server update',
      );
      expect(
        cards.singleWhere((row) => row['id'] == 'archived')['is_archived'],
        isTrue,
      );
      final activeSnapshot = jsonDecode(
        (await cache.get('user:a:user_cards'))!,
      );
      final allSnapshot = jsonDecode(
        (await cache.get('user:a:user_cards_with_archived'))!,
      );
      expect((activeSnapshot['userCards'] as List).map((row) => row['id']), [
        'active',
      ]);
      expect((allSnapshot['userCards'] as List).map((row) => row['id']), [
        'active',
        'archived',
      ]);
      expect(
        db.db
            .select('SELECT id FROM card_replacement_audit')
            .map((row) => row['id']),
        ['active', 'archived'],
      );
    },
  );

  test(
    'account change during card fetch prevents snapshot publication',
    () async {
      final api = _CardApi();
      late ProviderContainer scope;
      scope = container(
        api,
        _CardRepository(
          onArchivedFetch: () {
            scope.read(namespace.notifier).state = 'user:b';
          },
        ),
      );
      addTearDown(scope.dispose);

      final result = await scope.read(syncEngineProvider).sync();

      expect(result.ranToCompletion, isFalse);
      expect(queue.lastServerSeq, 0);
      expect(api.acknowledgments, 0);
      expect(await cache.get('user:a:user_cards'), isNull);
      expect(await cache.get('user:a:user_cards_with_archived'), isNull);
      expect(cache.financialStore.entities('user:b', 'cards'), isEmpty);
      expect(db.db.select('SELECT id FROM card_replacement_audit'), isEmpty);
      expect(
        cache.financialStore
            .entities('user:a', 'cards')
            .singleWhere((row) => row['id'] == 'active')['nickname'],
        isNull,
      );
    },
  );
}
