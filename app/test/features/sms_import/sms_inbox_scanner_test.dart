import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_import/sms_inbox_scanner.dart';
import 'package:pandapay/features/sms_import/sms_listener_service.dart';

void main() {
  late AppDatabase db;
  late FinancialStore store;
  late SmsInboxProgress progress;
  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    progress = SmsInboxProgress(db);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });
  InboxSms message(int id) => InboxSms(
    id: id,
    sender: 'VM-ICICIB',
    body: 'INR $id spent on ICICI Bank Card XX7788 at SWIGGY.',
    receivedAt: DateTime(2026, 10, 1),
  );
  SmsInboxScanner scanner(
    List<InboxSms> rows,
    List<int> queries, {
    Future<void> Function(List<InboxSms>)? capture,
    void Function()? checkAccount,
    int pageSize = 2,
  }) => SmsInboxScanner(
    progress: progress,
    head: () async => rows.isEmpty ? 0 : rows.last.id!,
    read: (after, through) async {
      queries.add(after);
      final page = rows
          .where((row) => row.id! > after && row.id! <= through)
          .take(pageSize)
          .toList();
      return SmsInboxPage(
        page,
        page.isEmpty ? after : page.last.id!,
        page.length,
      );
    },
    capture:
        capture ??
        (messages) async => SmsImportStore(store).captureBatch('user:a', [
          for (final row in messages)
            QueuedSms(
              sender: row.sender,
              body: row.body,
              receivedAt: row.receivedAt,
            ),
        ]),
    checkAccount: checkAccount ?? () {},
  );

  test(
    'initial scan finishes offline and subsequent reads only capture new IDs',
    () async {
      final rows = [for (var id = 1; id <= 5; id++) message(id)];
      final queries = <int>[];
      final owner = scanner(rows, queries);
      expect(await owner.scan('user:a'), 5);
      expect(queries, [0, 2, 4]);
      expect(progress.lastId('user:a'), 5);
      expect(progress.initialComplete('user:a'), isTrue);
      expect(SmsIntakeRepository(db).pending('user:a'), hasLength(5));
      expect(
        store.transactions('user:a', const TransactionQuery())!.rows,
        hasLength(5),
      );
      queries.clear();
      expect(await owner.scan('user:a'), 0);
      expect(queries, isEmpty);
      rows.add(
        message(6),
      ); // Same old date: identity, not wall-clock time, controls capture.
      expect(await owner.scan('user:a'), 1);
      expect(queries, [5]);
      expect(SmsIntakeRepository(db).pending('user:a'), hasLength(6));
    },
  );

  test('interrupted capture resumes after the last durable page', () async {
    final rows = [for (var id = 1; id <= 5; id++) message(id)];
    final queries = <int>[];
    final broken = scanner(
      rows,
      queries,
      capture: (messages) async {
        if (messages.first.id == 3) throw StateError('storage unavailable');
      },
    );
    await expectLater(broken.scan('user:a'), throwsStateError);
    expect(progress.lastId('user:a'), 2);
    expect(progress.initialComplete('user:a'), isFalse);
    queries.clear();
    await scanner(rows, queries).scan('user:a');
    expect(queries, [2, 4]);
    expect(progress.initialComplete('user:a'), isTrue);
  });

  test('scan progress is isolated by account', () async {
    final rows = [message(1), message(2)];
    final queries = <int>[];
    await scanner(rows, queries, capture: (_) async {}).scan('user:a');
    queries.clear();
    await scanner(rows, queries, capture: (_) async {}).scan('user:b');
    expect(queries, [0]);
    expect(progress.lastId('user:a'), 2);
    expect(progress.lastId('user:b'), 2);
  });

  test('account switch during capture never advances its checkpoint', () async {
    var switched = false;
    final owner = scanner(
      [message(1)],
      [],
      capture: (_) async {
        switched = true;
      },
      checkAccount: () {
        if (switched) throw StateError('account changed');
      },
    );
    await expectLater(owner.scan('user:a'), throwsStateError);
    expect(progress.lastId('user:a'), 0);
  });

  test(
    'a new SMS arriving during the snapshot is captured on the next pass',
    () async {
      final rows = [message(1), message(2)];
      var added = false;
      final owner = scanner(
        rows,
        [],
        capture: (_) async {
          if (!added) {
            rows.add(message(3));
            added = true;
          }
        },
      );
      await owner.scan('user:a');
      expect(progress.lastId('user:a'), 2);
      await owner.scan('user:a');
      expect(progress.lastId('user:a'), 3);
    },
  );

  test(
    'empty inbox completion is durable and malformed pages cannot skip rows',
    () async {
      await scanner([], []).scan('user:a');
      expect(progress.initialComplete('user:a'), isTrue);
      final broken = SmsInboxScanner(
        progress: progress,
        head: () async => 2,
        read: (_, _) async => const SmsInboxPage([], 0, 1),
        capture: (_) async {},
        checkAccount: () {},
      );
      await expectLater(broken.scan('user:a'), throwsStateError);
      expect(progress.lastId('user:a'), 0);
    },
  );
}
