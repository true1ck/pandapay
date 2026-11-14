import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/activity_screen.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_providers.dart';
import 'package:pandapay/features/shared_expenses/runtime/split_share_entries.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/activity/spend_exclusion.dart';
import 'package:pandapay/features/sms_v2/ledger/reports.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../storage/shared_store_test.dart' as fixtures;

SplitShareExpense _e(String id, String day, int share) => SplitShareExpense(
  id: id,
  title: 'Dinner $id',
  occurredOn: day,
  shareMinor: share,
);

SplitShareContext _ctx(List<SplitShareExpense> es, {int? owing}) =>
    SplitShareContext(id: 'c', name: 'Ravi', expenses: es, owingMinor: owing);

void main() {
  group('rows for shares somebody else paid', () {
    test(
      'a friend-paid share is a counted spend row dated the expense day',
      () {
        final rows = splitShareEntries([
          _ctx([_e('a', '2026-11-11', 50000)], owing: 50000),
        ]);
        final row = rows.single;
        expect(row.id, 'split:a');
        expect(row.entryKind, TxnEntryKind.spend);
        expect(row.amount.paise, 50000);
        expect(row.merchantName, 'Dinner a');
        expect(row.occurredAt, DateTime(2026, 11, 11, 12));
        expect(row.source, kSplitShareSource);
        expect(row.status, 'active');
        expect(row.excludeFromSpend, isFalse);
        expect(row.countsAsSpend, isTrue);
        expect(row.note, 'Split · Ravi');
        expect(isSplitShareEntry(row), isTrue);
      },
    );

    test('with nothing known about what is owed, every share counts', () {
      final rows = splitShareEntries([
        _ctx([_e('a', '2026-11-01', 30000), _e('b', '2026-11-02', 20000)]),
      ]);
      expect(rows.every((r) => r.countsAsSpend), isTrue);
    });

    test('paid back in full: the share stays visible but stops counting', () {
      final rows = splitShareEntries([
        _ctx([_e('a', '2026-11-11', 50000)], owing: 0),
      ]);
      expect(rows.single.excludeFromSpend, isTrue);
      expect(rows.single.countsAsSpend, isFalse);
      expect(rows.single.note, 'Split · Ravi · settled');
    });

    test(
      'the oldest shares are settled first; one part-paid share counts what is left',
      () {
        // 300 + 200 + 500 = 1000 shared, 600 still owed, so 400 was paid back.
        final rows = splitShareEntries([
          _ctx([
            _e('c', '2026-11-12', 50000),
            _e('a', '2026-11-01', 30000),
            _e('b', '2026-11-05', 20000),
          ], owing: 60000),
        ]);
        final byId = {for (final r in rows) r.id: r};
        expect(byId['split:a']!.countsAsSpend, isFalse); // 300 settled
        expect(byId['split:b']!.countsAsSpend, isTrue); // 100 of 200 left
        expect(byId['split:b']!.amount.paise, 10000);
        expect(byId['split:b']!.note, contains('still owed'));
        expect(byId['split:c']!.amount.paise, 50000);
        final counted = rows
            .where((r) => r.countsAsSpend)
            .fold<int>(0, (sum, r) => sum + r.amount.paise);
        expect(counted, 60000, reason: 'what is counted equals what is owed');
      },
    );

    test('owing more than the shares leaves them all counted', () {
      final rows = splitShareEntries([
        _ctx([_e('a', '2026-11-11', 50000)], owing: 90000),
      ]);
      expect(rows.single.countsAsSpend, isTrue);
      expect(rows.single.amount.paise, 50000);
    });

    test('a bad date is skipped, not thrown', () {
      expect(
        splitShareEntries([
          _ctx([_e('a', 'soon', 100)]),
        ]),
        isEmpty,
      );
    });
  });

  group('they reach the spending totals', () {
    test('a counted share adds to spending, a settled one does not', () {
      final rows = splitShareEntries([
        _ctx([
          _e('a', '2026-11-01', 30000),
          _e('b', '2026-11-05', 20000),
        ], owing: 20000),
      ]);
      final model = LedgerReadModel(
        ledger: LedgerSnapshot(entries: [], events: []),
        transactions: rows,
      );
      // 'a' (300) is settled, 'b' (200) is still owed.
      expect(model.totalsForTransactions(rows).spendMinor, 20000);
    });
  });

  group('Activity filters on share rows', () {
    final rows = splitShareEntries([
      _ctx([_e('a', '2026-11-01', 100), _e('b', '2026-11-20', 200)]),
    ]);

    test('a date range keeps only shares inside it', () {
      final kept = activityShareRows(
        rows,
        from: DateTime(2026, 11, 10),
        to: DateTime(2026, 11, 30),
      );
      expect(kept.map((r) => r.id), ['split:b']);
    });

    test('a text search matches the title or the split label', () {
      expect(activityShareRows(rows, query: 'dinner a').map((r) => r.id), [
        'split:a',
      ]);
      expect(activityShareRows(rows, query: 'ravi'), hasLength(2));
      expect(activityShareRows(rows, query: 'zzz'), isEmpty);
    });
  });

  group('reading the phone\'s own copy of Splits', () {
    const own = '88888888-8888-4888-8888-888888888888';
    const other = '99999999-9999-4999-8999-999999999999';
    const ctx = '77777777-7777-4777-8777-777777777777';
    final accountId = fixtures.accountA.substring(5);

    SharedProjection p(
      String entity,
      String id,
      Map<String, Object?> payload,
    ) => SharedProjection(
      entity: entity,
      id: id,
      contextId: ctx,
      revision: 1,
      payload: payload,
    );

    Map<String, Object?> expense(
      String id, {
      required String paidBy,
      required String day,
      String total = '100000',
      bool isVoid = false,
    }) => {
      'recordType': 'head',
      'contextId': ctx,
      'expenseId': id,
      'acceptedRevisionId': 'r$id',
      'accepted': {
        'revisionId': 'r$id',
        'title': 'Bill $id',
        'occurredOn': day,
        'totalMinor': total,
        'void': isVoid,
        'bill': null,
        'snapshot': {
          'contributions': [
            {'memberId': paidBy, 'amountMinor': total},
          ],
          'shares': [
            {'memberId': own, 'amountMinor': '50000'},
            {'memberId': other, 'amountMinor': '50000'},
          ],
        },
      },
    };

    Future<SplitShareReader> readerFor(String owing) async {
      final db = AppDatabase.forTesting(sqlite3.openInMemory());
      addTearDown(db.close);
      final store = SharedExpensesStore(db, namespace: fixtures.accountA);
      await store.applyPage(
        SharedChangePage(
          records: [
            p('contexts', ctx, {
              'contextId': ctx,
              'kind': 'direct',
              'name': 'PandaPay friend',
              'state': 'active',
              'membershipState': 'active',
              'committedSequence': '4',
              'createdAt': '2026-11-01T00:00:00Z',
              'owedMinor': '0',
              'owingMinor': owing,
            }),
            p('members', own, {
              'contextId': ctx,
              'memberId': own,
              'profileId': accountId,
              'role': 'owner',
              'state': 'active',
              'displayName': 'Me',
            }),
            p('members', other, {
              'contextId': ctx,
              'memberId': other,
              'profileId': null,
              'role': 'member',
              'state': 'active',
              'displayName': 'Ravi',
            }),
            p(
              'expenses',
              'e1',
              expense('e1', paidBy: other, day: '2026-11-11'),
            ),
            p('expenses', 'e2', expense('e2', paidBy: own, day: '2026-11-09')),
            p(
              'expenses',
              'e3',
              expense('e3', paidBy: other, day: '2026-11-10', isVoid: true),
            ),
          ],
          nextCursor: null,
        ),
        expectedCursor: null,
      );
      return SplitShareReader(store, accountId);
    }

    Future<List<SplitShareContext>> read(String owing) async =>
        (await readerFor(owing)).read();

    test(
      'only expenses somebody else paid, never mine or removed ones',
      () async {
        final contexts = await read('50000');
        final context = contexts.single;
        expect(
          context.name,
          'Ravi',
          reason: 'a friend is named by who they are',
        );
        expect(context.owingMinor, 50000);
        expect(context.expenses.map((e) => e.id), ['e1']);
        expect(context.expenses.single.shareMinor, 50000);
      },
    );

    test('a second read of unchanged data reuses what it read', () async {
      final reader = await readerFor('50000');
      final first = reader.read();
      final second = reader.read();
      expect(identical(first.single, second.single), isTrue);
    });

    test(
      'an expense the person paid and split is read with what they paid',
      () async {
        final paid = (await read('50000')).single.paidExpenses.single;
        expect(paid.id, 'e2');
        expect(paid.paidMinor, 100000);
        expect(paid.shareMinor, 50000);
        expect(paid.occurredOn, '2026-11-09');
      },
    );

    test('rows follow what is still owed', () async {
      final owed = splitShareEntries(await read('50000')).single;
      expect(owed.countsAsSpend, isTrue);
      final paid = splitShareEntries(await read('0')).single;
      expect(paid.countsAsSpend, isFalse);
    });
  });

  test('looking at the shares never starts the Splits runtime', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final overlay = await container.read(splitOverlayProvider.future);
    expect(overlay.isEmpty, isTrue);
    expect(
      container.exists(sharedExpensesRuntimeProvider),
      isFalse,
      reason: 'the app shell starts it; a reader must not do so earlier',
    );
  });

  group('a split of a payment the person made', () {
    TransactionEntry bank(
      String id, {
      int rupees = 1200,
      DateTime? at,
      bool excluded = false,
      TxnEntryKind kind = TxnEntryKind.spend,
      String status = 'active',
    }) => TransactionEntry(
      id: id,
      amount: Money.fromRupees(rupees),
      occurredAt: at ?? DateTime(2026, 11, 9, 20),
      merchantName: 'Dinner place',
      source: 'sms',
      status: status,
      entryKind: kind,
      excludeFromSpend: excluded,
      tags: const [],
    );

    SplitOverlay overlayFor({
      String day = '2026-11-09',
      int paid = 120000,
      int share = 60000,
    }) => splitOverlay([
      SplitShareContext(
        id: 'c',
        name: 'Ravi',
        expenses: const [],
        paidExpenses: [
          SplitPaidExpense(
            id: 'e1',
            title: 'Dinner',
            occurredOn: day,
            paidMinor: paid,
            shareMinor: share,
          ),
        ],
      ),
    ]);

    test('only your share counts: the payment steps aside for it', () {
      final base = [bank('p1')];
      final applied = applySplitOverlay(base, overlayFor());
      expect(applied.payments.single.excludeFromSpend, isTrue);
      expect(applied.payments.single.excludeReason, kSplitCoveredReason);
      expect(
        applied.payments.single.amount.paise,
        120000,
        reason: 'cash is cash',
      );
      expect(applied.shares.single.amount.paise, 60000);
      expect(applied.shares.single.note, contains('your share of'));
      final rows = [...applied.payments, ...applied.shares];
      final model = LedgerReadModel(
        ledger: LedgerSnapshot(entries: [], events: []),
        transactions: rows,
      );
      expect(model.totalsForTransactions(rows).spendMinor, 60000);
    });

    test('the day before or after still matches, two days away does not', () {
      for (final at in [DateTime(2026, 11, 8, 23), DateTime(2026, 11, 10, 1)]) {
        expect(
          applySplitOverlay([bank('p', at: at)], overlayFor()).shares,
          hasLength(1),
        );
      }
      expect(
        applySplitOverlay([
          bank('p', at: DateTime(2026, 11, 12)),
        ], overlayFor()).shares,
        isEmpty,
      );
    });

    test('a different amount is not the same payment', () {
      final base = [bank('p', rupees: 1000)];
      final applied = applySplitOverlay(base, overlayFor());
      expect(identical(applied.payments, base), isTrue);
      expect(applied.shares, isEmpty);
    });

    test('two payments that fit are not guessed between', () {
      final base = [bank('p1'), bank('p2')];
      final applied = applySplitOverlay(base, overlayFor());
      expect(identical(applied.payments, base), isTrue);
      expect(applied.shares, isEmpty);
    });

    test('a payment the person already left out is not touched', () {
      expect(
        applySplitOverlay([bank('p', excluded: true)], overlayFor()).shares,
        isEmpty,
      );
    });

    test('only an active spend is replaced', () {
      expect(
        applySplitOverlay([
          bank('p', kind: TxnEntryKind.income),
        ], overlayFor()).shares,
        isEmpty,
      );
      expect(
        applySplitOverlay([bank('p', status: 'ignored')], overlayFor()).shares,
        isEmpty,
      );
    });

    test('a share row is never mistaken for a payment', () {
      final share = splitShareEntries([
        SplitShareContext(
          id: 'c',
          name: 'Ravi',
          expenses: [_e('x', '2026-11-09', 120000)],
        ),
      ]);
      expect(applySplitOverlay(share, overlayFor()).shares, isEmpty);
    });

    test('one payment is stood in for by one split only', () {
      final two = SplitOverlay(
        linked: [...overlayFor().linked, ...overlayFor().linked],
      );
      final applied = applySplitOverlay([bank('p1')], two);
      // Both splits fit the one payment equally, so it is replaced once.
      expect(applied.shares, hasLength(1));
    });

    test('an unchanged payment keeps the same copy between calls', () {
      final base = [bank('p1')];
      final memo = <String, (TransactionEntry, TransactionEntry)>{};
      final a = applySplitOverlay(base, overlayFor(), memo: memo);
      final b = applySplitOverlay(base, overlayFor(), memo: memo);
      expect(identical(a.payments.single, b.payments.single), isTrue);
    });

    test('a share as big as the payment is not a split worth changing', () {
      expect(overlayFor(share: 120000).linked, isEmpty);
    });

    test('the label says why the payment is not counted in full', () {
      final applied = applySplitOverlay([bank('p1')], overlayFor());
      expect(
        leftOutLabel(applied.payments.single),
        'Counted as your share of a split',
      );
    });
  });
}
