import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/queue_registry.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/features/sync_status/sync_retry.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

const _a = 'user:11111111-1111-4111-8111-111111111111';

/// The retry actions run against the real queues on an in-memory database:
/// "Retry" must put exactly the parked rows of the signed-in account back in
/// the queue (due now, fresh attempts) and leave everything else alone.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = openInMemoryForTesting();
    container = ProviderContainer(
      overrides: [
        cacheNamespaceProvider.overrideWithValue(_a),
        appDatabaseProvider.overrideWith((_) async => db),
        commandOutboxProvider.overrideWith(
          (_) async => CommandOutbox(db, namespace: _a),
        ),
        outboxRepositoryProvider.overrideWith(
          (_) async => TransactionOutboxRepository(db, namespace: _a),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  QueueCounts counts(String queue) =>
      QueueRegistry(db).countsFor(queue, _a);

  test('command outbox: parked commands go back to waiting', () async {
    final commands = CommandOutbox(db, namespace: _a);
    commands.enqueue(kind: 'ignore_transaction', target: 'one');
    commands.enqueue(kind: 'ignore_transaction', target: 'two');
    db.db.execute('UPDATE command_outbox SET parked = 1 WHERE target = ?', [
      'one',
    ]);
    expect(counts('command_outbox'), const QueueCounts(pending: 1, parked: 1));

    await container.read(syncRetryActionsProvider)['command_outbox']!();

    expect(counts('command_outbox'), const QueueCounts(pending: 2));
  });

  test('transaction outbox: parked entries go back to waiting', () async {
    final outbox = TransactionOutboxRepository(db, namespace: _a);
    await outbox.enqueue(
      userCardId: 'card',
      amount: Money.fromRupees(10),
      clientMutationId: 'm1',
    );
    await outbox.enqueue(
      userCardId: 'card',
      amount: Money.fromRupees(20),
      clientMutationId: 'm2',
    );
    db.db.execute(
      'UPDATE transaction_outbox_entries SET parked = 1, attempts = 3 '
      "WHERE client_mutation_id = 'm1'",
    );
    expect(
      counts('transaction_outbox_entries'),
      const QueueCounts(pending: 1, parked: 1),
    );

    await container.read(syncRetryActionsProvider)['transaction_outbox_entries']!();

    expect(counts('transaction_outbox_entries'), const QueueCounts(pending: 2));
    expect(
      db.db
          .select(
            'SELECT attempts FROM transaction_outbox_entries '
            "WHERE client_mutation_id = 'm1'",
          )
          .single['attempts'],
      0,
    );
  });

  test('edits: changes that ran out of attempts get a fresh budget', () async {
    final queue = SyncQueue(db, namespace: _a);
    final first = queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 't1',
      fields: {'note': 'a'},
    );
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 't2',
      fields: {'note': 'b'},
    );
    queue.reject(first, 'rejected');
    expect(
      counts('sync_pending_changes'),
      const QueueCounts(pending: 1, parked: 1),
    );

    await container.read(syncRetryActionsProvider)['sync_pending_changes']!();

    expect(counts('sync_pending_changes'), const QueueCounts(pending: 2));
  });

  test('edits: Discard drops only the refused ones', () async {
    final queue = SyncQueue(db, namespace: _a);
    final first = queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 't1',
      fields: {'note': 'a'},
    );
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: 't2',
      fields: {'note': 'b'},
    );
    queue.reject(first, 'rejected');

    await container.read(syncDiscardActionsProvider)['sync_pending_changes']!();

    expect(counts('sync_pending_changes'), const QueueCounts(pending: 1));
  });

  test('another account is never touched', () async {
    final other = CommandOutbox(db, namespace: 'user:other');
    other.enqueue(kind: 'ignore_transaction', target: 'x');
    db.db.execute('UPDATE command_outbox SET parked = 1');

    await container.read(syncRetryActionsProvider)['command_outbox']!();

    expect(
      QueueRegistry(db).countsFor('command_outbox', 'user:other'),
      const QueueCounts(parked: 1),
    );
  });

  test('only queues that can be retried have an action', () {
    final actions = container.read(syncRetryActionsProvider);
    expect(
      actions.keys,
      containsAll(<String>[
        'sync_pending_changes',
        'transaction_outbox_entries',
        'command_outbox',
        'transaction_tag_outbox',
        'foreign_payments_outbox',
      ]),
    );
    expect(actions.containsKey('v2_outbox'), isFalse);
    expect(actions.containsKey('sms_intake'), isFalse);
  });
}
