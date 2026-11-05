import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

Commitment _bill(String id, {String title = 'Rent'}) => Commitment(
  id: id,
  title: title,
  category: CommitmentCategory.rent,
  dueOn: DateTime(2026, 12, 1),
  cadence: CommitmentCadence.monthly,
  source: CommitmentSource.manual,
  isUserConfirmed: true,
);

void main() {
  late AppDatabase db;
  late SyncQueue queue;
  late CommitmentsRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    queue = SyncQueue(db, namespace: 'user:a');
    repository = CommitmentsRepository(
      namespace: 'user:a',
      loadDatabase: () async => db,
      loadSyncQueue: () async => queue,
    );
  });
  tearDown(() => db.close());

  test('the server id is stable and is a UUID', () {
    final id = commitmentSyncId('manual-1762345678901');
    expect(id, commitmentSyncId('manual-1762345678901'));
    expect(id, isNot(commitmentSyncId('manual-2')));
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(id),
      isTrue,
    );
  });

  test('a new bill is queued as an insert with the whole document', () async {
    await repository.save(_bill('manual-1'));

    final pending = queue.pending();
    expect(pending, hasLength(1));
    expect(pending.single.entity, 'user_commitments');
    expect(pending.single.op, 'insert');
    expect(pending.single.entityId, commitmentSyncId('manual-1'));
    expect(pending.single.payload['id'], 'manual-1');
    expect(pending.single.payload['title'], 'Rent');
  });

  test(
    'an edited bill is queued as an update, an unchanged one is not',
    () async {
      await repository.save(_bill('manual-1'));
      queue.remove(queue.pending().single.clientSeq);

      await repository.save(_bill('manual-1'));
      expect(queue.pending(), isEmpty);

      await repository.save(_bill('manual-1', title: 'Rent (new flat)'));
      final pending = queue.pending();
      expect(pending, hasLength(1));
      expect(pending.single.op, 'update');
      expect(pending.single.payload['title'], 'Rent (new flat)');
      expect(pending.single.payload['id'], 'manual-1');
    },
  );

  test('marking a bill paid is queued as an update', () async {
    await repository.save(_bill('manual-1'));
    queue.remove(queue.pending().single.clientSeq);

    await repository.markAsPaid('manual-1', paidOn: DateTime(2026, 12, 2));

    final pending = queue.pending();
    expect(pending.single.op, 'update');
    expect(pending.single.payload['paid_on'], isNotNull);
  });

  test('deleting a bill is queued as a delete', () async {
    await repository.save(_bill('manual-1'));
    queue.remove(queue.pending().single.clientSeq);

    await repository.delete('manual-1');

    final pending = queue.pending();
    expect(pending.single.op, 'delete');
    expect(pending.single.entityId, commitmentSyncId('manual-1'));
  });

  test(
    'changes pulled from another phone are applied without being re-queued',
    () async {
      await repository.save(_bill('manual-2', title: 'Local'));
      queue.remove(queue.pending().single.clientSeq);

      await repository.applyRemote([
        {
          'entity': 'user_commitments',
          'entity_id': commitmentSyncId('manual-1'),
          'op': 'insert',
          'payload': _bill('manual-1', title: 'From phone B').toJson(),
        },
        {
          'entity': 'user_commitments',
          'entity_id': commitmentSyncId('manual-2'),
          'op': 'update',
          'payload': _bill('manual-2', title: 'Edited on B').toJson(),
        },
      ]);

      final titles = {
        for (final c in await repository.fetchAll()) c.id: c.title,
      };
      expect(titles, {'manual-1': 'From phone B', 'manual-2': 'Edited on B'});

      await repository.applyRemote([
        {
          'entity': 'user_commitments',
          'entity_id': commitmentSyncId('manual-1'),
          'op': 'delete',
          'payload': <String, dynamic>{},
        },
      ]);
      expect((await repository.fetchAll()).map((c) => c.id), ['manual-2']);
      expect(queue.pending(), isEmpty);
    },
  );

  test('an unreadable pulled document is skipped, not fatal', () async {
    await repository.applyRemote([
      {
        'entity': 'user_commitments',
        'entity_id': commitmentSyncId('manual-9'),
        'op': 'insert',
        'payload': {'id': 'manual-9'},
      },
      {
        'entity': 'user_commitments',
        'entity_id': commitmentSyncId('manual-1'),
        'op': 'insert',
        'payload': _bill('manual-1').toJson(),
      },
    ]);
    expect((await repository.fetchAll()).map((c) => c.id), ['manual-1']);
  });
}
