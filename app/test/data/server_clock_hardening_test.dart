import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/server_clock.dart';

void main() {
  late DateTime device;
  ServerClock make() => ServerClock(deviceNow: () => device);
  setUp(() => device = DateTime.utc(2026, 11, 13, 10));

  test('one poisoned sample among good ones does not move the clock', () {
    final clock = make();
    for (var i = 0; i < 3; i++) {
      clock.observeServerTime(device.add(const Duration(seconds: 30)));
    }
    clock.observeServerTime(device.add(const Duration(hours: 20)));
    expect(clock.offset, const Duration(seconds: 30));
  });

  test('offset is bounded to one day', () {
    final clock = make();
    clock.observeServerTime(device.add(const Duration(days: 7)));
    expect(clock.offset, const Duration(days: 1));
  });

  test('samples older than two minutes are forgotten', () {
    final clock = make();
    clock.observeServerTime(device.add(const Duration(minutes: 5)));
    clock.observeServerTime(device.add(const Duration(minutes: 5)));
    device = device.add(const Duration(minutes: 3));
    clock.observeServerTime(device.add(const Duration(minutes: 1)));
    expect(clock.offset, const Duration(minutes: 1));
  });

  test('now() never goes backwards', () {
    final clock = make();
    clock.observeServerTime(device.add(const Duration(hours: 2)));
    final high = clock.now();
    clock.reset();
    clock.observeServerTime(device.subtract(const Duration(hours: 2)));
    expect(clock.now().isBefore(high), isFalse);
  });

  test('a restart cannot stamp an edit older than the last one', () {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final ahead = ServerClock(deviceNow: () => device)
      ..observeServerTime(device.add(const Duration(hours: 3)));
    final first = SyncQueue(db, namespace: 'user:a', serverClock: ahead);
    first.enqueueUpdate(entity: 'transactions', entityId: 't1', fields: {'note': 'a'});
    final stampedFirst = db.db
        .select('SELECT created_at FROM sync_pending_changes')
        .single['created_at'] as int;

    // New process: fresh clock with no offset learnt (cold start offline).
    final cold = ServerClock(deviceNow: () => device);
    final second = SyncQueue(db, namespace: 'user:a', serverClock: cold);
    second.enqueueUpdate(entity: 'transactions', entityId: 't2', fields: {'note': 'b'});
    final stampedSecond = db.db
        .select("SELECT created_at FROM sync_pending_changes WHERE entity_id='t2'")
        .single['created_at'] as int;
    expect(stampedSecond, greaterThanOrEqualTo(stampedFirst));
  });
}
