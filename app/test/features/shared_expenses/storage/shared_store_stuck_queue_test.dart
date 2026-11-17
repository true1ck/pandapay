import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'shared_store_test.dart' as fixtures;

// "Syncing your latest changes" stayed on the Splits screen for good: the phone
// counted a saved change as waiting while nothing could ever send it, and said
// nothing about why. These cover each way a change ends up in that state.
const _op3 = '66666666-6666-4666-8666-666666666666';
const _gone = '77777777-7777-4777-8777-777777777777';

SharedCommand _member(String id, {String ctx = fixtures.contextId}) =>
    SharedCommand(
      operationId: id,
      kind: 'member.invite',
      payload: {
        'contextId': ctx,
        'memberId': '88888888-8888-4888-8888-888888888888',
        'displayName': 'boy',
      },
    );

void main() {
  late Directory temp;
  late AppDatabase db;
  late SharedExpensesStore store;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('shared-stuck-');
    db = AppDatabase.forTesting(sqlite3.open('${temp.path}/data.sqlite'));
    store = SharedExpensesStore(db, namespace: fixtures.accountA);
  });
  tearDown(() {
    db.close();
    temp.deleteSync(recursive: true);
  });

  int now() => DateTime.now().millisecondsSinceEpoch;

  /// A saved change waiting for an earlier one that has since vanished (never
  /// confirmed, no longer on this phone). The app's own paths do not make this
  /// state; the guard is for whatever a crash or an old build left behind.
  Future<void> _orphan(String id) async {
    await store.enqueue(fixtures.command(_gone));
    await store.enqueue(_member(id), dependsOn: [_gone]);
    db.db.execute(
      'DELETE FROM shared_commands WHERE namespace=? AND operation_id=?',
      [fixtures.accountA, _gone],
    );
  }

  test(
    'a change in a split this phone lost access to is not "syncing"',
    () async {
      await store.enqueue(_member(fixtures.op1));
      expect(store.waitingCount, 1);
      await store.revokeContext(fixtures.contextId);
      // Nothing will ever send it while access is gone ...
      expect(await store.claim(now: now(), leaseId: 'w'), isNull);
      // ... so it must not be counted as on its way.
      expect(store.waitingCount, 0);
      final why = store.waitingChanges(now: now());
      expect(why, isEmpty);
    },
  );

  test(
    'a change waiting for one that no longer exists is refused, not left waiting',
    () async {
      await _orphan(fixtures.op1);
      expect(await store.claim(now: now(), leaseId: 'w'), isNull);
      expect(
        store.waitingChanges(now: now()).single.reason,
        SharedWaitReason.earlierChange,
      );

      expect(await store.reconcileQueue(), 1);

      expect(store.waitingCount, 0);
      final refused = store.operation(fixtures.op1)!;
      expect(refused.state, SharedCommandState.rejected);
      expect(refused.errorCode, sharedDependencyMissing);
      // The person is told (it is in the list of changes that did not sync).
      expect(store.attentionCount, 1);
    },
  );

  test('a change waiting for one that was refused is refused with it', () async {
    await store.enqueue(fixtures.command(fixtures.op1));
    await store.enqueue(_member(fixtures.op2), dependsOn: [fixtures.op1]);
    // An older build refused the first without refusing what waited on it.
    db.db.execute(
      "UPDATE shared_commands SET state='rejected',error_code='http_403' WHERE namespace=? AND operation_id=?",
      [fixtures.accountA, fixtures.op1],
    );
    expect(store.waitingCount, 1);

    expect(await store.reconcileQueue(), 1);

    expect(store.waitingCount, 0);
    expect(store.operation(fixtures.op2)!.errorCode, sharedDependencyRejected);
    // Folded into the first one: one problem for the person, not two.
    expect(store.attentionCount, 1);
  });

  test(
    'refusing a missing dependency refuses what waited on that too',
    () async {
      await _orphan(fixtures.op1);
      await store.enqueue(_member(_op3), dependsOn: [fixtures.op1]);
      expect(await store.reconcileQueue(), 2);
      expect(store.waitingCount, 0);
      expect(store.operation(fixtures.op1)!.errorCode, sharedDependencyMissing);
      expect(store.operation(_op3)!.errorCode, sharedDependencyRejected);
      expect(store.attentionCount, 1);
    },
  );

  test('a change waiting for one still on its way is left alone', () async {
    await store.enqueue(fixtures.command(fixtures.op1));
    await store.enqueue(_member(fixtures.op2), dependsOn: [fixtures.op1]);
    expect(await store.reconcileQueue(), 0);
    expect(store.waitingCount, 2);
    final why = store.waitingChanges(now: now());
    expect(why.map((w) => w.reason), [
      SharedWaitReason.due,
      SharedWaitReason.earlierChange,
    ]);
  });

  test('one whose earlier change was confirmed is not refused', () async {
    final first = fixtures.command(fixtures.op1);
    await store.enqueue(first);
    await store.enqueue(_member(fixtures.op2), dependsOn: [fixtures.op1]);
    final claim = (await store.claim(now: now(), leaseId: 'w'))!;
    await store.complete(claim, fixtures.receipt(first), [
      fixtures.projection(),
    ]);
    expect(await store.reconcileQueue(), 0);
    expect(store.operation(fixtures.op2)!.state, SharedCommandState.pending);
  });

  test('the reason a change is waiting is said in each state', () async {
    await store.enqueue(_member(fixtures.op1));
    expect(
      store.waitingChanges(now: now()).single.reason,
      SharedWaitReason.due,
    );

    // The server was busy: it waits a little, and says when.
    db.db.execute(
      "UPDATE shared_commands SET state='retry',attempts=2,next_attempt=? WHERE namespace=?",
      [now() + 60000, fixtures.accountA],
    );
    final retry = store.waitingChanges(now: now()).single;
    expect(retry.reason, SharedWaitReason.retryLater);
    expect(retry.retryAt, greaterThan(now()));

    db.db.execute(
      "UPDATE shared_commands SET state='awaitingAuth' WHERE namespace=?",
      [fixtures.accountA],
    );
    expect(
      store.waitingChanges(now: now()).single.reason,
      SharedWaitReason.signIn,
    );

    db.db.execute(
      "UPDATE shared_commands SET state='sending',lease_expires=? WHERE namespace=?",
      [now() + 60000, fixtures.accountA],
    );
    expect(
      store.waitingChanges(now: now()).single.reason,
      SharedWaitReason.sending,
    );
  });
}
