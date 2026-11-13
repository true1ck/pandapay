import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sync_queue.dart';

/// Plan Phase 4. The queue's job is to answer "what have I changed that the
/// server hasn't seen", and the two things that can go wrong are both silent:
/// coalescing that loses a field, and a permanently-rejected change that
/// blocks everything queued behind it forever.
void main() {
  late AppDatabase appDb;
  late SyncQueue queue;

  setUp(() {
    appDb = openInMemoryForTesting();
    queue = SyncQueue(appDb);
  });
  tearDown(() => appDb.close());

  test('a single edit is queued with a clock for each field', () {
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'dinner'},
      at: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.entity, 'transactions');
    expect(pending.single.op, 'update');
    expect(pending.single.payload, {'note': 'dinner'});
    expect(pending.single.fieldClocks, {'note': 1000});
  });

  test('repeated edits to the same field coalesce to the latest value', () {
    // A user retyping a note produces one edit per keystroke. Queueing each
    // would push dozens of changes describing the same final state, and each
    // intermediate value would get its own conflict evaluation.
    for (var i = 1; i <= 20; i++) {
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'txn-1',
        fields: {'note': 'draft $i'},
        at: DateTime.fromMillisecondsSinceEpoch(1000 + i),
      );
    }

    final pending = queue.pending();
    expect(
      pending,
      hasLength(1),
      reason: '20 keystrokes must not be 20 pushes',
    );
    expect(pending.single.payload['note'], 'draft 20');
    expect(
      pending.single.fieldClocks['note'],
      1020,
      reason: 'clock tracks the LATEST edit',
    );
  });

  test('edits to different fields of the same row merge into one change', () {
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'dinner'},
      at: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'category_id': 'cat-food'},
      at: DateTime.fromMillisecondsSinceEpoch(2000),
    );

    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.payload, {
      'note': 'dinner',
      'category_id': 'cat-food',
    });
    // Per-field clocks, not one clock for the change — this is what lets the
    // server accept the newer category while rejecting an older note.
    expect(pending.single.fieldClocks, {'note': 1000, 'category_id': 2000});
  });

  test('different rows stay separate changes', () {
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-2',
      fields: {'note': 'b'},
    );
    expect(queue.pending(), hasLength(2));
  });

  test('a delete supersedes any queued edits to the same row', () {
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'merchant_name': 'b'},
    );
    queue.enqueueDelete(entity: 'transactions', entityId: 'txn-1');

    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(
      pending.single.op,
      'delete',
      reason: 'no point pushing edits to a row being removed',
    );
  });

  test('an empty field map queues nothing', () {
    expect(
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'txn-1',
        fields: {},
      ),
      0,
    );
    expect(queue.pending(), isEmpty);
  });

  test(
    'a repeatedly rejected change is retained without blocking other work',
    () {
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'txn-1',
        fields: {'note': 'a'},
      );
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'txn-2',
        fields: {'note': 'b'},
      );
      final blocker = queue.pending().first.clientSeq;

      // The uncomfortable trade, asserted explicitly: a change the server keeps
      // refusing is eventually discarded, because leaving it at the head of the
      // queue would stop every later edit from ever syncing.
      for (var i = 0; i < SyncQueue.maxAttempts; i++) {
        queue.recordFailure(blocker, 'server said no');
      }

      final remaining = queue.pending();
      expect(remaining, hasLength(1));
      expect(
        remaining.single.entityId,
        'txn-2',
        reason: 'the other change must survive',
      );
      expect(
        queue.pendingCount,
        2,
        reason: 'the rejected edit remains saved for correction',
      );
    },
  );

  test('a failure below the threshold keeps the change for retry', () {
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    queue.recordFailure(queue.pending().first.clientSeq, 'offline');
    expect(
      queue.pending(),
      hasLength(1),
      reason: 'a transient failure must not discard an edit',
    );
  });

  test('removing an applied change leaves the rest', () {
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    queue.enqueueUpdate(
      entity: 'user_cards',
      entityId: 'card-1',
      fields: {'nickname': 'Blue'},
    );
    queue.remove(queue.pending().first.clientSeq);

    expect(queue.pending(), hasLength(1));
    expect(queue.pending().single.entity, 'user_cards');
  });

  test('device id and cursor survive being read back', () {
    expect(queue.deviceId, isNull);
    expect(queue.lastServerSeq, 0);

    queue.deviceId = 'device-abc';
    queue.lastServerSeq = 42;

    expect(queue.deviceId, 'device-abc');
    expect(queue.lastServerSeq, 42);
  });

  test('clear() wipes the queue and the cursor on sign-out', () {
    // The queue belongs to one account. Carrying it into the next sign-in on
    // the same device would push one user's edits under another's token.
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    queue.deviceId = 'device-abc';
    queue.lastServerSeq = 42;

    queue.clear();

    expect(queue.pending(), isEmpty);
    expect(queue.deviceId, isNull);
    expect(queue.lastServerSeq, 0);
  });

  test('pendingCount matches what pending() returns', () {
    expect(queue.pendingCount, 0);
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    queue.enqueueUpdate(
      entity: 'user_cards',
      entityId: 'card-1',
      fields: {'nickname': 'Blue'},
    );
    expect(queue.pendingCount, 2);
  });

  test(
    'editing during upload gets a new identity and survives the older acknowledgment',
    () {
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'txn',
        fields: {'note': 'first'},
      );
      final uploading = queue.pending();
      queue.claim(uploading);
      queue.enqueueUpdate(
        entity: 'transactions',
        entityId: 'txn',
        fields: {'note': 'second'},
      );
      final newer = queue.pending().single;
      expect(newer.clientSeq, isNot(uploading.single.clientSeq));
      queue.remove(uploading.single.clientSeq);
      expect(queue.pending().single.payload['note'], 'second');
    },
  );

  test('account queues and cursors remain isolated', () {
    final a = SyncQueue(appDb, namespace: 'user:a');
    final b = SyncQueue(appDb, namespace: 'user:b');
    a.enqueueUpdate(
      entity: 'transactions',
      entityId: 'id',
      fields: {'note': 'private'},
    );
    a.lastServerSeq = 10;
    expect(b.pending(), isEmpty);
    expect(b.lastServerSeq, 0);
  });

  group('applied changes (in_flight = 2)', () {
    int rows() =>
        appDb.db.select('SELECT COUNT(*) AS n FROM sync_pending_changes').single['n'] as int;

    void edit(String id) => queue.enqueueUpdate(
      entity: 'transactions',
      entityId: id,
      fields: {'note': 'x'},
    );

    test('markApplied takes a change out of pending and the count', () {
      edit('a');
      edit('b');
      final seq = queue.pending().first.clientSeq;
      queue.markApplied(seq);
      expect(queue.pending().map((c) => c.entityId), ['b']);
      expect(queue.pendingCount, 1);
      expect(rows(), 2, reason: 'still stored, so it keeps overlaying the row');
    });

    test('release never revives an applied change', () {
      edit('a');
      final changes = queue.pending();
      queue.claim(changes);
      queue.markApplied(changes.single.clientSeq);
      queue.release(changes);
      expect(queue.pending(), isEmpty);
      expect(queue.appliedEntities(), {'transactions'});
    });

    test('a restart returns claimed changes to the queue, applied ones stay',
        () {
      edit('claimed');
      edit('applied');
      final both = queue.pending();
      queue.claim(both);
      queue.markApplied(both.last.clientSeq);
      final restarted = SyncQueue(appDb);
      expect(restarted.pending().map((c) => c.entityId), ['claimed']);
      expect(restarted.appliedEntities(), {'transactions'});
    });

    test('purgeApplied removes only applied changes of those entities', () {
      edit('a');
      queue.enqueueUpdate(
        entity: 'user_cards',
        entityId: 'c',
        fields: {'nickname': 'n'},
      );
      queue.enqueueUpdate(
        entity: 'user_cards',
        entityId: 'd',
        fields: {'nickname': 'n'},
      );
      final all = queue.pending();
      queue.markApplied(all[0].clientSeq);
      queue.markApplied(all[1].clientSeq);
      queue.purgeApplied(['transactions']);
      expect(rows(), 2);
      expect(queue.appliedEntities(), {'user_cards'});
      // The unapplied card change is untouched either way.
      expect(queue.pending().map((c) => c.entityId), ['d']);
    });

    test('a new edit of the same row after applying is a separate change', () {
      edit('a');
      queue.markApplied(queue.pending().single.clientSeq);
      edit('a');
      expect(queue.pending(), hasLength(1));
      expect(rows(), 2);
    });
  });
}
