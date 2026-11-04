import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/data/shared_transport.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/sync/shared_sync.dart';

import '../storage/shared_store_test.dart' as fixtures;

class FakeRemote implements SharedExpensesTransport {
  final committed = <String, SharedCommitResponse>{};
  final sent = <String>[];
  bool loseOnce = false;
  Completer<void>? delay;
  int effects = 0;
  @override
  Future<SharedCommitResponse?> lookupOperation(String operationId) async =>
      committed[operationId];
  @override
  Future<SharedCommitResponse> execute(SharedCommand command) async {
    sent.add(command.operationId);
    if (delay != null) await delay!.future;
    final result = committed.putIfAbsent(command.operationId, () {
      effects++;
      return SharedCommitResponse(
        receipt: fixtures.receipt(command),
        records: [fixtures.projection()],
      );
    });
    if (loseOnce) {
      loseOnce = false;
      throw const SharedTransportException();
    }
    return result;
  }

  @override
  Future<SharedChangePage> pull({String? cursor, int limit = 100}) async =>
      SharedChangePage(records: [], nextCursor: cursor);
}

void main() {
  late AppDatabase db;
  late SharedExpensesStore store;
  late FakeRemote remote;
  var current = true, time = 1000;
  late SharedExpensesSync sync;
  setUp(() {
    db = openInMemoryForTesting();
    store = SharedExpensesStore(db, namespace: fixtures.accountA);
    remote = FakeRemote();
    current = true;
    time = 1000;
    sync = SharedExpensesSync(
      store: store,
      remote: remote,
      isCurrent: () => current,
      now: () => time,
      leaseId: 'test-worker',
    );
  });
  tearDown(() => db.close());
  test(
    'lost response looks up same operation, applies one server effect and clears overlay',
    () async {
      await store.enqueue(
        fixtures.command(),
        provisional: {'title': 'Pending'},
      );
      remote.loseOnce = true;
      await sync.flush();
      expect(remote.effects, 1);
      expect(store.pendingCount, 1);
      time += 600000;
      await sync.flush();
      expect(remote.effects, 1);
      expect(remote.sent, [fixtures.op1]);
      expect(
        store.operation(fixtures.op1)!.state,
        SharedCommandState.committed,
      );
      expect(store.provisional(fixtures.op1), isNull);
    },
  );
  test(
    'account switch during HTTP does not acknowledge or publish old account data',
    () async {
      await store.enqueue(fixtures.command());
      remote.delay = Completer();
      final running = sync.flush();
      await Future<void>.delayed(Duration.zero);
      current = false;
      remote.delay!.complete();
      await running;
      expect(remote.effects, 1);
      expect(store.receipt(fixtures.op1), isNull);
      expect(
        store.readPage(entity: 'contexts', contextId: fixtures.contextId).items,
        isEmpty,
      );
      current = true;
      time += 600000;
      await sync.flush();
      expect(remote.effects, 1);
      expect(store.receipt(fixtures.op1), isNotNull);
    },
  );
  test(
    'offline account fence prevents both claims and network calls',
    () async {
      await store.enqueue(fixtures.command());
      current = false;
      await sync.flush();
      expect(remote.sent, isEmpty);
      expect(store.operation(fixtures.op1)!.state, SharedCommandState.pending);
    },
  );
}
