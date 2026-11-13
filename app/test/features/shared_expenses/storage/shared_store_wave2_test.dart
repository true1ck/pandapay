import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';

import 'shared_store_test.dart' as fixtures;

// WP-C8 wave 2: a command queued against a group created offline names the
// owner by a stand-in id; the create's receipt swaps in the server's id.
const _ctx = '33333333-3333-4333-8333-333333333333';
const _real = '99999999-9999-4999-8999-999999999999';
const _create = '44444444-4444-4444-8444-444444444444';
const _settle = '55555555-5555-4555-8555-555555555555';
const _other = '66666666-6666-4666-8666-666666666666';

void main() {
  test('stand-in owner id is swapped for the real one on create commit', () async {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final store = SharedExpensesStore(db, namespace: fixtures.accountA);
    final stand = sharedPendingOwnerMemberId(_ctx);
    expect(stand, isNot(_real));
    expect(sharedUuid(stand), isTrue);
    final create = SharedCommand(
      operationId: _create,
      kind: 'context.create',
      payload: {'contextId': _ctx, 'contextKind': 'group', 'name': 'Trip'},
    );
    final report = SharedCommand(
      operationId: _settle,
      kind: 'settlement.report',
      payload: {
        'contextId': _ctx,
        'settlementId': _other,
        'payerMemberId': stand,
        'receiverMemberId': _other,
        'amountMinor': '100',
        'currency': 'INR',
        'method': 'cash',
        'paidOn': '2026-11-04',
      },
    );
    await store.enqueue(create);
    await store.enqueue(report);
    final before = store.operation(_settle)!.command.requestHash;
    final claim = (await store.claim(now: 1, leaseId: 'w'))!;
    expect(claim.command.operationId, _create);
    await store.complete(
      claim,
      SharedOperationReceipt(
        operationId: _create,
        kind: 'context.create',
        requestHash: claim.command.requestHash,
        contextId: _ctx,
        result: {'status': 'created', 'contextId': _ctx, 'memberId': _real},
      ),
      const [],
    );
    final after = store.operation(_settle)!;
    expect(after.command.requestHash, isNot(before));
    expect(after.command.canonicalJson, contains(_real));
    expect(after.command.canonicalJson, isNot(contains(stand)));
    expect(after.state, SharedCommandState.pending);
    // Still waits for nothing and is claimable with its new bytes.
    final next = (await store.claim(now: 2, leaseId: 'w'))!;
    expect(next.command.operationId, _settle);
    expect(next.command.requestHash, after.command.requestHash);
  });
}
