import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/queue_retry_policy.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Fake server: a mutation id listed in [reject] answers with that error, any
/// other id is accepted. [attempted] records every request in order.
class _Server extends UserCardsRepository {
  final Map<String, Object> reject = {};
  Object? failAll;
  final List<String> attempted = [];
  final List<String> accepted = [];

  _Server() : super(apiBaseUrl: 'http://test', accessToken: 'tok');

  @override
  Future<String> logTransaction({
    String? userCardId,
    required Money amount,
    String? categoryId,
    String? userCategoryId,
    String? merchantName,
    String? merchantVpa,
    String? mcc,
    DateTime? occurredAt,
    String? note,
    String? rail,
    TxnInstrument instrument = TxnInstrument.creditCard,
    TxnEntryKind entryKind = TxnEntryKind.spend,
    String? clientMutationId,
    String? paymentMethod,
  }) async {
    attempted.add(clientMutationId!);
    final all = failAll;
    if (all != null) throw all;
    final error = reject[clientMutationId];
    if (error != null) throw error;
    accepted.add(clientMutationId);
    return 'srv-$clientMutationId';
  }
}

ApiException _http(int status) =>
    ApiException('POST /transactions failed: $status {"error":"nope"}');

Map<String, Object?> _row(AppDatabase db, String mutationId) => Map.of(
  db.db.select(
    'SELECT * FROM transaction_outbox_entries WHERE client_mutation_id = ?',
    [mutationId],
  ).single,
);

