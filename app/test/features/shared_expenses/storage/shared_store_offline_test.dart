import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';

import 'shared_store_test.dart' as fixtures;

// WP-C8 (Split offline fixes): enqueue order, dependsOn, retry rules, the
// needs-attention queue and reconnect. Synthetic ids only.
const _ctxA = '33333333-3333-4333-8333-333333333333';
const _ctxB = '66666666-6666-4666-8666-666666666666';
const _member = '77777777-7777-4777-8777-777777777777';
const _idLow = '00000000-0000-4000-8000-000000000001';
const _idMid = '55555555-5555-4555-8555-555555555551';
const _idHigh = 'ffffffff-ffff-4fff-8fff-ffffffffffff';

SharedCommand _create(String id, String context, {String kind = 'group'}) =>
    SharedCommand(
      operationId: id,
      kind: 'context.create',
      payload: {'contextId': context, 'contextKind': kind, 'name': 'Trip'},
    );

SharedCommand _invite(String id, String context) => SharedCommand(
  operationId: id,
  kind: 'member.invite',
  payload: {'contextId': context, 'memberId': _member, 'displayName': 'Sam'},
);

SharedCommand _rename(String id, String context) => SharedCommand(
  operationId: id,
  kind: 'member.rename',
  payload: {'contextId': context, 'memberId': _member, 'displayName': 'Sam'},
);

