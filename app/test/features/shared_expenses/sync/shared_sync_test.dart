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

  /// Consulted before the server "does" anything; a returned error is thrown.
  Object? Function(SharedCommand)? refuse;
  @override
  Future<SharedCommitResponse?> lookupOperation(String operationId) async =>
      committed[operationId];
  @override
  Future<SharedCommitResponse> execute(SharedCommand command) async {
    sent.add(command.operationId);
    final refusal = refuse?.call(command);
    if (refusal != null) throw refusal;
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

  group('WP-C8 offline Split fixes', () {
    const ctx = '33333333-3333-4333-8333-333333333333';
    const member = '77777777-7777-4777-8777-777777777777';
    const createId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    const inviteId = '00000000-0000-4000-8000-000000000001';
    SharedCommand create() => SharedCommand(
      operationId: createId,
      kind: 'context.create',
      payload: {'contextId': ctx, 'contextKind': 'group', 'name': 'Trip'},
    );
    SharedCommand invite() => SharedCommand(
      operationId: inviteId,
      kind: 'member.invite',
      payload: {'contextId': ctx, 'memberId': member, 'displayName': 'Sam'},
    );
    // The real server's answer for a context it has not seen yet.
    Object? serverRule(SharedCommand c) =>
        c.kind != 'context.create' && !remote.committed.containsKey(createId)
        ? const SharedTransportException(
            statusCode: 403,
            code: 'context_not_authorized',
          )
        : null;

    test('create then invite saved offline both reach the server, in order, '
        'with no rejection', () async {
      remote.refuse = serverRule;
      await store.enqueue(create());
      await store.enqueue(invite());
      await sync.flush();
      // One pass: the invite waited for the create's receipt, then followed.
      expect(remote.sent, [createId, inviteId]);
      expect(store.attentionCount, 0);
      expect(store.operation(inviteId)!.state, SharedCommandState.committed);
    });

    test('an invite queued by an older build before its create is retried, '
        'not rejected', () async {
      remote.refuse = serverRule;
      await store.enqueue(invite());
      await store.enqueue(create());
      await sync.flush();
      // The invite got the 403 first, then the create went through.
      expect(remote.sent, [inviteId, createId]);
      expect(store.operation(inviteId)!.state, SharedCommandState.retry);
      expect(store.attentionCount, 0);
      time += 600000;
      await sync.flush();
      expect(store.operation(inviteId)!.state, SharedCommandState.committed);
    });

    test(
      'the same 403 once the create is committed is a real refusal',
      () async {
        await store.enqueue(create());
        await sync.flush();
        remote.refuse = (c) => const SharedTransportException(
          statusCode: 403,
          code: 'context_not_authorized',
        );
        await store.enqueue(invite());
        await sync.flush();
        expect(store.operation(inviteId)!.state, SharedCommandState.rejected);
        expect(store.attentionCount, 1);
      },
    );

    test('429 Retry-After is waited out, then the command is sent', () async {
      remote.refuse = (c) => SharedTransportException(
        statusCode: 429,
        retryAfter: const Duration(minutes: 10),
      );
      await store.enqueue(invite());
      await sync.flush();
      time += 9 * 60 * 1000;
      remote.refuse = null;
      await sync.flush();
      expect(remote.sent, [inviteId]);
      time += 2 * 60 * 1000;
      await sync.flush();
      expect(store.operation(inviteId)!.state, SharedCommandState.committed);
    });

    test('reconnect: resetBackoff lets a command waiting out a backoff go '
        'now', () async {
      remote.refuse = (c) => const SharedTransportException();
      await store.enqueue(invite());
      await sync.flush();
      remote.refuse = null;
      time += 1; // still inside the backoff
      await sync.flush();
      expect(remote.sent, [inviteId]);
      await store.resetBackoff();
      await sync.flush();
      expect(remote.sent, [inviteId, inviteId]);
      expect(store.operation(inviteId)!.state, SharedCommandState.committed);
    });

    test('a server that keeps failing ends in the needs-attention list '
        'instead of retrying for ever', () async {
      remote.refuse = (c) => const SharedTransportException(statusCode: 503);
      await store.enqueue(invite());
      for (var i = 0; i < sharedMaxAttempts; i++) {
        time += 1000000;
        await sync.flush();
      }
      expect(store.operation(inviteId)!.state, SharedCommandState.rejected);
      expect(store.readAttention().single.errorCode, startsWith('retry_limit'));
      time += 1000000;
      final before = remote.sent.length;
      await sync.flush();
      expect(remote.sent.length, before);
      // Retry gives it a fresh budget and it can now succeed.
      remote.refuse = null;
      await store.requeue(inviteId);
      await sync.flush();
      expect(store.operation(inviteId)!.state, SharedCommandState.committed);
    });
  });
}
