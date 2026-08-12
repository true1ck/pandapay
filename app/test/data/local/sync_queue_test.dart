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
    expect(pending, hasLength(1), reason: '20 keystrokes must not be 20 pushes');
    expect(pending.single.payload['note'], 'draft 20');
    expect(pending.single.fieldClocks['note'], 1020, reason: 'clock tracks the LATEST edit');
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
    expect(pending.single.payload, {'note': 'dinner', 'category_id': 'cat-food'});
    // Per-field clocks, not one clock for the change — this is what lets the
    // server accept the newer category while rejecting an older note.
    expect(pending.single.fieldClocks, {'note': 1000, 'category_id': 2000});
  });

  test('different rows stay separate changes', () {
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {'note': 'a'});
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-2', fields: {'note': 'b'});
    expect(queue.pending(), hasLength(2));
  });

  test('a delete supersedes any queued edits to the same row', () {
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {'note': 'a'});
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {'merchant_name': 'b'});
    queue.enqueueDelete(entity: 'transactions', entityId: 'txn-1');

    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.op, 'delete', reason: 'no point pushing edits to a row being removed');
  });

  test('an empty field map queues nothing', () {
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {});
    expect(queue.pending(), isEmpty);
  });

  test('a change is dropped after maxAttempts so it cannot block the queue', () {
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {'note': 'a'});
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-2', fields: {'note': 'b'});
    final blocker = queue.pending().first.clientSeq;

    // The uncomfortable trade, asserted explicitly: a change the server keeps
    // refusing is eventually discarded, because leaving it at the head of the
    // queue would stop every later edit from ever syncing.
    for (var i = 0; i < SyncQueue.maxAttempts; i++) {
      queue.recordFailure(blocker, 'server said no');
    }

    final remaining = queue.pending();
    expect(remaining, hasLength(1));
    expect(remaining.single.entityId, 'txn-2', reason: 'the other change must survive');
  });

  test('a failure below the threshold keeps the change for retry', () {
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {'note': 'a'});
    queue.recordFailure(queue.pending().first.clientSeq, 'offline');
    expect(queue.pending(), hasLength(1), reason: 'a transient failure must not discard an edit');
  });

  test('removing an applied change leaves the rest', () {
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {'note': 'a'});
    queue.enqueueUpdate(entity: 'user_cards', entityId: 'card-1', fields: {'nickname': 'Blue'});
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
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {'note': 'a'});
    queue.deviceId = 'device-abc';
    queue.lastServerSeq = 42;

    queue.clear();

    expect(queue.pending(), isEmpty);
    expect(queue.deviceId, isNull);
    expect(queue.lastServerSeq, 0);
  });

  test('pendingCount matches what pending() returns', () {
    expect(queue.pendingCount, 0);
    queue.enqueueUpdate(entity: 'transactions', entityId: 'txn-1', fields: {'note': 'a'});
    queue.enqueueUpdate(entity: 'user_cards', entityId: 'card-1', fields: {'nickname': 'Blue'});
    expect(queue.pendingCount, 2);
  });
}