void main() {
  late AppDatabase db;
  late SharedExpensesStore store;
  setUp(() {
    db = openInMemoryForTesting();
    store = SharedExpensesStore(db, namespace: fixtures.accountA);
  });
  tearDown(() => db.close());

  Future<SharedCommandClaim> claim(int now) async =>
      (await store.claim(now: now, leaseId: 'worker'))!;

  Future<void> commit(SharedCommandClaim c) async => store.complete(
    c,
    SharedOperationReceipt(
      operationId: c.command.operationId,
      kind: c.command.kind,
      requestHash: c.command.requestHash,
      contextId: c.command.contextId,
      result: {'ok': true},
    ),
    const [],
  );

  group('ordering (X-03)', () {
    test(
      'independent commands keep enqueue order, not random operation-id order',
      () async {
        // The id that sorts LAST is enqueued FIRST.
        await store.enqueue(_rename(_idHigh, _ctxA));
        await store.enqueue(_rename(_idLow, _ctxB));
        await store.enqueue(_rename(_idMid, _ctxA));
        expect((await claim(1)).command.operationId, _idHigh);
        expect((await claim(1)).command.operationId, _idLow);
        expect((await claim(1)).command.operationId, _idMid);
      },
    );

    test('equal-millisecond enqueues still get strictly rising stamps', () async {
      for (final id in [_idHigh, _idMid, _idLow]) {
        await store.enqueue(_rename(id, _ctxA));
      }
      final rows = db.db.select(
        'SELECT created_at FROM shared_commands WHERE namespace=? ORDER BY rowid',
        [fixtures.accountA],
      );
      final stamps = [for (final r in rows) r['created_at'] as int];
      expect(stamps.every((s) => s > 0), isTrue);
      expect(stamps[0] < stamps[1] && stamps[1] < stamps[2], isTrue);
    });

    test('an explicit createdAt is still honoured', () async {
      await store.enqueue(_rename(_idHigh, _ctxA), createdAt: 5);
      expect(
        db.db
            .select('SELECT created_at FROM shared_commands')
            .single['created_at'],
        5,
      );
    });
  });

  group('dependsOn for a context created in the same session', () {
    test('invite waits for its own unconfirmed context.create', () async {
      // Invite id sorts before the create id and is enqueued second.
      await store.enqueue(_create(_idHigh, _ctxA));
      await store.enqueue(_invite(_idLow, _ctxA));
      final first = await claim(1);
      expect(first.command.operationId, _idHigh);
      // The create is in flight: the invite must not start yet.
      expect(await store.claim(now: 1, leaseId: 'worker'), isNull);
      await commit(first);
      expect((await claim(2)).command.operationId, _idLow);
    });

    test('rename also waits; a committed create adds no dependency', () async {
      await store.enqueue(_create(_idHigh, _ctxA));
      await store.enqueue(_rename(_idLow, _ctxA));
      expect(
        db.db
            .select('SELECT depends_on FROM shared_command_dependencies')
            .single['depends_on'],
        _idHigh,
      );
      await commit(await claim(1));
      await store.enqueue(_rename(_idMid, _ctxA));
      expect(
        db.db.select('SELECT * FROM shared_command_dependencies'),
        hasLength(1),
      );
    });

    test('a command for another context is not held back', () async {
      await store.enqueue(_create(_idHigh, _ctxA));
      await store.enqueue(_rename(_idLow, _ctxB));
      await claim(1); // the create
      expect((await claim(1)).command.operationId, _idLow);
    });

    test('a rejected create rejects what was waiting on it', () async {
      await store.enqueue(_create(_idHigh, _ctxA));
      await store.enqueue(_invite(_idLow, _ctxA));
      await store.fail(await claim(1), statusCode: 422, now: 1);
      expect(store.operation(_idHigh)!.state, SharedCommandState.rejected);
      final dependent = store.operation(_idLow)!;
      expect(dependent.state, SharedCommandState.rejected);
      expect(dependent.errorCode, 'dependency_rejected');
      expect(store.waitingCount, 0);
    });
  });

  group('failure classification (SRV-18)', () {
    // The invite was queued by an older build (no dependency), before its
    // create, and so is the first thing the worker sends.
    Future<SharedCommandClaim> inviteAheadOfCreate() async {
      await store.enqueue(_invite(_idLow, _ctxA));
      await store.enqueue(_create(_idHigh, _ctxA));
      return claim(1);
    }

    test(
      '403 context_not_authorized retries while the create is unconfirmed',
      () async {
        final c = await inviteAheadOfCreate();
        await store.fail(
          c,
          statusCode: 403,
          serverCode: 'context_not_authorized',
          now: 1,
        );
        final op = store.operation(_idLow)!;
        expect(op.state, SharedCommandState.retry);
        expect(op.errorCode, 'http_403');
        expect(store.attentionCount, 0);
      },
    );

    test('403 context_not_authorized is rejected once the create is '
        'committed', () async {
      await store.enqueue(_create(_idHigh, _ctxA));
      await commit(await claim(1));
      await store.enqueue(_invite(_idLow, _ctxA));
      await store.fail(
        await claim(2),
        statusCode: 403,
        serverCode: 'context_not_authorized',
        now: 2,
      );
      expect(store.operation(_idLow)!.state, SharedCommandState.rejected);
      expect(store.attentionCount, 1);
    });

    test('403 for a context with no create at all stays permanent', () async {
      await store.enqueue(_invite(_idLow, _ctxA));
      await store.fail(
        await claim(1),
        statusCode: 403,
        serverCode: 'context_not_authorized',
        now: 1,
      );
      expect(store.operation(_idLow)!.state, SharedCommandState.rejected);
    });

    test(
      'a different 403 code is permanent even with a pending create',
      () async {
        final c = await inviteAheadOfCreate();
        await store.fail(c, statusCode: 403, serverCode: 'not_owner', now: 1);
        expect(store.operation(_idLow)!.state, SharedCommandState.rejected);
      },
    );

    test(
      '409 retryable and 429 retry; plain 409 conflicts; 400 rejects',
      () async {
        await store.enqueue(_rename(_idLow, _ctxA));
        await store.fail(
          await claim(1),
          statusCode: 409,
          retryable: true,
          now: 1,
        );
        expect(store.operation(_idLow)!.state, SharedCommandState.retry);
        await store.fail(await claim(999999), statusCode: 429, now: 999999);
        expect(store.operation(_idLow)!.state, SharedCommandState.retry);
        await store.fail(await claim(9999999), statusCode: 409, now: 9999999);
        expect(store.operation(_idLow)!.state, SharedCommandState.conflict);
        await store.requeue(_idLow);
        await store.fail(await claim(0), statusCode: 400, now: 0);
        expect(store.operation(_idLow)!.state, SharedCommandState.rejected);
      },
    );

    test(
      '429 respects Retry-After when it is longer than the backoff',
      () async {
        await store.enqueue(_rename(_idLow, _ctxA));
        await store.fail(
          await claim(1000),
          statusCode: 429,
          retryAfter: const Duration(minutes: 20),
          now: 1000,
        );
        final next = db.db
            .select('SELECT next_attempt FROM shared_commands')
            .single['next_attempt'];
        expect(next, 1000 + const Duration(minutes: 20).inMilliseconds);
      },
    );

    test('without Retry-After the 5s doubling backoff is unchanged', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      await store.fail(await claim(1000), statusCode: 503, now: 1000);
      expect(
        db.db
            .select('SELECT next_attempt FROM shared_commands')
            .single['next_attempt'],
        1000 + 10000,
      );
    });

    test(
      'server errors stop at the attempt cap with a surfaced error',
      () async {
        await store.enqueue(_rename(_idLow, _ctxA));
        var now = 0;
        for (var i = 0; i < sharedMaxAttempts; i++) {
          expect(
            store.operation(_idLow)!.state,
            isNot(SharedCommandState.rejected),
          );
          now += 1000000;
          await store.fail(await claim(now), statusCode: 503, now: now);
        }
        final op = store.operation(_idLow)!;
        expect(op.state, SharedCommandState.rejected);
        expect(op.errorCode, startsWith('retry_limit'));
        expect(store.attentionCount, 1);
      },
    );

    test('being offline never burns the cap', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      var now = 0;
      for (var i = 0; i < sharedMaxAttempts + 5; i++) {
        now += 1000000;
        await store.fail(await claim(now), now: now);
      }
      expect(store.operation(_idLow)!.state, SharedCommandState.retry);
    });
  });

  group('reconnect (X-02)', () {
    test('resetBackoff makes waiting rows claimable straight away', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      await store.enqueue(_rename(_idMid, _ctxB));
      await store.fail(await claim(1000), now: 1000); // network down
      await store.resetBackoff();
      final rows = db.db.select(
        "SELECT next_attempt FROM shared_commands WHERE state IN ('retry','pending')",
      );
      expect(rows.every((r) => r['next_attempt'] == 0), isTrue);
    });

    test('resetBackoff leaves refused and committed rows alone', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      await store.fail(await claim(1), statusCode: 400, now: 1);
      await store.resetBackoff();
      expect(store.operation(_idLow)!.state, SharedCommandState.rejected);
      expect(await store.claim(now: 1, leaseId: 'worker'), isNull);
    });

    test('a row in backoff is sent after resetBackoff, not before', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      await store.fail(await claim(1000), now: 1000);
      expect(await store.claim(now: 1001, leaseId: 'worker'), isNull);
      await store.resetBackoff();
      expect((await claim(1001)).command.operationId, _idLow);
    });
  });

  group('needs attention (X-01)', () {
    test('refused commands are listed; syncing ones are not', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      await store.enqueue(_rename(_idMid, _ctxB));
      await store.fail(await claim(1), statusCode: 422, now: 1);
      expect(store.attentionCount, 1);
      final items = store.readAttention();
      expect(items, hasLength(1));
      expect(items.single.command.operationId, _idLow);
      expect(items.single.state, SharedCommandState.rejected);
    });

    test('Retry re-queues with a fresh budget and the same bytes', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      final hash = store.operation(_idLow)!.command.requestHash;
      await store.fail(await claim(1), statusCode: 422, now: 1);
      expect(await store.requeue(_idLow), isTrue);
      final op = store.operation(_idLow)!;
      expect(op.state, SharedCommandState.pending);
      expect(op.attempts, 0);
      expect(op.errorCode, isNull);
      expect(op.command.requestHash, hash);
      expect(store.attentionCount, 0);
      expect((await claim(2)).command.operationId, _idLow);
    });

    test('Retry only applies to refused commands', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      expect(await store.requeue(_idLow), isFalse);
      expect(await store.requeue(_idMid), isFalse);
    });

    test('Discard removes the command and its overlay', () async {
      await store.enqueue(
        _rename(_idLow, _ctxA),
        provisional: {'title': 'Pending'},
      );
      await store.fail(await claim(1), statusCode: 422, now: 1);
      expect(await store.discard(_idLow), isTrue);
      expect(store.operation(_idLow), isNull);
      expect(store.provisional(_idLow), isNull);
      expect(store.attentionCount, 0);
      expect(await store.discard(_idLow), isFalse);
    });

    test('Discard refuses a command that is still on its way', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      expect(await store.discard(_idLow), isFalse);
      expect(store.operation(_idLow), isNotNull);
    });

    test('a refused create is one item; Retry and Discard take its '
        'dependents along', () async {
      await store.enqueue(_create(_idHigh, _ctxA));
      await store.enqueue(_invite(_idLow, _ctxA));
      await store.fail(await claim(1), statusCode: 422, now: 1);
      expect(store.attentionCount, 1);
      expect(store.readAttention().single.command.operationId, _idHigh);
      expect(await store.requeue(_idHigh), isTrue);
      expect(store.operation(_idLow)!.state, SharedCommandState.pending);
      final again = await claim(2);
      expect(again.command.operationId, _idHigh);
      // The invite is held back again while the create is in flight.
      expect(await store.claim(now: 2, leaseId: 'worker'), isNull);
    });

    test(
      'Discard of a refused create removes the waiting invite too',
      () async {
        await store.enqueue(_create(_idHigh, _ctxA));
        await store.enqueue(_invite(_idLow, _ctxA));
        await store.fail(await claim(1), statusCode: 422, now: 1);
        expect(await store.discard(_idHigh), isTrue);
        expect(store.operation(_idHigh), isNull);
        expect(store.operation(_idLow), isNull);
      },
    );

    test('another account never sees these rows', () async {
      await store.enqueue(_rename(_idLow, _ctxA));
      await store.fail(await claim(1), statusCode: 422, now: 1);
      final other = SharedExpensesStore(db, namespace: fixtures.accountB);
      expect(other.attentionCount, 0);
      expect(other.readAttention(), isEmpty);
      expect(await other.discard(_idLow), isFalse);
    });
  });
}
