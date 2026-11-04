import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:sqlite3/sqlite3.dart';

const account = '11111111-1111-4111-8111-111111111111';
const me = '22222222-2222-4222-8222-222222222222';
const friend = '33333333-3333-4333-8333-333333333333';
const group = '44444444-4444-4444-8444-444444444444';
void main() {
  late AppDatabase db;
  late SharedExpensesStore store;
  late SharedEditor editor;
  setUp(() {
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    store = SharedExpensesStore(db, namespace: 'user:$account');
    editor = SharedEditor(store: store, accountId: account);
  });
  tearDown(() {
    editor.dispose();
    db.close();
  });
  void setup() {
    editor.selectContext(group, 'Flatmates', const [
      SharedEditorMember(me, 'You'),
      SharedEditorMember(friend, 'Rahul'),
    ], me);
    editor.setBill('900');
    editor.setTitle('Dinner');
    editor.choosePayer(friend);
  }

  test(
    'someone else paid generates only a shared proposal and no own source or payment',
    () async {
      setup();
      expect(editor.evaluation.preview!.yourFullPaid.paise, 0);
      expect(editor.evaluation.preview!.yourShare.paise, 45000);
      final command = await editor.seal();
      expect(command.kind, 'expense.propose');
      expect((command.toJson()['payload'] as Map)['sources'], isEmpty);
      expect(store.pendingCount, 1);
      expect(
        ((command.toJson()['payload'] as Map)['bill'] as Map)['totalMinor'],
        '90000',
      );
      expect(
        ((command.toJson()['payload'] as Map)['snapshot']
            as Map)['contributions'],
        [
          {'memberId': friend, 'amountMinor': '90000'},
        ],
      );
      expect((await editor.seal()).canonicalJson, command.canonicalJson);
      expect(store.pendingCount, 1);
    },
  );
  test(
    'new own bank payment cannot silently become an unlinked cash split',
    () async {
      setup();
      editor.choosePayer(me);
      expect(editor.evaluation.canPropose, isFalse);
      await expectLater(editor.seal(), throwsStateError);
      expect(store.pendingCount, 0);
    },
  );
  test(
    'unfinished input and private classification restore exactly without a command',
    () async {
      setup();
      editor.setBill('900.');
      editor.setPrivateFields({
        'categoryId': 'dining',
        'tagIds': ['trip'],
      });
      await editor.persist();
      final restored = SharedEditor(
        store: store,
        accountId: account,
        draftId: editor.id,
      );
      expect(restored.billText, '900.');
      expect(restored.title, 'Dinner');
      expect(restored.privateFields['tagIds'], ['trip']);
      expect(restored.evaluation.isValid, isFalse);
      expect(store.pendingCount, 0);
      restored.dispose();
    },
  );
  test(
    'rapid edits serialize latest state and keep stable revision identity',
    () async {
      setup();
      final revision = editor.revisionId;
      editor.setBill('100');
      final first = editor.persist();
      editor.setBill('200');
      final second = editor.persist();
      await first;
      await second;
      expect(store.editorDraft(editor.id)!.value['billText'], '200');
      expect(editor.revisionId, revision);
    },
  );
  test(
    'participant mode updates use live exact validation and preserve payer separately',
    () {
      setup();
      editor.setMode(SharedSplitMode.exact);
      editor.setSplit(me, '300');
      editor.setSplit(friend, '600');
      expect(editor.evaluation.preview!.yourShare.paise, 30000);
      editor.setSplit(friend, '599.99');
      expect(editor.evaluation.isValid, isFalse);
      editor.setSplit(friend, '600');
      editor.setShared('600');
      expect(editor.evaluation.isValid, isFalse);
    },
  );
  test(
    'a stale editor cannot overwrite or seal another window changes',
    () async {
      setup();
      await editor.persist();
      final other = SharedEditor(
        store: store,
        accountId: account,
        draftId: editor.id,
      );
      other.setTitle('Different');
      await other.persist();
      editor.setTitle('Old change');
      await expectLater(editor.persist(), throwsA(isA<SharedLocalException>()));
      await expectLater(editor.seal(), throwsA(isA<SharedLocalException>()));
      expect(store.pendingCount, 0);
      other.dispose();
    },
  );
  test(
    'member removal cannot silently drop a selected share on restart',
    () async {
      setup();
      editor.selectContext(group, 'Flatmates', const [
        SharedEditorMember(me, 'You'),
      ], me);
      expect(editor.canSubmit, isFalse);
      await editor.persist();
      final restored = SharedEditor(
        store: store,
        accountId: account,
        draftId: editor.id,
      );
      expect(restored.participants, contains(friend));
      expect(restored.singlePayer, friend);
      restored.dispose();
    },
  );
  test(
    'unchanged private fields do not schedule another database version',
    () async {
      setup();
      editor.setPrivateFields({
        'note': 'Keep receipt',
        'tagIds': ['trip'],
      });
      await editor.persist();
      final version = store.editorDraft(editor.id)!.version;
      editor.setPrivateFields({
        'tagIds': ['trip'],
        'note': 'Keep receipt',
      });
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(store.editorDraft(editor.id)!.version, version);
    },
  );
}
