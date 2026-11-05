import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/portable_backup/local_restore_writer.dart';
import 'package:pandapay/data/portable_backup/portable_attachments.dart';
import 'package:pandapay/data/transaction_page_refresh.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry row(String id) => TransactionEntry(
  id: id,
  amount: Money.fromPaise(100),
  occurredAt: DateTime(2026, 11, 1),
  status: 'active',
  source: 'manual',
);

http.Response page(String id, {String? next}) => http.Response(
  jsonEncode({
    'transactions': [row(id).toJson()],
    'pageInfo': {'hasMore': next != null, 'nextCursor': next},
  }),
  200,
);

void main() {
  late AppDatabase db;
  late FinancialStore store;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  TransactionPageRefresh owner(
    http.Client client, {
    bool Function()? isCurrent,
  }) => TransactionPageRefresh(
    namespace: 'user:a',
    sessionGeneration: 'session:1',
    query: const TransactionQuery(),
    repository: UserCardsRepository(
      apiBaseUrl: 'https://api.test',
      accessToken: 'a',
      client: client,
    ),
    store: store,
    isCurrent: isCurrent ?? () => true,
    maxPagesPerPass: 1,
  );

  test(
    'bounded pages retain older rows and persist a resumable cursor',
    () async {
      store.saveTransactions('user:a', [row('older')]);
      final cursors = <String?>[];
      final client = MockClient((request) async {
        final cursor = request.url.queryParameters['cursor'];
        cursors.add(cursor);
        return cursor == null ? page('first', next: 'cursor-1') : page('last');
      });
      final first = await owner(client).refresh();
      expect(first.hasMore, isTrue);
      expect(
        store
            .transactionPageProgress('user:a', const TransactionQuery())!
            .nextCursor,
        'cursor-1',
      );
      expect(
        store.transactions('user:a', const TransactionQuery())!.complete,
        isFalse,
      );

      final second = await owner(client).refresh();
      expect(second.hasMore, isFalse);
      expect(cursors, [null, 'cursor-1']);
      expect(
        store
            .transactions('user:a', const TransactionQuery())!
            .rows
            .map((r) => r.id)
            .toSet(),
        {'older', 'first', 'last'},
      );
      expect(
        store.transactions('user:a', const TransactionQuery())!.complete,
        isFalse,
      );
    },
  );

  test('failed page commit rolls back rows and cursor together', () async {
    final refresh = owner(MockClient((_) async => page('first', next: 'next')));
    db.db.execute(
      "CREATE TRIGGER fail_page BEFORE INSERT ON financial_transaction_pages BEGIN SELECT RAISE(ABORT, 'disk failure'); END;",
    );
    await expectLater(refresh.refresh(), throwsException);
    expect(
      store.transactionPageProgress('user:a', const TransactionQuery()),
      isNull,
    );
    expect(store.transactions('user:a', const TransactionQuery()), isNull);
  });

  test(
    'same owner coalesces requests and ignores stale session response',
    () async {
      final pending = Completer<http.Response>();
      var current = true;
      var calls = 0;
      final refresh = owner(
        MockClient((_) {
          calls++;
          return pending.future;
        }),
        isCurrent: () => current,
      );
      final first = refresh.refresh();
      expect(identical(first, refresh.refresh()), isTrue);
      current = false;
      pending.complete(page('wrong-session', next: 'next'));
      await expectLater(first, throwsStateError);
      expect(calls, 1);
      expect(store.transactions('user:a', const TransactionQuery()), isNull);
    },
  );

  test(
    'a new session restarts cursor and clear removes paging state',
    () async {
      final client = MockClient((_) async => page('first', next: 'next'));
      await owner(client).refresh();
      final restarted = TransactionPageRefresh(
        namespace: 'user:a',
        sessionGeneration: 'session:2',
        query: const TransactionQuery(),
        repository: UserCardsRepository(
          apiBaseUrl: 'https://api.test',
          accessToken: 'a',
          client: MockClient((request) async {
            expect(request.url.queryParameters.containsKey('cursor'), isFalse);
            return page('new-session', next: 'different');
          }),
        ),
        store: store,
        isCurrent: () => true,
        maxPagesPerPass: 1,
      );
      await restarted.refresh();
      expect(
        store
            .transactionPageProgress('user:a', const TransactionQuery())!
            .sessionGeneration,
        'session:2',
      );
      store.clear('user:a');
      expect(
        store.transactionPageProgress('user:a', const TransactionQuery()),
        isNull,
      );
    },
  );

  test(
    'network failure resumes committed cursor and preserves offline edits',
    () async {
      store.saveTransactions('user:a', [row('older')]);
      SyncQueue(db, namespace: 'user:a').enqueueUpdate(
        entity: 'transactions',
        entityId: 'older',
        fields: {'note': 'offline edit'},
      );
      final cursors = <String?>[];
      var calls = 0;
      final refresh = owner(
        MockClient((request) async {
          calls++;
          cursors.add(request.url.queryParameters['cursor']);
          if (calls == 1) return page('first', next: 'next');
          if (calls == 2) return http.Response('offline', 503);
          return page('last');
        }),
      );
      await refresh.refresh();
      await expectLater(refresh.refresh(), throwsException);
      expect(
        store
            .transactionPageProgress('user:a', const TransactionQuery())!
            .nextCursor,
        'next',
      );
      await refresh.refresh();
      expect(cursors, [null, 'next', 'next']);
      expect(
        store.entities('user:a', 'transactions', id: 'older').single['note'],
        'offline edit',
      );
      expect(store.transactions('user:b', const TransactionQuery()), isNull);
    },
  );

  test(
    'a page that repeats its cursor fails before publishing any rows',
    () async {
      var calls = 0;
      final refresh = owner(
        MockClient((_) async {
          calls++;
          return page(calls == 1 ? 'first' : 'invalid', next: 'next');
        }),
      );
      await refresh.refresh();
      await expectLater(refresh.refresh(), throwsFormatException);
      expect(store.entities('user:a', 'transactions', id: 'invalid'), isEmpty);
      expect(
        store
            .transactionPageProgress('user:a', const TransactionQuery())!
            .nextCursor,
        'next',
      );
    },
  );

  test(
    'query cursors remain independent and an exhausted pass is idle',
    () async {
      final requests = <Map<String, String>>[];
      final repository = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'a',
        client: MockClient((request) async {
          requests.add(request.url.queryParameters);
          return page(request.url.queryParameters['cardId'] ?? 'all');
        }),
      );
      TransactionPageRefresh queryOwner(TransactionQuery query) =>
          TransactionPageRefresh(
            namespace: 'user:a',
            sessionGeneration: 'session:1',
            query: query,
            repository: repository,
            store: store,
            isCurrent: () => true,
          );
      final all = queryOwner(const TransactionQuery());
      await all.refresh();
      final idle = await all.refresh();
      expect(idle.pages, 0);
      await queryOwner(const TransactionQuery(cardId: 'card')).refresh();
      expect(requests, hasLength(2));
      expect(requests.last['cardId'], 'card');
      expect(
        store
            .transactionPageProgress(
              'user:a',
              const TransactionQuery(cardId: 'card'),
            )!
            .exhausted,
        isTrue,
      );
      expect(
        store.transactions('user:a', const TransactionQuery())!.complete,
        isFalse,
      );
    },
  );

  test('fresh portable restore clears page progress transactionally', () async {
    await owner(MockClient((_) async => page('first', next: 'next'))).refresh();
    final writer = LocalPortableRestoreWriter(
      appDb: db,
      namespace: 'user:a',
      receipts: _NoReceipts(),
    );
    await writer.beginFreshNamespace();
    expect(
      store.transactionPageProgress('user:a', const TransactionQuery()),
      isNull,
    );
    await writer.rollback();
    expect(
      store
          .transactionPageProgress('user:a', const TransactionQuery())!
          .nextCursor,
      'next',
    );
  });
}

/// This test installs no attachments; any use is a test failure.
final class _NoReceipts implements PortableReceiptVault {
  @override
  Future<Uint8List> readPlaintext(PortableAttachmentSource source) =>
      throw UnimplementedError();

  @override
  Future<String> storeEncrypted({
    required String attachmentId,
    required String transactionId,
    required File plaintext,
  }) => throw UnimplementedError();
}
