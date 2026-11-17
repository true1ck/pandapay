import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_pair_index.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_pending_balances.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_presentation.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:sqlite3/sqlite3.dart';

import '../storage/shared_store_test.dart' as fixtures;

// The shape found in production on 18 Nov 2026: Sujay is a friend with an
// account (a friend context), and the group "Pp" has "Sujay" and "boy" added
// by typing their names, so neither has an account in the group. Money in the
// group never showed under the friend Sujay, and "boy" was not a friend at all.
const _friendCtx = '11111111-0000-4000-8000-000000000001';
const _group = '11111111-0000-4000-8000-000000000002';
const _meF = 'aaaaaaaa-0000-4000-8000-000000000001';
const _sujayF = 'aaaaaaaa-0000-4000-8000-000000000002';
const _meG = 'aaaaaaaa-0000-4000-8000-000000000003';
const _sujayG = 'aaaaaaaa-0000-4000-8000-000000000004';
const _boyG = 'aaaaaaaa-0000-4000-8000-000000000005';
const _sujayAccount = '22222222-0000-4000-8000-000000000001';
const _zero = SharedBalanceSummary(
  owedToYou: Money.zero(),
  youOwe: Money.zero(),
  netBalance: Money.zero(),
);
const _expense = 'eeeeeeee-0000-4000-8000-000000000001';
const _revision = 'ffffffff-0000-4000-8000-000000000001';