void main() {
  late AppDatabase appDb;
  late TransactionOutboxRepository outbox;
  late _Server server;
  var clock = DateTime(2026, 11, 13, 10);

  setUp(() {
    clock = DateTime(2026, 11, 13, 10);
    appDb = openInMemoryForTesting();
    outbox = TransactionOutboxRepository(appDb, now: () => clock);
    server = _Server();
  });
  tearDown(() => appDb.close());

  Future<void> enqueue(String id, {int createdOffset = 0}) async {
    await outbox.enqueue(
      userCardId: 'uc',
      amount: Money.fromRupees(10),
      clientMutationId: id,
    );
    appDb.db.execute(
      'UPDATE transaction_outbox_entries SET created_at = ? WHERE client_mutation_id = ?',
      [clock.millisecondsSinceEpoch + createdOffset, id],
    );
  }

  group('poison handling (Q-01)', () {
    test('20 permanently rejected rows do not starve a 21st valid row', () async {
      for (var i = 0; i < 20; i++) {
        await enqueue('bad-$i', createdOffset: i);
        server.reject['bad-$i'] = _http(422);
      }
      await enqueue('good', createdOffset: 100);

      // Pass 1: the oldest 20 are all rejected and parked.
      expect(await outbox.flush(server), 0);
      expect(await outbox.parked(), hasLength(20));
      // Pass 2: they are skipped, the valid row is next in line and sent.
      expect(await outbox.flush(server), 1);
      expect(server.accepted, ['good']);
      expect(await outbox.pending(), isEmpty);
      // The parked rows were attempted exactly once, never again.
      expect(server.attempted.where((id) => id.startsWith('bad-')), hasLength(20));
    });

    test('a permanent 4xx parks the row with its error and no retry', () async {
      await enqueue('a');
      server.reject['a'] = _http(400);
      await outbox.flush(server);
      final row = _row(appDb, 'a');
      expect(row['parked'], 1);
      expect(row['attempts'], 1);
      expect(row['last_error'], contains('400'));
      await outbox.flush(server);
      expect(server.attempted, ['a']);
    });

    test('401, 408 and 429 are never parked', () async {
      for (final status in [401, 408, 429]) {
        final id = 'status-$status';
        await enqueue(id);
        server.reject[id] = _http(status);
      }
      await outbox.flush(server);
      expect(await outbox.parked(), isEmpty);
      for (final status in [401, 408, 429]) {
        expect(_row(appDb, 'status-$status')['parked'], 0);
      }
    });

    test('a transient server error counts an attempt and backs off', () async {
      await enqueue('a');
      server.reject['a'] = _http(503);
      await outbox.flush(server);
      var row = _row(appDb, 'a');
      expect(row['attempts'], 1);
      expect(row['parked'], 0);
      expect(
      row['next_attempt_at'] as int,
      inInclusiveRange(
        clock.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
        clock.add(const Duration(seconds: 36)).millisecondsSinceEpoch,
      ),
      reason: '30 s plus up to 20 % jitter',
    );
      // Not due yet: neither pending() nor another flush touches it.
      expect(await outbox.pending(), isEmpty);
      expect(await outbox.flush(server), 0);
      expect(server.attempted, ['a']);

      clock = clock.add(const Duration(seconds: 37));
      expect(await outbox.pending(), hasLength(1));
      await outbox.flush(server);
      row = _row(appDb, 'a');
      expect(row['attempts'], 2);
      expect(
        row['next_attempt_at'] as int,
        inInclusiveRange(
          clock.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
          clock.add(const Duration(seconds: 72)).millisecondsSinceEpoch,
        ),
      );
    });

    test('a row in backoff does not stop a newer, healthy row', () async {
      await enqueue('flaky', createdOffset: 0);
      await enqueue('fine', createdOffset: 10);
      server.reject['flaky'] = _http(500);
      await outbox.flush(server);
      expect(server.accepted, ['fine']);
      expect(await outbox.flush(server), 0);
    });

    test('the provisional row of a parked entry stays visible', () async {
      final store = FinancialStore(appDb);
      addTearDown(store.dispose);
      final withStore = TransactionOutboxRepository(
        appDb,
        financialStore: store,
        now: () => clock,
      );
      await withStore.enqueue(
        userCardId: 'uc',
        amount: Money.fromRupees(10),
        clientMutationId: 'poison',
      );
      server.reject['poison'] = _http(422);
      await withStore.flush(server);
      expect(await withStore.pending(), isEmpty);
      // A restart rebuilds the provisional rows from every queued entry,
      // parked or not.
      final restarted = TransactionOutboxRepository(
        appDb,
        financialStore: store,
        now: () => clock,
      );
      await restarted.restoreLocalEntries();
      final ids = store
          .transactions('legacy', const TransactionQuery())!
          .rows
          .map((t) => t.id)
          .toList();
      expect(ids, contains('local-outbox:poison'));
    });

    test('retryParked puts the row back in the queue', () async {
      await enqueue('a');
      server.reject['a'] = _http(422);
      await outbox.flush(server);
      final id = (await outbox.parked()).single.id;
      server.reject.remove('a');
      expect(await outbox.retryParked(id), isTrue);
      expect(await outbox.parked(), isEmpty);
      expect(await outbox.flush(server), 1);
      expect(server.accepted, ['a']);
      expect(await outbox.retryParked(id), isFalse);
    });

    test('orders by parked, next attempt, then age', () async {
      await enqueue('old-flaky', createdOffset: 0);
      await enqueue('new', createdOffset: 10);
      server.reject['old-flaky'] = _http(500);
      server.failAll = null;
      await outbox.flush(server);
      clock = clock.add(const Duration(hours: 1));
      // Both due again; the never-failed row (next_attempt_at 0) goes first.
      server.reject.clear();
      await enqueue('newest', createdOffset: 20);
      await outbox.flush(server, maxEntries: 20);
      expect(server.attempted.skip(2), ['newest', 'old-flaky']);
    });
  });

  group('network failures are not attempts', () {
    for (final error in <Object>[
      const SocketException('no route'),
      TimeoutException('slow'),
      http.ClientException('closed'),
      _http(401),
    ]) {
      test('${error.runtimeType} keeps attempts at 0 and sets no backoff', () async {
        await enqueue('a');
        server.failAll = error;
        await outbox.flush(server);
        final row = _row(appDb, 'a');
        expect(row['attempts'], 0);
        expect(row['next_attempt_at'], 0);
        expect(row['parked'], 0);
        expect(row['last_error'], isNotNull);
        expect(await outbox.pending(), hasLength(1));
      });
    }

    test('an ApiException without a status is unknown and counts', () async {
      await enqueue('a');
      server.failAll = ApiException('something odd');
      await outbox.flush(server);
      expect(_row(appDb, 'a')['attempts'], 1);
      expect(_row(appDb, 'a')['next_attempt_at'], isNot(0));
    });

    test('a network failure ends the pass instead of timing out per row', () async {
      for (var i = 0; i < 5; i++) {
        await enqueue('r$i', createdOffset: i);
      }
      server.failAll = const SocketException('offline');
      await outbox.flush(server);
      expect(server.attempted, ['r0']);
    });

    test('many offline flushes never park a row', () async {
      await enqueue('a');
      server.failAll = const SocketException('offline');
      for (var i = 0; i < 12; i++) {
        await outbox.flush(server);
      }
      expect(_row(appDb, 'a')['attempts'], 0);
      server.failAll = null;
      expect(await outbox.flush(server), 1);
    });
  });

  group('reconnect', () {
    test('resetBackoff makes rows in backoff due again, offline to online',
        () async {
      await enqueue('a');
      server.reject['a'] = _http(503);
      await outbox.flush(server);
      expect(await outbox.pending(), isEmpty);

      server.reject.clear();
      await outbox.resetBackoff();
      expect(_row(appDb, 'a')['next_attempt_at'], 0);
      expect(_row(appDb, 'a')['attempts'], 1);
      expect(await outbox.flush(server), 1);
    });

    test('resetBackoff leaves parked rows parked', () async {
      await enqueue('a');
      server.reject['a'] = _http(422);
      await outbox.flush(server);
      await outbox.resetBackoff();
      expect(await outbox.parked(), hasLength(1));
      expect(await outbox.pending(), isEmpty);
    });

    test('all() lists every queued row, even parked or in backoff', () async {
      await enqueue('parked', createdOffset: 0);
      await enqueue('backoff', createdOffset: 1);
      await enqueue('due', createdOffset: 2);
      server.reject['parked'] = _http(422);
      server.reject['backoff'] = _http(500);
      server.failAll = null;
      server.reject['due'] = const SocketException('x');
      await outbox.flush(server);
      // Never-tried first, then the one waiting out a backoff, parked last.
      expect((await outbox.all()).map((e) => e.clientMutationId), [
        'due',
        'backoff',
        'parked',
      ]);
      expect(await outbox.pending(), hasLength(1));
    });
  });

  group('classifyQueueFailure / queueBackoff', () {
    test('status mapping', () {
      expect(classifyQueueFailure(_http(500)), QueueFailure.retryable);
      expect(classifyQueueFailure(_http(502)), QueueFailure.retryable);
      expect(classifyQueueFailure(_http(408)), QueueFailure.retryable);
      expect(classifyQueueFailure(_http(429)), QueueFailure.retryable);
      expect(classifyQueueFailure(_http(400)), QueueFailure.permanent);
      expect(classifyQueueFailure(_http(403)), QueueFailure.permanent);
      expect(classifyQueueFailure(_http(404)), QueueFailure.permanent);
      expect(classifyQueueFailure(_http(409)), QueueFailure.permanent);
      expect(classifyQueueFailure(_http(401)), QueueFailure.network);
      expect(classifyQueueFailure(StateError('x')), QueueFailure.retryable);
      expect(classifyQueueFailure(ApiException('no status')), QueueFailure.retryable);
    });

    test('backoff doubles from 30 s and caps at 30 min', () {
      expect(queueBackoff(1), const Duration(seconds: 30));
      expect(queueBackoff(2), const Duration(minutes: 1));
      expect(queueBackoff(3), const Duration(minutes: 2));
      expect(queueBackoff(7), const Duration(minutes: 30));
      expect(queueBackoff(500), const Duration(minutes: 30));
    });
  });
}
