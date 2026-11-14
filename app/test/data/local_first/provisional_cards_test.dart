import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';

/// H3-1: a sync edit for a card that only exists on the phone must not reach
/// /sync/push before the add; it is held without counting an attempt.
void main() {
  late AppDatabase db;
  late SyncQueue queue;
  late CommandOutbox commands;
  setUp(() {
    db = openInMemoryForTesting();
    FinancialStore(db);
    queue = SyncQueue(db, namespace: 'a');
    commands = CommandOutbox(db, namespace: 'a');
  });
  tearDown(() => db.close());

  test('edits for a card with a queued add are held, others are sent', () {
    commands.enqueue(kind: 'add_card', target: 'prov-1', payload: {'id': 'prov-1'});
    queue.enqueueUpdate(entity: 'user_cards', entityId: 'prov-1', fields: {'sort_order': 0});
    queue.enqueueUpdate(entity: 'user_cards', entityId: 'srv-1', fields: {'sort_order': 1});
    expect(queue.pending().map((c) => c.entityId), ['srv-1']);
    // Nothing was counted against the held row.
    expect(
      db.db.select('SELECT attempts FROM sync_pending_changes WHERE entity_id=?', ['prov-1']).single['attempts'],
      0,
    );
  });

  test('edits are released once the add is delivered', () {
    commands.enqueue(kind: 'add_card', target: 'prov-1');
    queue.enqueueUpdate(entity: 'user_cards', entityId: 'prov-1', fields: {'is_default': true});
    expect(queue.pending(), isEmpty);
    db.db.execute("DELETE FROM command_outbox WHERE target='prov-1'");
    expect(queue.pending(), hasLength(1));
  });

  test('a pending=1 card row also holds edits', () {
    db.db.execute(
      "INSERT INTO financial_entities(namespace, entity, id, payload, observed_at, pending) "
      "VALUES ('a','cards','prov-2','{}',1,1)",
    );
    queue.enqueueUpdate(entity: 'user_cards', entityId: 'prov-2', fields: {'sort_order': 0});
    expect(queue.pending(), isEmpty);
  });
}
