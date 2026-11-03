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
}