void main() {
  final me = fixtures.accountA.substring(5);

  SharedProjection p(
    String entity,
    String id,
    String ctx,
    Map<String, Object?> payload,
  ) => SharedProjection(
    entity: entity,
    id: id,
    contextId: ctx,
    revision: 1,
    payload: payload,
  );

  Map<String, Object?> member(
    String ctx,
    String id,
    String? profile,
    String? name, {
    String state = 'active',
  }) => {
    'contextId': ctx,
    'memberId': id,
    'profileId': profile,
    'role': 'member',
    'state': state,
    'displayName': name,
  };

  Map<String, Object?> context(String id, String kind, String name) => {
    'contextId': id,
    'kind': kind,
    'name': name,
    'state': 'active',
    'membershipState': 'active',
    'committedSequence': '3',
  };

  Map<String, Object?> balance(
    String ctx,
    String me,
    String other,
    int minor,
  ) => {
    'contextId': ctx,
    'lowMemberId': me,
    'highMemberId': other,
    'balanceMinor': '$minor',
  };

  Map<String, Object?> snapshot(
    Map<String, int> paid,
    Map<String, int> shares,
  ) {
    final total = shares.values.fold<int>(0, (a, b) => a + b);
    return {
      'currency': 'INR',
      'totalMinor': '$total',
      'contributions': [
        for (final e in paid.entries)
          {'memberId': e.key, 'amountMinor': '${e.value}'},
      ],
      'shares': [
        for (final e in shares.entries)
          {'memberId': e.key, 'amountMinor': '${e.value}'},
      ],
      'memberOrder': shares.keys.toList(),
    };
  }

  Future<SharedExpensesStore> seed({
    bool secondSujayFriend = false,
    String sujayGroupName = 'Sujay',
    String boyState = 'invited',
    List<SharedProjection> extra = const [],
  }) async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.close);
    final store = SharedExpensesStore(db, namespace: fixtures.accountA);
    await store.applyPage(
      SharedChangePage(
        records: [
          p(
            'contexts',
            _friendCtx,
            _friendCtx,
            context(_friendCtx, 'direct', 'Sujay'),
          ),
          p('members', _meF, _friendCtx, member(_friendCtx, _meF, me, null)),
          p(
            'members',
            _sujayF,
            _friendCtx,
            member(_friendCtx, _sujayF, _sujayAccount, 'Sujay'),
          ),
          p(
            'balances',
            '$_meF:$_sujayF',
            _friendCtx,
            balance(_friendCtx, _meF, _sujayF, 650000),
          ),
          p('contexts', _group, _group, context(_group, 'group', 'Pp')),
          p('members', _meG, _group, member(_group, _meG, me, null)),
          p(
            'members',
            _sujayG,
            _group,
            member(_group, _sujayG, null, sujayGroupName, state: 'invited'),
          ),
          p(
            'members',
            _boyG,
            _group,
            member(_group, _boyG, null, 'boy', state: boyState),
          ),
          // I owe the group's Sujay 500 net.
          p(
            'balances',
            '$_meG:$_sujayG',
            _group,
            balance(_group, _meG, _sujayG, -50000),
          ),
          if (secondSujayFriend) ...[
            p(
              'contexts',
              'dddddddd-0000-4000-8000-000000000001',
              'dddddddd-0000-4000-8000-000000000001',
              context(
                'dddddddd-0000-4000-8000-000000000001',
                'direct',
                'Sujay',
              ),
            ),
            p(
              'members',
              'dddddddd-0000-4000-8000-0000000000a1',
              'dddddddd-0000-4000-8000-000000000001',
              member(
                'dddddddd-0000-4000-8000-000000000001',
                'dddddddd-0000-4000-8000-0000000000a1',
                me,
                null,
              ),
            ),
            p(
              'members',
              'dddddddd-0000-4000-8000-0000000000a2',
              'dddddddd-0000-4000-8000-000000000001',
              member(
                'dddddddd-0000-4000-8000-000000000001',
                'dddddddd-0000-4000-8000-0000000000a2',
                '33333333-0000-4000-8000-000000000009',
                'Sujay',
              ),
            ),
          ],
          ...extra,
        ],
        nextCursor: null,
      ),
      expectedCursor: null,
    );
    return store;
  }

  Future<void> enqueue(
    SharedExpensesStore store, {
    required Map<String, int> paid,
    required Map<String, int> shares,
    String context = _group,
    String expense = _expense,
    String revision = _revision,
    String? previous,
    bool isVoid = false,
  }) => store.enqueue(
    SharedCommand(
      operationId: const SharedUuidForTests().next(),
      kind: 'expense.propose',
      payload: {
        'contextId': context,
        'expenseId': expense,
        'revisionId': revision,
        'expectedHeadRevisionId': previous,
        'title': 'Amazon Pay Ecom',
        'occurredOn': '2026-11-18',
        'snapshot': isVoid ? null : snapshot(paid, shares),
        'sources': <Object?>[],
        'void': isVoid,
      },
    ),
  );

  group('a name typed into a group is the friend of that name', () {
    test('the friend shows the group money and the total adds up', () async {
      final store = await seed();
      final index = SharedPairIndex.read(store, me);
      final lines = index.linesFor(_friendCtx, 650000);
      expect(lines, hasLength(2));
      expect(lines[0].groupName, isNull);
      expect(lines[0].owedToYou, isTrue);
      expect(lines[0].amount.paise, 650000);
      expect(lines[1].groupName, 'Pp');
      expect(lines[1].owedToYou, isFalse);
      expect(lines[1].amount.paise, 50000);
      final total = sharedSummaryOfLines(lines, _zero);
      expect(total.owedToYou.paise, 650000);
      expect(total.youOwe.paise, 50000);
      expect(total.netBalance.paise, 600000);
    });

    test(
      'the typed-name Sujay is not listed again as a separate friend',
      () async {
        final index = SharedPairIndex.read(await seed(), me);
        expect(index.groupPeople.map((g) => g.name), ['boy']);
      },
    );

    test('two friends with the same name: nobody is guessed', () async {
      final index = SharedPairIndex.read(
        await seed(secondSujayFriend: true),
        me,
      );
      // Which Sujay? Unknown, so the group's Sujay stays his own person and
      // neither friend takes the group money.
      expect(index.linesFor(_friendCtx, 650000), isEmpty);
      expect(
        index.groupPeople.map((g) => g.name),
        containsAll(['Sujay', 'boy']),
      );
    });

    test('names are matched without case or extra spaces', () async {
      final store = await seed(sujayGroupName: '  SUJAY ');
      expect(
        SharedPairIndex.read(store, me).linesFor(_friendCtx, 650000),
        hasLength(2),
      );
    });
  });

  group('people only in your groups are friends too', () {
    test('someone with a balance shows what is owed in each group', () async {
      final store = await seed(
        extra: [
          p(
            'balances',
            '$_meG:$_boyG',
            _group,
            balance(_group, _meG, _boyG, 150000),
          ),
        ],
      );
      final index = SharedPairIndex.read(store, me);
      final boy = index.groupPeople.single;
      expect(boy.groups, [(_group, 'Pp')]);
      final lines = index.linesForPerson(boy);
      expect(lines.single.owedToYou, isTrue);
      expect(lines.single.amount.paise, 150000);
    });

    test('a row opens the group the person is in', () {
      expect(
        sharedGroupOfPersonRow('$sharedGroupPersonPrefix$_group:name:boy'),
        _group,
      );
      expect(sharedGroupOfPersonRow(_friendCtx), isNull);
    });

    test('somebody who left, or has no name, is not listed', () async {
      final store = await seed(boyState: 'left');
      expect(SharedPairIndex.read(store, me).groupPeople, isEmpty);
    });
  });

  group('expenses saved on this phone count at once', () {
    test('a new group expense moves the group line and the totals', () async {
      final store = await seed();
      // I paid 3,000: 1,000 each for me, Sujay and boy.
      await enqueue(
        store,
        paid: {_meG: 300000},
        shares: {_meG: 100000, _sujayG: 100000, _boyG: 100000},
      );
      final waiting = SharedPendingBalances.read(store, me);
      expect(waiting.inContext(_group), {_sujayG: 100000, _boyG: 100000});

      final index = SharedPairIndex.read(store, me, pending: waiting);
      // I owed Sujay 500; now he owes me 500 net.
      final lines = index.linesFor(_friendCtx, 650000);
      expect(lines[1].groupName, 'Pp');
      expect(lines[1].owedToYou, isTrue);
      expect(lines[1].amount.paise, 50000);
      // boy now owes me 1,000.
      expect(
        index.linesForPerson(index.groupPeople.single).single.amount.paise,
        100000,
      );
      // Top line: owed +1,500 (Sujay flips +500, boy +1,000), owing -500.
      expect(index.overviewShift, (owed: 150000, owing: -50000));
    });

    test('an expense in the friend page itself moves that balance', () async {
      final store = await seed();
      await enqueue(
        store,
        context: _friendCtx,
        paid: {_meF: 200000},
        shares: {_meF: 100000, _sujayF: 100000},
      );
      final index = SharedPairIndex.read(store, me);
      expect(index.pendingDirect(_friendCtx), 100000);
      expect(index.pendingDirect(_group), 0);
    });

    test('an expense somebody else paid makes you owe them', () async {
      final store = await seed();
      await enqueue(
        store,
        paid: {_sujayG: 500000},
        shares: {_meG: 100000, _sujayG: 250000, _boyG: 150000},
      );
      expect(SharedPendingBalances.read(store, me).inContext(_group), {
        _sujayG: -100000,
      });
    });

    test('an expense the phone already has is not counted twice', () async {
      final store = await seed(
        extra: [
          p('expenses', _expense, _group, {
            'recordType': 'head',
            'contextId': _group,
            'expenseId': _expense,
            'acceptedRevisionId': _revision,
            'accepted': {
              'revisionId': _revision,
              'title': 'Amazon Pay Ecom',
              'occurredOn': '2026-11-18',
              'totalMinor': '300000',
              'void': false,
              'snapshot': snapshot(
                {_meG: 300000},
                {_meG: 100000, _sujayG: 100000, _boyG: 100000},
              ),
            },
          }),
        ],
      );
      await enqueue(
        store,
        paid: {_meG: 300000},
        shares: {_meG: 100000, _sujayG: 100000, _boyG: 100000},
      );
      expect(SharedPendingBalances.read(store, me).isEmpty, isTrue);
    });

    test('removing an expense takes back what it had added', () async {
      const second = 'ffffffff-0000-4000-8000-000000000002';
      final store = await seed(
        extra: [
          p('expenses', _expense, _group, {
            'recordType': 'head',
            'contextId': _group,
            'expenseId': _expense,
            'acceptedRevisionId': _revision,
            'accepted': {
              'revisionId': _revision,
              'title': 'Amazon Pay Ecom',
              'occurredOn': '2026-11-18',
              'totalMinor': '300000',
              'void': false,
              'snapshot': snapshot(
                {_meG: 300000},
                {_meG: 100000, _sujayG: 100000, _boyG: 100000},
              ),
            },
          }),
        ],
      );
      await enqueue(
        store,
        paid: const {},
        shares: const {},
        revision: second,
        previous: _revision,
        isVoid: true,
      );
      expect(SharedPendingBalances.read(store, me).inContext(_group), {
        _sujayG: -100000,
        _boyG: -100000,
      });
    });

    test(
      'an edit of something this phone has not got is not guessed',
      () async {
        final store = await seed();
        await enqueue(
          store,
          paid: {_meG: 100000},
          shares: {_meG: 50000, _sujayG: 50000},
          previous: 'ffffffff-0000-4000-8000-0000000000ee',
        );
        expect(SharedPendingBalances.read(store, me).isEmpty, isTrue);
      },
    );
  });
}

class SharedUuidForTests {
  const SharedUuidForTests();
  static var _n = 0;
  String next() {
    _n++;
    return '00000000-0000-4000-8000-${_n.toString().padLeft(12, '0')}';
  }
}
