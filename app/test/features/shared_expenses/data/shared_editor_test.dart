import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_editor.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/shared_expenses.dart';

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

  test('unsubmitted input and private classification never persist', () async {
    setup();
    editor.setBill('900.');
    editor.setPrivateFields({
      'categoryId': 'dining',
      'tagIds': ['trip'],
    });
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(
      db.db.select('SELECT count(*) n FROM shared_editor_drafts').single['n'],
      0,
    );
    expect(store.pendingCount, 0);
    final fresh = SharedEditor(store: store, accountId: account);
    expect(fresh.billText, isEmpty);
    expect(fresh.privateFields, isEmpty);
    fresh.dispose();
  });
  test(
    'a selected receipt is private memory until the same submission commits',
    () async {
      setup();
      final receipt = SharedSubmissionReceipt(
        name: 'Bill.jpg',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      editor.setReceipt(receipt);
      editor.setPrivateFields({'note': 'Dinner', 'receiptHash': receipt.hash});
      expect(
        db.db
            .select('SELECT count(*) n FROM shared_editor_receipts')
            .single['n'],
        0,
      );
      final command = await editor.seal();
      expect(
        store.submissionReceipt(command.operationId, receipt.hash)!.bytes,
        [1, 2, 3, 4],
      );
      expect(
        (store.provisional(command.operationId)!['privateFields']
            as Map)['note'],
        'Dinner',
      );
      expect(
        db.db.select('SELECT count(*) n FROM shared_editor_drafts').single['n'],
        0,
      );
    },
  );
  test(
    'someone else paid creates one exact shared proposal without an own bank row',
    () async {
      setup();
      expect(editor.evaluation.preview!.yourFullPaid.paise, 0);
      expect(editor.evaluation.preview!.yourShare.paise, 45000);
      final command = await editor.seal();
      final payload = command.toJson()['payload'] as Map;
      expect(payload['sources'], isEmpty);
      expect((payload['bill'] as Map)['totalMinor'], '90000');
      expect((payload['snapshot'] as Map)['contributions'], [
        {'memberId': friend, 'amountMinor': '90000'},
      ]);
      expect((await editor.seal()).canonicalJson, command.canonicalJson);
      expect(store.pendingCount, 1);
      expect(
        db.db.select('SELECT count(*) n FROM shared_editor_drafts').single['n'],
        0,
      );
    },
  );
  test(
    'own bank payment stays blocked until funding admission is implemented',
    () async {
      setup();
      editor.choosePayer(me);
      expect(editor.evaluation.canPropose, isFalse);
      await expectLater(editor.seal(), throwsStateError);
      expect(store.pendingCount, 0);
    },
  );
  test('concurrent submit taps seal one immutable operation', () async {
    setup();
    final result = await Future.wait([editor.seal(), editor.seal()]);
    expect(result[0].canonicalJson, result[1].canonicalJson);
    editor.setTitle('Late edit');
    expect(editor.title, 'Dinner');
    expect(store.pendingCount, 1);
  });
  test(
    'exact amounts and partial sharing validate without silently changing participants',
    () {
      setup();
      editor.setMode(SharedSplitMode.exact);
      editor.setSplit(me, '300');
      editor.setSplit(friend, '600');
      expect(editor.evaluation.preview!.yourShare.paise, 30000);
      editor.setSplit(friend, '599.99');
      expect(editor.canSubmit, isFalse);
      editor.setSplit(friend, '600');
      editor.setShared('600');
      expect(editor.canSubmit, isFalse);
    },
  );
  test(
    'removed participants stay explicit until the user corrects the form',
    () {
      setup();
      editor.selectContext(group, 'Flatmates', const [
        SharedEditorMember(me, 'You'),
      ], me);
      expect(editor.canSubmit, isFalse);
      expect(editor.participants, contains(friend));
      expect(editor.singlePayer, friend);
    },
  );
  test(
    'changing payer cannot detach the original payment or invent funding',
    () {
      setup();
      editor.choosePayer(me);
      final source = SharedExpenseSourceReference.parse({
        'kind': 'legacy_transaction',
        'ownerAccountId': account,
        'canonicalTransactionId': group,
        'sourceVersion': 'pending',
      });
      editor.attachSourceIntent(source, const Money.fromPaise(90000));
      editor.choosePayer(friend);
      expect(editor.linkedSource!.toJson(), source.toJson());
      expect(editor.lockedOwnPaid!.paise, 90000);
      expect(editor.evaluation.isValid, isFalse);
      expect(store.pendingCount, 0);
    },
  );
}
