import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/connectivity/write_fence.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/spend_by_category_repository.dart';
import 'package:pandapay/data/sync_api.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sync/sync_engine.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// The 18 Nov 2026 bug: "I added a transaction, it showed in spending for a
/// while and then it was gone".
///
/// An edit push makes the sync engine re-read the whole transaction list. While
/// that GET is in flight the quick-add outbox delivers the new transaction. The
/// list was answered from before the add, so it does not contain it, and the
/// engine used to treat "not in the list" as "deleted on the server".
class _Api implements SyncApi {
  @override
  Future<List<SyncPushResult>> push({
    required String deviceId,
    required List<SyncChange> changes,
  }) async => [
    for (final c in changes)
      SyncPushResult(clientSeq: c.clientSeq, applied: true, conflicts: 0),
  ];

  @override
  Future<SyncPullBatch> pull({
    required String deviceId,
    required int since,
    int limit = 500,
  }) async => const SyncPullBatch(
    changes: [],
    conflicts: [],
    hasMore: false,
    latestServerSeq: 0,
  );

  @override
  Future<String> registerDevice({
    required String platform,
    String? label,
    String? appVersion,
    String? deviceId,
  }) async => deviceId ?? 'device';

  @override
  Future<void> ack({required String deviceId, required int serverSeq}) async {}

  @override
  Future<List<Map<String, dynamic>>?> fetchSelfTransferRules() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answers each full-list GET from a script (`call` counts from 1) and each
/// single-row GET from [onRow]; both are counted.
class _Repository implements UserCardsRepository {
  _Repository(this.onList, {this.onRow});
  final Future<List<TransactionEntry>> Function(int call) onList;
  final Future<TransactionEntry> Function(String id, int call)? onRow;
  int lists = 0;
  final rowFetches = <String>[];

