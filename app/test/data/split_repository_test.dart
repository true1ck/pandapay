import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/split_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionSplit share(num rupees) =>
    TransactionSplit(amount: Money.fromRupees(rupees));
TransactionSplitDocument doc(List<TransactionSplit> shares) =>
    TransactionSplitDocument(
      shares,
      fingerprint: SplitRepository.fingerprint(shares),
    );

class _Remote implements UserCardsRepository {
  TransactionSplitDocument server = doc([]);
  int gets = 0, puts = 0;
  Object? failure;
  bool loseResponse = false;
  Completer<void>? gate;
  @override
  Future<TransactionSplitDocument> fetchSplitDocument(String id) async {
    gets++;
    final snapshot = server;
    if (gate != null) await gate!.future;
    return snapshot;
  }

  @override
  Future<TransactionSplitDocument> saveSplitDocument(
    String id,
    TransactionSplitDocument next,
  ) async {
    puts++;
    if (failure != null) throw failure!;
    if (gate != null) await gate!.future;
    final desired = doc(next.splits);
    if (desired.fingerprint != server.fingerprint &&
        next.fingerprint != server.fingerprint) {
      throw ApiException('PUT splits failed: 409 {"error":"split_conflict"}');
    }
    server = desired;
    if (loseResponse) {
      loseResponse = false;
      throw StateError('response lost');
    }
    return server;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase database;
  late _Remote remote;
  late SplitRepository store;
  late bool online;
  late DateTime time;
  SplitRepository create([String namespace = 'account-a']) => SplitRepository(
    database,
    namespace: namespace,
    remote: () => remote,
    canSync: () => online,
    now: () => time,
    autoSync: false,
  );

  setUp(() {
    database = openInMemoryForTesting();
    remote = _Remote();
    online = true;
    time = DateTime(2026, 10, 18);
    store = create();
  });
  tearDown(() {
    store.dispose();
    database.close();
  });

  test(
    'HTTP transport forwards the server fingerprint with a replacement',
    () async {
      final empty = SplitRepository.fingerprint([]);
      var writes = 0;
      final api = UserCardsRepository(
        apiBaseUrl: 'https://example.test',
        accessToken: 'token',
        client: MockClient((request) async {
          expect(request.url.path, '/transactions/t1/splits');
          if (request.method == 'PUT') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['expectedFingerprint'], empty);
            expect((body['splits'] as List).single['amountInr'], 10);
            writes++;
          }
          return http.Response(
            jsonEncode({'splits': [], 'fingerprint': empty}),
            200,
          );
        }),
      );
      final baseline = await api.fetchSplitDocument('t1');
      await api.saveSplitDocument(
        't1',
        TransactionSplitDocument([
          share(10),
        ], fingerprint: baseline.fingerprint),
      );
      expect(writes, 1);
    },
  );

  test('a network failure backs off the whole pending set', () async {
    await store.read('t1');
    await store.read('t2');
    store.save('t1', [share(100)], Money.fromRupees(1000));
    store.save('t2', [share(200)], Money.fromRupees(1000));
    remote.failure = StateError('offline');
    await store.sync();
    await store.sync();
    expect(remote.puts, 1);
    expect(store.pendingCount, 2);
  });

  test('failed SQLite writes cannot appear as saved changes', () async {
    await store.read('t1');
    database.db.execute(
      "CREATE TRIGGER fail_split_save BEFORE UPDATE ON split_documents BEGIN SELECT RAISE(ABORT, 'disk unavailable'); END",
    );
    expect(
      () => store.save('t1', [share(100)], Money.fromRupees(1000)),
      throwsA(anything),
    );
    expect(store.local('t1')!.pending, false);
    expect(store.local('t1')!.document.splits, isEmpty);
    expect(remote.puts, 0);
  });

  test('server changes after conflict review cause another conflict', () async {
    await store.read('t1');
    store.save('t1', [share(100)], Money.fromRupees(1000));
    remote.server = doc([share(200)]);
    await store.sync();
    final reviewed = await store.fetchServerVersion('t1');
    remote.server = doc([share(300)]);
    await store.resolve('t1', keepLocal: true, reviewedServerVersion: reviewed);
    await store.sync();
    expect(store.local('t1')!.blocked, true);
    expect(remote.server.splits.single.amount.rupees, 300);
  });

  test(
    'fresh reads and unchanged documents make no repeated requests',
    () async {
      await store.read('t1');
      await store.read('t1');
      store.save('t1', [], Money.fromRupees(1000));
      await store.sync();
      expect(remote.gets, 1);
      expect(remote.puts, 0);
    },
  );

  test(
    'offline saves survive repository restart and coalesce to latest set',
    () async {
      await store.read('t1');
      online = false;
      store.save('t1', [share(100)], Money.fromRupees(1000));
      store.save('t1', [share(200), share(300)], Money.fromRupees(1000));
      store.dispose();
      store = create();
      expect((await store.read('t1')).document.splits, hasLength(2));
      expect(remote.puts, 0);
      online = true;
      await store.sync();
      expect(remote.puts, 1);
      expect(store.local('t1')!.pending, false);
      expect(remote.server.splits.map((s) => s.amount.rupees), [200, 300]);
    },
  );

  test('offline clear is a durable empty replacement', () async {
    remote.server = doc([share(200)]);
    await store.read('t1');
    online = false;
    store.save('t1', [], Money.fromRupees(1000));
    expect(store.local('t1')!.pending, true);
    online = true;
    await store.sync();
    expect(remote.server.splits, isEmpty);
    expect(store.local('t1')!.pending, false);
  });

  test(
    'conflicting device edits are retained and require explicit resolution',
    () async {
      await store.read('t1');
      store.save('t1', [share(100)], Money.fromRupees(1000));
      remote.server = doc([share(200)]);
      await store.sync();
      expect(store.local('t1')!.blocked, true);
      expect(store.local('t1')!.document.splits.single.amount.rupees, 100);
      await store.sync(reconnect: true);
      expect(remote.puts, 1);
      await store.resolve('t1', keepLocal: true);
      await store.sync();
      expect(remote.server.splits.single.amount.rupees, 100);
      expect(store.local('t1')!.pending, false);
    },
  );

  test('choosing server version explicitly clears the conflict', () async {
    await store.read('t1');
    store.save('t1', [share(100)], Money.fromRupees(1000));
    remote.server = doc([share(200)]);
    await store.sync();
    await store.resolve('t1', keepLocal: false);
    expect(store.local('t1')!.document.splits.single.amount.rupees, 200);
    expect(store.local('t1')!.pending, false);
  });

  test(
    'lost response safely retries identical content without conflict',
    () async {
      await store.read('t1');
      store.save('t1', [share(100)], Money.fromRupees(1000));
      remote.loseResponse = true;
      await store.sync();
      expect(store.local('t1')!.pending, true);
      await store.sync();
      expect(remote.puts, 1); // persisted backoff
      await store.sync(reconnect: true);
      expect(store.local('t1')!.pending, false);
      expect(remote.puts, 2);
    },
  );

  test('acknowledging an older in-flight save preserves newer edits', () async {
    await store.read('t1');
    store.save('t1', [share(100)], Money.fromRupees(1000));
    remote.gate = Completer<void>();
    final sending = store.sync();
    await Future<void>.delayed(Duration.zero);
    store.save('t1', [share(250)], Money.fromRupees(1000));
    remote.gate!.complete();
    await sending;
    remote.gate = null;
    expect(store.local('t1')!.pending, true);
    expect(store.local('t1')!.document.splits.single.amount.rupees, 250);
    await store.sync();
    expect(remote.server.splits.single.amount.rupees, 250);
    expect(store.local('t1')!.pending, false);
  });

  test(
    'stale GET cannot overwrite a local edit made while refreshing',
    () async {
      await store.read('t1');
      remote.gate = Completer<void>();
      final refreshing = store.refresh('t1');
      store.save('t1', [share(250)], Money.fromRupees(1000));
      remote.gate!.complete();
      await refreshing;
      expect(store.local('t1')!.document.splits.single.amount.rupees, 250);
      expect(store.local('t1')!.pending, true);
    },
  );

  test(
    'account boundaries and disposal prevent wrong-account acknowledgements',
    () async {
      await store.read('t1');
      store.save('t1', [share(100)], Money.fromRupees(1000));
      final other = create('account-b');
      expect(other.local('t1'), isNull);
      other.dispose();
      remote.gate = Completer<void>();
      final sending = store.sync();
      await Future<void>.delayed(Duration.zero);
      online = false;
      remote.gate!.complete();
      await sending;
      expect(store.local('t1')!.pending, true);
    },
  );

  test(
    'authentication failures preserve edits; validation failures pause retries',
    () async {
      await store.read('t1');
      store.save('t1', [share(100)], Money.fromRupees(1000));
      remote.failure = ApiException('PUT splits failed: 401 {}');
      await store.sync();
      expect(store.local('t1')!.pending, true);
      expect(store.local('t1')!.blocked, false);
      remote.failure = ApiException('PUT splits failed: 400 {}');
      await store.sync(reconnect: true);
      expect(store.local('t1')!.blocked, true);
      await store.sync(reconnect: true);
      expect(remote.puts, 2);
    },
  );

  test('blockedCount counts only refused documents of this account', () async {
    await store.read('t1');
    await store.read('t2');
    store.save('t1', [share(100)], Money.fromRupees(1000));
    store.save('t2', [share(100)], Money.fromRupees(1000));
    expect(store.pendingCount, 2);
    expect(store.blockedCount, 0);
    remote.failure = ApiException('PUT splits failed: 400 {}');
    await store.sync();
    // A 4xx is permanent for that document: both stay unsent but are blocked.
    expect(store.blockedCount, 2);
    expect(store.pendingCount, 2);
    expect(create('account-b').blockedCount, 0);
    remote.failure = null;
    await store.sync(reconnect: true);
    // Blocked ones are left alone until the person resolves them.
    expect(store.blockedCount, 2);
    await store.resolve('t1', keepLocal: false);
    expect(store.blockedCount, 1);
  });

  test('a never-loaded split opens empty offline and saves durably', () async {
    online = false;
    final first = await store.read('t1');
    expect(first.document.splits, isEmpty);
    expect(first.version, 0);
    expect(first.pending, false);
    store.save('t1', [share(100)], Money.fromRupees(1000));
    expect(store.local('t1')!.pending, true);
    expect(remote.gets, 0);
    store.dispose();
    store = create();
    expect(store.local('t1')!.document.splits.single.amount.rupees, 100);
    online = true;
    await store.sync();
    expect(store.local('t1')!.pending, false);
    expect(remote.server.splits.single.amount.rupees, 100);
  });

  test('an offline empty baseline reconciles through the 409 flow', () async {
    online = false;
    await store.read('t1');
    store.save('t1', [share(100)], Money.fromRupees(1000));
    // The split already existed on the server (never seen on this phone).
    remote.server = doc([share(200)]);
    online = true;
    await store.sync();
    expect(store.local('t1')!.blocked, true);
    expect(store.blockedCount, 1);
    expect(store.local('t1')!.document.splits.single.amount.rupees, 100);
    await store.resolve('t1', keepLocal: true);
    await store.sync();
    expect(remote.server.splits.single.amount.rupees, 100);
    expect(store.local('t1')!.pending, false);
  });

  test('an unedited offline baseline is replaced by the server copy', () async {
    online = false;
    await store.read('t1');
    remote.server = doc([share(250)]);
    online = true;
    await store.read('t1'); // returns the baseline, refreshes behind it
    await Future<void>.delayed(Duration.zero);
    expect(store.local('t1')!.document.splits.single.amount.rupees, 250);
  });

  test('a failed first fetch (network down) also opens empty', () async {
    remote.failure = null;
    final failing = _FailingFetch();
    final repo = SplitRepository(
      database,
      namespace: 'account-z',
      remote: () => failing,
      canSync: () => true,
      now: () => time,
      autoSync: false,
    );
    expect((await repo.read('t9')).document.splits, isEmpty);
    repo.dispose();
  });

  test('a refusal on first fetch (not a network failure) is still an error', () async {
    final repo = SplitRepository(
      database,
      namespace: 'account-y',
      remote: () => _FailingFetch(ApiException('GET splits failed: 403 {}')),
      canSync: () => true,
      now: () => time,
      autoSync: false,
    );
    await expectLater(repo.read('t9'), throwsA(isA<ApiException>()));
    repo.dispose();
  });
}

class _FailingFetch implements UserCardsRepository {
  final Object error;
  _FailingFetch([Object? error])
    : error = error ?? http.ClientException('Failed host lookup');
  @override
  Future<TransactionSplitDocument> fetchSplitDocument(String id) async =>
      throw error;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
