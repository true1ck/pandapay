import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/server_clock.dart';

/// WP-C1 (decision D9): field clocks come from the server-time-adjusted clock
/// when an offset is known, and are byte-for-byte the old behaviour when not.
void main() {
  late AppDatabase appDb;
  final device = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  setUp(() => appDb = openInMemoryForTesting());
  tearDown(() => appDb.close());

  test('with no offset the default clock is the device clock', () {
    final clock = ServerClock(deviceNow: () => device);
    final queue = SyncQueue(appDb, serverClock: clock);

    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    queue.enqueueInsert(
      entity: 'user_categories',
      entityId: 'cat-1',
      fields: {'name': 'x'},
    );

    final pending = queue.pending();
    expect(pending[0].fieldClocks, {'note': device.millisecondsSinceEpoch});
    expect(pending[1].fieldClocks, {'name': device.millisecondsSinceEpoch});
  });

  test('a known offset shifts update, insert, coalesce and delete clocks', () {
    final clock = ServerClock(deviceNow: () => device)
      ..observeServerTime(device.add(const Duration(minutes: 3)));
    final queue = SyncQueue(appDb, serverClock: clock);
    final shifted = device
        .add(const Duration(minutes: 3))
        .millisecondsSinceEpoch;

    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    expect(queue.pending().single.fieldClocks, {'note': shifted});

    // Coalescing bumps the clock with the same adjusted source.
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'b', 'category': 'food'},
    );
    final coalesced = queue.pending().single;
    expect(coalesced.fieldClocks, {'note': shifted, 'category': shifted});

    queue.enqueueInsert(
      entity: 'user_categories',
      entityId: 'cat-1',
      fields: {'name': 'x'},
    );
    queue.enqueueDelete(entity: 'user_cards', entityId: 'card-1');
    final rows = appDb.db.select(
      'SELECT created_at FROM sync_pending_changes ORDER BY client_seq',
    );
    expect(rows.map((r) => r['created_at']), everyElement(shifted));
  });

  test('an explicit at: always wins over the server clock', () {
    final clock = ServerClock(deviceNow: () => device)
      ..observeServerTime(device.add(const Duration(days: 2)));
    final queue = SyncQueue(appDb, serverClock: clock);
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
      at: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    expect(queue.pending().single.fieldClocks, {'note': 1000});
  });

  test('default constructor uses the process-wide ServerClock', () {
    addTearDown(ServerClock.instance.reset);
    ServerClock.instance.reset();
    final before = DateTime.now().millisecondsSinceEpoch;
    final queue = SyncQueue(appDb);
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 'txn-1',
      fields: {'note': 'a'},
    );
    final clockMs = queue.pending().single.fieldClocks['note'] as int;
    expect(
      clockMs,
      inInclusiveRange(before, DateTime.now().millisecondsSinceEpoch),
    );
  });
}