  @override
  Future<TransactionEntry> fetchTransaction(String id) {
    rowFetches.add(id);
    final handler = onRow;
    if (handler == null) return Future.value(_row(id, note: 'server copy'));
    return handler(id, rowFetches.length);
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
  }) {
    lists++;
    return onList(lists);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A repository for tests where reading the whole list would be a bug.
_Repository _rowsOnly({
  Future<TransactionEntry> Function(String id, int call)? onRow,
}) => _Repository(
  (_) => Future.error(StateError('the full list was read')),
  onRow: onRow,
);

/// Answers each category-spend GET from a script; `call` counts from 1.
class _SpendRepository extends SpendByCategoryRepository {
  _SpendRepository(this.onFetch)
    : super(apiBaseUrl: 'https://api.test', accessToken: 't');
  final FutureOr<List<CategorySpend>> Function(int call) onFetch;
  int calls = 0;

  @override
  Future<List<CategorySpend>> fetchSpendByCategory({int months = 12}) async =>
      onFetch(++calls);
}

TransactionEntry _row(String id, {String note = ''}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(120),
  occurredAt: DateTime.now(),
  note: note.isEmpty ? null : note,
  source: 'manual',
  status: 'active',
);

void main() {
  late AppDatabase db;
  late ResponseCache cache;
  late SyncQueue queue;
  const ns = 'user:a';

  setUp(() {
    WriteFence.process.reset();
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
    queue = SyncQueue(db, namespace: ns)..deviceId = 'device';
  });
  tearDown(() {
    cache.financialStore.dispose();
    db.close();
    WriteFence.process.reset();
  });

  ProviderContainer engine(_Repository repository) {
    final scope = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(ns),
        appDatabaseProvider.overrideWith((ref) async => db),
        isOnlineProvider.overrideWith((ref) => Stream.value(false)),
        responseCacheProvider.overrideWith((ref) async => cache),
        syncQueueProvider.overrideWith((ref) async => queue),
        syncApiProvider.overrideWithValue(_Api()),
        transactionsProvider.overrideWith((ref) async => []),
        utilizationTransactionsProvider.overrideWith((ref) async => []),
        userCardsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(scope.dispose);
    return scope;
  }

  List<String> storedIds() => [
    for (final r in cache.financialStore.entities(ns, 'transactions'))
      r['id'] as String,
  ];

  /// What the quick-add outbox does when its POST is acknowledged: the server
  /// has the row now, and the phone stores it.
  void deliverNewTransaction({required bool observedByFence}) {
    if (observedByFence) WriteFence.process.markAcked();
    cache.financialStore.saveTransactions(ns, [_row('new-spend')]);
  }

  /// Edits waiting to be pushed: the push is what triggers the refresh of the
  /// rows. One edit is `edited`; more are `edited-0`, `edited-1`...
  void queueEdits(int count) {
    for (var i = 0; i < count; i++) {
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: count == 1 ? 'edited' : 'edited-$i',
        fields: {'note': 'edit'},
      );
    }
  }

  String? noteOf(String id) =>
      cache.financialStore.entities(ns, 'transactions', id: id).single['note']
          as String?;

  group('the refresh after an edit push (one row at a time)', () {
    setUp(() => queueEdits(1));

    test('fetches only the edited row and never reads the full list', () async {
      final repo = _rowsOnly();
      final result = await engine(repo).read(syncEngineProvider).sync();

      expect(result.ranToCompletion, isTrue);
      expect(repo.lists, 0);
      expect(repo.rowFetches, ['edited']);
      expect(noteOf('edited'), 'server copy');
      expect(queue.appliedEntities(), isEmpty);
    });

    test(
      'a transaction delivered while the row is in flight is not touched',
      () async {
        final started = Completer<void>();
        final answer = Completer<TransactionEntry>();
        final repo = _rowsOnly(
          onRow: (id, call) {
            started.complete();
            return answer.future;
          },
        );
        final sync = engine(repo).read(syncEngineProvider).sync();

        await started.future;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        // No fence signal: a row fetch cannot remove anything either way.
        deliverNewTransaction(observedByFence: false);
        answer.complete(_row('edited', note: 'server copy'));
        await sync;

        expect(storedIds(), containsAll(['edited', 'new-spend']));
      },
    );

    test(
      'a write acknowledged while the row is in flight makes it fetch again',
      () async {
        final started = Completer<void>();
        final first = Completer<TransactionEntry>();
        final repo = _rowsOnly(
          onRow: (id, call) {
            if (call == 1) {
              started.complete();
              return first.future;
            }
            return Future.value(_row(id, note: 'second copy'));
          },
        );
        final sync = engine(repo).read(syncEngineProvider).sync();

        await started.future;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        deliverNewTransaction(observedByFence: true);
        first.complete(_row('edited', note: 'first copy'));
        final result = await sync;

        expect(result.ranToCompletion, isTrue);
        expect(repo.rowFetches, ['edited', 'edited'], reason: 'asked again');
        expect(noteOf('edited'), 'second copy');
        expect(storedIds(), containsAll(['edited', 'new-spend']));
        expect(queue.appliedEntities(), isEmpty);
      },
    );

    test(
      'rows that are out of date every time are never stored and the edit stays kept',
      () async {
        // A write is acknowledged during every fetch (an import uploading
        // batches, say).
        final repo = _rowsOnly(
          onRow: (id, call) async {
            WriteFence.process.markAcked();
            return _row(id, note: 'older copy');
          },
        );
        final result = await engine(repo).read(syncEngineProvider).sync();

        expect(result.ranToCompletion, isFalse);
        expect(repo.rowFetches, hasLength(WriteFence.defaultRetries + 1));
        expect(storedIds(), isEmpty, reason: 'the older copy is not stored');
        // The server applied the edit; its fresh copy is still awaited, so the
        // entry stays (it keeps showing the edit) for the next sync.
        expect(queue.appliedEntities(), {'transactions'});
      },
    );

    test('a row the server no longer has is skipped, not deleted', () async {
      cache.financialStore.saveTransactions(ns, [_row('edited', note: 'kept')]);
      final repo = _rowsOnly(
        onRow: (id, call) =>
            Future.error(ApiException('GET /transactions/$id failed: 404 {}')),
      );
      final result = await engine(repo).read(syncEngineProvider).sync();

      expect(result.ranToCompletion, isTrue);
      expect(storedIds(), [
        'edited',
      ], reason: 'only a delete in the feed removes it');
      expect(
        queue.appliedEntities(),
        isEmpty,
        reason: 'nothing left to wait for',
      );
    });

    test(
      'an edit made on the phone after the request was sent is not put back',
      () async {
        cache.financialStore.saveTransactions(ns, [
          _row('edited', note: 'old'),
        ]);
        final started = Completer<void>();
        final answer = Completer<TransactionEntry>();
        final repo = _rowsOnly(
          onRow: (id, call) {
            started.complete();
            return answer.future;
          },
        );
        final sync = engine(repo).read(syncEngineProvider).sync();

        await started.future;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        cache.financialStore.patchTransaction(ns, 'edited', {
          'note': 'edited on the phone',
        });
        answer.complete(_row('edited', note: 'older server copy'));
        await sync;

        expect(noteOf('edited'), 'edited on the phone');
      },
    );

    test('only the refreshed rows lose their applied edit', () {
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'other',
        fields: {'note': 'edit'},
      );
      for (final change in queue.pending()) {
        queue.markApplied(change.clientSeq);
      }
      expect(queue.appliedEntityIds('transactions'), {'edited', 'other'});

      queue.purgeAppliedIds('transactions', ['edited']);

      expect(queue.appliedEntityIds('transactions'), {'other'});
    });
  });

