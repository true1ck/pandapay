import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/storage/outbox_store.dart';
import 'package:pandapay/features/sms_v2/storage/schema.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('retry backoff, payload acknowledgement and namespaces are durable', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    SmsV2Schema.ensure(db);
    final queue = OutboxStore(db, namespace: 'a');
    final other = OutboxStore(db, namespace: 'b');
    final now = DateTime.utc(2026, 11);
    queue.enqueue('event', 'one', {'version': 1});
    other.enqueue('event', 'one', {'version': 3});
    final sent = queue.due(now).single;
    queue.retry(sent, now);
    expect(queue.due(now.add(const Duration(seconds: 29))), isEmpty);
    expect(queue.due(now.add(const Duration(seconds: 30))).single.attempts, 1);
    queue.enqueue('event', 'one', {'version': 2});
    expect(queue.acknowledge(sent), isFalse);
    expect(queue.due(now).single.json['version'], 2);
    expect(queue.acknowledge(queue.due(now).single), isTrue);
    expect(other.due(now).single.json['version'], 3);
  });

  test('resetBackoff makes every waiting record due and keeps attempts', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    SmsV2Schema.ensure(db);
    final queue = OutboxStore(db, namespace: 'a');
    final other = OutboxStore(db, namespace: 'b');
    final now = DateTime.utc(2026, 11);
    final far = DateTime.utc(2100);
    queue.enqueue('event', 'one', {'version': 1});
    queue.enqueue('event', 'two', {'version': 1});
    other.enqueue('event', 'one', {'version': 1});
    for (final id in ['event:one', 'event:two']) {
      for (var i = 0; i < 3; i++) {
        queue.retry(queue.due(far).firstWhere((r) => r.id == id), now);
      }
    }
    other.retry(other.due(now).single, now);
    expect(queue.due(now), isEmpty);
    expect(queue.resetBackoff(), 2);
    final due = queue.due(now);
    expect(due, hasLength(2));
    expect(due.every((r) => r.attempts == 3), isTrue);
    expect(other.due(now), isEmpty, reason: 'another account is untouched');
  });

  test('restarting an entry resets it even when the payload is identical', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    SmsV2Schema.ensure(db);
    final queue = OutboxStore(db, namespace: 'a');
    final now = DateTime.utc(2026, 11);
    queue.enqueue('source', 'S', {'k': 1});
    for (var i = 0; i < 6; i++) {
      queue.retry(queue.due(DateTime.utc(2100)).single, now);
    }
    // Plain enqueue of the same bytes leaves the back-off alone.
    queue.enqueue('source', 'S', {'k': 1});
    expect(queue.due(now), isEmpty);
    queue.enqueue('source', 'S', {'k': 1}, restart: true);
    expect(queue.due(now).single.attempts, 0);
  });
}
