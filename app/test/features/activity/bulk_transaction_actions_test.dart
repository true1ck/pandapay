import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart' show OutboxCommand;
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sync_queue.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/bulk_transaction_actions.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _row(String id, {int pipeline = 1}) => TransactionEntry(
  id: id,
  amount: Money.fromRupees(10),
  occurredAt: DateTime(2026, 11, 1),
  entryKind: TxnEntryKind.spend,
  source: 'manual',
  status: 'active',
  pipelineVersion: pipeline,
);

void main() {
  const ns = 'user:synthetic';
  late AppDatabase db;
  late FinancialStore store;
  late TransactionOutboxRepository outbox;
  late BulkTransactionActions bulk;
  final smsCategory = <String>[];
  final hidden = <String>[];

  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    outbox = TransactionOutboxRepository(db, namespace: ns, financialStore: store);
    smsCategory.clear();
    hidden.clear();
    bulk = BulkTransactionActions(
      namespace: ns,
      store: store,
      queue: SyncQueue(db, namespace: ns),
      commands: CommandOutbox(db, namespace: ns),
      outbox: outbox,
      smsSetCategory: (rows, slug) => smsCategory.add(
        '$slug:${rows.map((e) => e.id).join(',')}',
      ),
      smsHide: (row) => hidden.add(row.id),
    );
  });
  tearDown(() => db.close());

  List<Map<String, Object?>> pending() => [
    for (final r in db.db.select(
      'SELECT entity_id, payload_json FROM sync_pending_changes',
    ))
      {
        'id': r['entity_id'],
        ...jsonDecode(r['payload_json'] as String) as Map<String, Object?>,
      },
  ];

  test('command kind constant matches the real outbox command', () {
    expect(bulkIgnoreCommandKind, OutboxCommand.ignoreTransaction);
  });

  test('mixed selection offline: category goes to the right place per id kind', () async {
    await outbox.enqueue(
      amount: Money.fromRupees(5),
      clientMutationId: 'm1',
      categoryId: 'old',
    );
    final r = await bulk.setCategory(
      [_row('srv-1'), _row('v2:abc', pipeline: 2), _row('local-outbox:m1')],
      'dining',
      slug: 'dining',
    );
    expect(r.done, 3);
    expect(r.failed, isEmpty);
    expect(smsCategory, ['dining:v2:abc']);
    expect(pending().single['id'], 'srv-1');
    expect(pending().single['category_id'], 'dining');
    expect((await outbox.pending()).single.categoryId, 'dining');
  });

  test('a failing row is reported and the others still apply', () async {
    final r = await bulk.setCategory(
      [_row('local-outbox:gone'), _row('srv-2')],
      'dining',
    );
    expect(r.done, 1);
    expect(r.failed, ['local-outbox:gone']);
    expect(pending().single['id'], 'srv-2');
  });

  test('assign card edits queued rows, queues server rows, skips SMS rows', () async {
    await outbox.enqueue(amount: Money.fromRupees(5), clientMutationId: 'm2');
    final r = await bulk.assignCard(
      [_row('srv-3'), _row('v2:x', pipeline: 2), _row('local-outbox:m2')],
      'card-9',
    );
    expect(r.done, 2);
    expect(r.skipped, 1);
    expect(pending().single['user_card_id'], 'card-9');
    expect((await outbox.pending()).single.userCardId, 'card-9');
  });

  test('delete: v2 hidden locally, queued row cancelled, server row gets an ignore command', () async {
    await outbox.enqueue(amount: Money.fromRupees(5), clientMutationId: 'm3');
    final r = await bulk.delete(
      [_row('srv-4'), _row('v2:y', pipeline: 2), _row('local-outbox:m3')],
    );
    expect(r.done, 3);
    expect(hidden, ['v2:y']);
    expect(await outbox.pending(), isEmpty);
    final commands = db.db.select('SELECT kind, target, payload_json FROM command_outbox');
    expect(commands, hasLength(1));
    expect(commands.single['kind'], 'ignore_transaction');
    expect(commands.single['target'], 'srv-4');
    expect(jsonDecode(commands.single['payload_json'] as String)['reason'], 'manual');
  });
}