  group(
    'the full-list fallback (more than ${SyncEngine.maxRowRefresh} edited rows)',
    () {
      // One big list is cheaper than hundreds of small requests, so a large batch
      // still reads the list. It is exactly where the 18 Nov bug lived, so it has
      // the same protection: the request time, and the write fence.
      final many = SyncEngine.maxRowRefresh + 1;
      setUp(() => queueEdits(many));

      test(
        'a transaction delivered while the list is in flight is not deleted by it',
        () async {
          final started = Completer<void>();
          final answer = Completer<List<TransactionEntry>>();
          final repo = _Repository((call) {
            started.complete();
            return answer.future;
          });
          final sync = engine(repo).read(syncEngineProvider).sync();

          await started.future; // the GET is out; its snapshot predates the add
          await Future<void>.delayed(const Duration(milliseconds: 5));
          // No fence signal at all: only the timestamps can protect the row.
          deliverNewTransaction(observedByFence: false);
          answer.complete([_row('edited-0')]); // answered from before the add
          await sync;

          expect(storedIds(), containsAll(['edited-0', 'new-spend']));
          expect(repo.rowFetches, isEmpty);
        },
      );

      test(
        'a write acknowledged while the list is in flight makes the engine ask again',
        () async {
          final started = Completer<void>();
          final first = Completer<List<TransactionEntry>>();
          final repo = _Repository((call) {
            if (call == 1) {
              started.complete();
              return first.future;
            }
            // The second GET began after the add, so it has the row.
            return Future.value([_row('edited-0'), _row('new-spend')]);
          });
          final sync = engine(repo).read(syncEngineProvider).sync();

          await started.future;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          deliverNewTransaction(observedByFence: true);
          first.complete([_row('edited-0')]);
          final result = await sync;

          expect(result.ranToCompletion, isTrue);
          expect(
            repo.lists,
            2,
            reason: 'the older answer is dropped and re-read',
          );
          expect(storedIds(), containsAll(['edited-0', 'new-spend']));
          expect(queue.appliedEntities(), isEmpty);
        },
      );

      test(
        'a list that is out of date every time is never applied and the edits stay kept',
        () async {
          final repo = _Repository((call) async {
            deliverNewTransaction(observedByFence: true);
            return [_row('edited-0')]; // never contains 'new-spend'
          });
          final result = await engine(repo).read(syncEngineProvider).sync();

          expect(result.ranToCompletion, isFalse);
          expect(storedIds(), contains('new-spend'));
          expect(queue.appliedEntities(), {'transactions'});
        },
      );
    },
  );

