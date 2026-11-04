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
  const value = {'billText': '100.', 'title': 'Dinner', 'payers': <Object?>[]};
  SharedCommand command() => SharedCommand(
    operationId: f.op2,
    kind: 'expense.propose',
    payload: {'contextId': f.contextId, 'expenseId': f.op1},
  );
  setUp(() {
    folder = Directory.systemTemp.createTempSync('split-editor-');
    db = AppDatabase.openFile('${folder.path}/data.sqlite');
    store = SharedExpensesStore(db, namespace: f.accountA);
  });
  tearDown(() {
    db.close();
    folder.deleteSync(recursive: true);
  });
  test(
    'unfinished editor survives process restart and is account scoped',
    () async {
      final first = await store.saveEditorDraft(
        f.op1,
        contextId: f.contextId,
        expectedVersion: 0,
        value: value,
      );
      expect(first.version, 1);
      db.close();
      db = AppDatabase.openFile('${folder.path}/data.sqlite');
      store = SharedExpensesStore(db, namespace: f.accountA);
      expect(store.editorDraft(f.op1)!.value, value);
      expect(
        SharedExpensesStore(db, namespace: f.accountB).editorDraft(f.op1),
        isNull,
      );
    },
  );
  test(
    'concurrent editors must resolve version conflict without overwriting input',
    () async {
      await store.saveEditorDraft(
        f.op1,
        contextId: f.contextId,
        expectedVersion: 0,
        value: value,
      );
      await store.saveEditorDraft(
        f.op1,
        contextId: f.contextId,
        expectedVersion: 1,
        value: {...value, 'billText': '200'},
      );
      await expectLater(
        store.saveEditorDraft(
          f.op1,
          contextId: f.contextId,
          expectedVersion: 1,
          value: value,
        ),
        throwsA(isA<SharedLocalException>()),
      );
      expect(store.editorDraft(f.op1)!.value['billText'], '200');
    },
  );
  test(
    'sealing atomically retains input, command identity and provisional preview',
    () async {
      await store.saveEditorDraft(
        f.op1,
        contextId: f.contextId,
        expectedVersion: 0,
        value: value,
      );
      await store.sealEditorDraft(
        f.op1,
        expectedVersion: 1,
        command: command(),
        provisional: {'title': 'Dinner'},
      );
      expect(store.editorDraft(f.op1)!.operationId, f.op2);
      expect(
        store.operation(f.op2)!.command.canonicalJson,
        command().canonicalJson,
      );
      expect(store.provisional(f.op2), {'title': 'Dinner'});
      await store.sealEditorDraft(
        f.op1,
        expectedVersion: 1,
        command: command(),
        provisional: {'title': 'Dinner'},
      );
      expect(store.pendingCount, 1);
      await expectLater(
        store.saveEditorDraft(
          f.op1,
          contextId: f.contextId,
          expectedVersion: 2,
          value: value,
        ),
        throwsA(isA<SharedLocalException>()),
      );
    },
  );
  test(
    'failed dependency cannot leave an editor sealed without its command',
    () async {
      await store.saveEditorDraft(
        f.op1,
        contextId: f.contextId,
        expectedVersion: 0,
        value: value,
      );
      await expectLater(
        store.sealEditorDraft(
          f.op1,
          expectedVersion: 1,
          command: command(),
          dependsOn: [f.contextId],
        ),
        throwsA(isA<SharedLocalException>()),
      );
      expect(store.editorDraft(f.op1)!.operationId, isNull);
      expect(store.pendingCount, 0);
    },
  );
  test(
    'revocation fences editor reads and submission; other authored drafts remain',
    () async {
      await store.saveEditorDraft(
        f.op1,
        contextId: f.contextId,
        expectedVersion: 0,
        value: value,
      );
      await store.revokeContext(f.contextId);
      expect(store.editorDraft(f.op1), isNull);
      await expectLater(
        store.saveEditorDraft(
          f.op1,
          contextId: null,
          expectedVersion: 0,
          value: value,
        ),
        throwsA(isA<SharedLocalException>()),
      );
      await expectLater(
        store.sealEditorDraft(f.op1, expectedVersion: 1, command: command()),
        throwsA(isA<SharedLocalException>()),
      );
    },
  );
  test(
    'private receipt bytes survive restart and never cross the account boundary',
    () async {
      await store.saveEditorDraft(
        f.op1,
        contextId: f.contextId,
        expectedVersion: 0,
        value: value,
      );
      final receipt = await store.saveEditorReceipt(
        f.op1,
        name: 'Bill.jpg',
        mimeType: 'image/jpeg',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      db.close();
      db = AppDatabase.openFile('${folder.path}/data.sqlite');
      store = SharedExpensesStore(db, namespace: f.accountA);
      expect(store.editorReceipt(f.op1, receipt.hash)!.bytes, [1, 2, 3, 4]);
      expect(
        SharedExpensesStore(
          db,
          namespace: f.accountB,
        ).editorReceipt(f.op1, receipt.hash),
        isNull,
      );
      await store.saveEditorReceipt(
        f.op1,
        name: 'Same.jpg',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(
        db.db
            .select('SELECT count(*) n FROM shared_editor_receipts')
            .single['n'],
        1,
      );
      await store.revokeContext(f.contextId);
      expect(store.editorReceipt(f.op1, receipt.hash), isNull);
    },
  );
}
