import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'shared_store_test.dart' as f;

void main() {
  late Directory folder;
  late AppDatabase db;
  late SharedExpensesStore store;
  SharedCommand command() => SharedCommand(
    operationId: f.op2,
    kind: 'expense.propose',
    payload: {'contextId': f.contextId, 'expenseId': f.op1},
  );
  SharedSubmissionReceipt attachment() => SharedSubmissionReceipt(
    name: 'Bill.jpg',
    mimeType: 'image/jpeg',
    bytes: Uint8List.fromList([1, 2, 3, 4]),
  );
  setUp(() {
    folder = Directory.systemTemp.createTempSync('split-submit-');
    db = AppDatabase.openUnencryptedFileForTesting('${folder.path}/data.sqlite');
    store = SharedExpensesStore(db, namespace: f.accountA);
  });
  tearDown(() {
    db.close();
    folder.deleteSync(recursive: true);
  });
  test(
    'submission and private attachment survive restart with identical financial bytes',
    () async {
      final receipt = attachment();
      await store.enqueueExpenseSubmission(
        command(),
        provisional: {'title': 'Dinner'},
        receipt: receipt,
      );
      db.close();
      db = AppDatabase.openUnencryptedFileForTesting('${folder.path}/data.sqlite');
      store = SharedExpensesStore(db, namespace: f.accountA);
      expect(
        store.operation(f.op2)!.command.canonicalJson,
        command().canonicalJson,
      );
      expect(store.provisional(f.op2), {'title': 'Dinner'});
      expect(store.submissionReceipt(f.op2, receipt.hash)!.bytes, [1, 2, 3, 4]);
      expect(
        SharedExpensesStore(
          db,
          namespace: f.accountB,
        ).submissionReceipt(f.op2, receipt.hash),
        isNull,
      );
      await store.enqueueExpenseSubmission(
        command(),
        provisional: {'title': 'Dinner'},
        receipt: receipt,
      );
      expect(store.pendingCount, 1);
      expect(
        db.db
            .select('SELECT count(*) n FROM shared_editor_receipts')
            .single['n'],
        1,
      );
      expect(
        db.db.select('SELECT count(*) n FROM shared_editor_drafts').single['n'],
        0,
      );
    },
  );
  test(
    'receipt storage failure rolls back the entire submission instead of leaving partial work',
    () async {
      db.db.execute(
        "CREATE TRIGGER reject_receipt BEFORE INSERT ON shared_editor_receipts BEGIN SELECT RAISE(ABORT,'test receipt failure'); END",
      );
      await expectLater(
        store.enqueueExpenseSubmission(
          command(),
          provisional: {'title': 'Dinner'},
          receipt: attachment(),
        ),
        throwsA(anything),
      );
      expect(store.pendingCount, 0);
      expect(store.provisional(f.op2), isNull);
      db.db.execute('DROP TRIGGER reject_receipt');
      await store.enqueueExpenseSubmission(
        command(),
        provisional: {'title': 'Dinner'},
        receipt: attachment(),
      );
      expect(store.pendingCount, 1);
    },
  );
  test(
    'revocation prevents receipt reads and new submission while retaining immutable history',
    () async {
      final receipt = attachment();
      await store.enqueueExpenseSubmission(
        command(),
        provisional: {'title': 'Dinner'},
        receipt: receipt,
      );
      await store.revokeContext(f.contextId);
      expect(store.submissionReceipt(f.op2, receipt.hash), isNull);
      await expectLater(
        store.enqueueExpenseSubmission(
          command(),
          provisional: {'title': 'Dinner'},
          receipt: receipt,
        ),
        throwsA(isA<SharedLocalException>()),
      );
      expect(
        store.operation(f.op2)!.command.requestHash,
        command().requestHash,
      );
    },
  );
  test(
    'legacy unfinished input is removed without changing submitted work or another account',
    () async {
      await store.enqueueExpenseSubmission(
        command(),
        provisional: {'title': 'Dinner'},
        receipt: attachment(),
      );
      for (final ns in [f.accountA, f.accountB]) {
        db.db.execute(
          'INSERT INTO shared_editor_drafts VALUES(?,?,?,?,?,?,?)',
          [ns, f.op1, f.contextId, '{}', 1, null, 0],
        );
      }
      db.db.execute('INSERT INTO shared_editor_receipts VALUES(?,?,?,?,?,?)', [
        f.accountA,
        f.op1,
        'old',
        'Unsubmitted.jpg',
        null,
        Uint8List.fromList([9]),
      ]);
      final before = store.operation(f.op2)!.command.requestHash;
      store = SharedExpensesStore(db, namespace: f.accountA);
      expect(
        db.db.select(
          'SELECT count(*) n FROM shared_editor_drafts WHERE namespace=?',
          [f.accountA],
        ).single['n'],
        0,
      );
      expect(
        db.db.select(
          'SELECT count(*) n FROM shared_editor_drafts WHERE namespace=?',
          [f.accountB],
        ).single['n'],
        1,
      );
      expect(store.operation(f.op2)!.command.requestHash, before);
      expect(store.submissionReceipt(f.op2, attachment().hash)!.bytes, [
        1,
        2,
        3,
        4,
      ]);
      expect(
        db.db
            .select('SELECT count(*) n FROM transaction_outbox_entries')
            .single['n'],
        0,
      );
    },
  );
  test('friend setup persists two dependent commands atomically', () async {
    final context = SharedCommand(
      operationId: f.op1,
      kind: 'context.create',
      payload: {
        'contextId': f.contextId,
        'contextKind': 'direct',
        'name': 'Friend',
      },
    );
    final member = SharedCommand(
      operationId: f.op2,
      kind: 'member.invite',
      payload: {
        'contextId': f.contextId,
        'memberId': f.op1,
        'displayName': 'Friend',
      },
    );
    await store.enqueueFriendSetup(context, member);
    await store.enqueueFriendSetup(context, member);
    expect(store.pendingCount, 2);
    expect(
      db.db
          .select('SELECT depends_on FROM shared_command_dependencies')
          .single['depends_on'],
      f.op1,
    );
    final changed = SharedCommand(
      operationId: f.op2,
      kind: 'member.invite',
      payload: {'contextId': f.contextId, 'displayName': 'Different'},
    );
    final newContext = SharedCommand(
      operationId: '66666666-6666-4666-8666-666666666666',
      kind: 'context.create',
      payload: {'contextId': f.contextId},
    );
    await expectLater(
      store.enqueueFriendSetup(newContext, changed),
      throwsA(isA<SharedLocalException>()),
    );
    expect(store.pendingCount, 2);
  });
}