  group('the card list', () {
    const stale = UserCard(
      id: 'card-old',
      cardProductId: 'product-1',
      cardName: 'Old card',
      isDefault: false,
    );
    const justAdded = UserCard(
      id: 'card-new',
      cardProductId: 'product-2',
      cardName: 'Card added a moment ago',
      isDefault: false,
    );

    List<String> cardIds() => [
      for (final c in cache.financialStore.entities(ns, 'cards'))
        c['id'] as String,
    ];

    test(
      'a card stored after the list was requested survives the list',
      () async {
        final requestedAt = DateTime.now();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        // The add_card command settled while the list was in flight.
        cache.financialStore.replaceCards(ns, [stale, justAdded]);
        // The list answers from before it.
        await cache.put(
          '$ns:user_cards',
          jsonEncode({
            'userCards': [stale.toJson()],
          }),
          requestedAt: requestedAt,
        );
        expect(cardIds(), containsAll(['card-old', 'card-new']));
      },
    );

    test(
      'a card the server no longer lists is still removed by a current list',
      () async {
        cache.financialStore.replaceCards(ns, [stale, justAdded]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await cache.put(
          '$ns:user_cards',
          jsonEncode({
            'userCards': [stale.toJson()],
          }),
          requestedAt: DateTime.now(),
        );
        expect(cardIds(), ['card-old']);
      },
    );
  });

  group('background refreshes of saved server snapshots', () {
    // categorySpendProvider shows its saved snapshot and refreshes it in the
    // background through the same path as the budgets, recurring, spend report
    // and monthly report.
    late ProviderContainer scope;
    late _SpendRepository repo;
    late String key;

    Future<void> openWithSavedSnapshot(
      FutureOr<List<CategorySpend>> Function(int call) onFetch,
    ) async {
      repo = _SpendRepository(onFetch);
      scope = ProviderContainer(
        overrides: [
          accessTokenProvider.overrideWith((ref) => 'test-token'),
          responseCacheProvider.overrideWith((ref) async => cache),
          spendByCategoryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(scope.dispose);
      key = '${scope.read(cacheNamespaceProvider)}:category_spend:12';
      await cache.put(key, jsonEncode({'categories': <Object>[]}));
      cache.requestRefresh(key); // due now
      await scope.read(categorySpendProvider.future);
    }

    Future<void> settle(int calls) async {
      for (var i = 0; i < 100 && repo.calls < calls; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    CategorySpend dining() => CategorySpend(
      categoryId: 'c',
      categorySlug: 'dining',
      categoryName: 'Dining',
      totalSpend: Money.fromRupees(500),
      txnCount: 1,
    );

    test(
      'an answer is stored when no write was acknowledged meanwhile',
      () async {
        await openWithSavedSnapshot((_) => [dining()]);
        await settle(1);
        final saved = await cache.read(key);
        expect(saved!.rawJson, contains('Dining'));
        expect(cache.needsRefresh(key), isFalse);
      },
    );

    test(
      'an answer that may predate an acknowledged write is not stored',
      () async {
        await openWithSavedSnapshot((_) {
          WriteFence.process.markAcked(); // a spend was saved during this read
          return [dining()];
        });
        await settle(WriteFence.defaultRetries + 1);

        final saved = await cache.read(key);
        expect(
          saved!.rawJson,
          isNot(contains('Dining')),
          reason: 'the older numbers must not replace the screen',
        );
        expect(
          cache.needsRefresh(key),
          isTrue,
          reason: 'asked for again, not forgotten',
        );
        expect(repo.calls, WriteFence.defaultRetries + 1);
      },
    );

    test(
      'it asks again and stores the answer once no write interrupts',
      () async {
        await openWithSavedSnapshot((call) {
          if (call == 1) WriteFence.process.markAcked();
          return [dining()];
        });
        await settle(2);
        final saved = await cache.read(key);
        expect(saved!.rawJson, contains('Dining'));
        expect(repo.calls, 2);
      },
    );
  });

  group('the transaction list provider', () {
    // Utilization uses the full-list path (Activity pages additively), the same
    // fetch-and-store the sync engine's refresh goes through.
    late _Repository repo;
    late ProviderContainer scope;

    String? storedNote(String id) =>
        cache.financialStore.entities(ns, 'transactions', id: id).single['note']
            as String?;

    Future<void> untilLists(int n) async {
      for (var i = 0; i < 100 && repo.lists < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    ProviderContainer open(_Repository repository) {
      repo = repository;
      scope = ProviderContainer(
        overrides: [
          cacheNamespaceProvider.overrideWithValue(ns),
          appDatabaseProvider.overrideWith((ref) async => db),
          isOnlineProvider.overrideWith((ref) => Stream.value(true)),
          responseCacheProvider.overrideWith((ref) async => cache),
          userCardsRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(scope.dispose);
      return scope;
    }

    test(
      'an edit delivered while a list is in flight is not put back to its old value',
      () async {
        final started = Completer<void>();
        final stale = Completer<List<TransactionEntry>>();
        open(
          _Repository((call) {
            if (call == 1) return Future.value([_row('e', note: 'old')]);
            if (call == 2) {
              started.complete();
              return stale.future;
            }
            return Future.value([_row('e', note: 'new note')]);
          }),
        );
        await scope.read(
          utilizationTransactionsProvider.future,
        ); // saved: 'old'

        // The person edits; the refresh that follows is asked AFTER the edit was
        // saved on the phone, so its timestamp alone cannot tell it is older than
        // the delivery that happens next.
        cache.financialStore.patchTransaction(ns, 'e', {'note': 'new note'});
        await Future<void>.delayed(const Duration(milliseconds: 5));
        scope.invalidate(utilizationTransactionsProvider);
        await scope.read(utilizationTransactionsProvider.future);
        await started.future;

        WriteFence.process.markAcked(); // the queued edit is delivered
        stale.complete([_row('e', note: 'old')]); // answered from before it
        await untilLists(3);

        expect(storedNote('e'), 'new note');
      },
    );

    test(
      'a refresh that predates a write is not handed to a reader asking because of it',
      () async {
        final started = Completer<void>();
        final neverAnswered = Completer<List<TransactionEntry>>();
        open(
          _Repository((call) {
            if (call == 1) return Future.value([_row('e')]);
            if (call == 2) {
              started.complete();
              return neverAnswered.future; // slow: still in flight below
            }
            return Future.value([_row('e')]);
          }),
        );
        await scope.read(utilizationTransactionsProvider.future);
        scope.invalidate(utilizationTransactionsProvider);
        await scope.read(utilizationTransactionsProvider.future);
        await started.future;
        expect(repo.lists, 2);

        // The outbox delivers and invalidates, exactly like outboxFlushProvider.
        WriteFence.process.markAcked();
        scope.invalidate(utilizationTransactionsProvider);
        await scope.read(utilizationTransactionsProvider.future);
        await untilLists(3);

        expect(
          repo.lists,
          greaterThanOrEqualTo(3),
          reason: 'a new read is made, not the in-flight older one joined',
        );
        neverAnswered.complete([_row('e')]);
      },
    );
  });

  group('guard', () {
    test('every full-list save in lib/ passes the time its request was sent', () {
      // A complete list deletes whatever it does not contain that is older than
      // its timestamp. Defaulting that timestamp to "now" (arrival) is the bug.
      final offenders = <String>[];
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        if (file.path.endsWith('data/local/financial_store.dart')) continue;
        final text = file.readAsStringSync();
        var at = text.indexOf('completeQuery:');
        while (at != -1) {
          final open = text.lastIndexOf('saveTransactions(', at);
          if (open == -1) {
            offenders.add(
              '${file.path}: completeQuery outside saveTransactions',
            );
          } else {
            var depth = 0;
            var end = text.indexOf('(', open);
            for (var i = end; i < text.length; i++) {
              if (text[i] == '(') depth++;
              if (text[i] == ')' && --depth == 0) {
                end = i;
                break;
              }
            }
            final call = text.substring(open, end);
            if (!RegExp(r'\bat:').hasMatch(call)) {
              final line = '\n'.allMatches(text.substring(0, open)).length + 1;
              offenders.add('${file.path}:$line');
            }
          }
          at = text.indexOf('completeQuery:', at + 1);
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });
}
