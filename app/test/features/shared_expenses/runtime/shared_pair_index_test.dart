import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_pair_index.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:pandapay/features/shared_expenses/ui/shared_presentation.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
import 'package:sqlite3/sqlite3.dart';

import '../storage/shared_store_test.dart' as fixtures;

const _direct = '11111111-0000-4000-8000-000000000001';
const _goa = '11111111-0000-4000-8000-000000000002';
const _solo = '11111111-0000-4000-8000-000000000003';
const _meD = 'aaaaaaaa-0000-4000-8000-000000000001';
const _sujayD = 'aaaaaaaa-0000-4000-8000-000000000002';
const _meG = 'aaaaaaaa-0000-4000-8000-000000000003';
const _sujayG = 'aaaaaaaa-0000-4000-8000-000000000004';
const _samG = 'aaaaaaaa-0000-4000-8000-000000000005';
const _meS = 'aaaaaaaa-0000-4000-8000-000000000006';
const _invited = 'aaaaaaaa-0000-4000-8000-000000000007';
const _sujay = '22222222-0000-4000-8000-000000000001';
const _sam = '22222222-0000-4000-8000-000000000002';

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
    String? profile, {
    String state = 'active',
  }) => {
    'contextId': ctx,
    'memberId': id,
    'profileId': profile,
    'role': 'member',
    'state': state,
    'displayName': id,
  };

  Map<String, Object?> context(String id, String kind, String name) => {
    'contextId': id,
    'kind': kind,
    'name': name,
    'state': 'active',
    'membershipState': 'active',
    'committedSequence': '3',
  };

  /// [low] is always "me" here: a positive balance means they owe me.
  Map<String, Object?> balance(
    String ctx,
    String low,
    String high,
    int minor,
  ) => {
    'contextId': ctx,
    'lowMemberId': low,
    'highMemberId': high,
    'balanceMinor': '$minor',
  };

  Future<SharedPairIndex> index() async {
    final db = AppDatabase.forTesting(sqlite3.openInMemory());
    addTearDown(db.close);
    final store = SharedExpensesStore(db, namespace: fixtures.accountA);
    await store.applyPage(
      SharedChangePage(
        records: [
          p('contexts', _direct, _direct, context(_direct, 'direct', 'Sujay')),
          p('members', _meD, _direct, member(_direct, _meD, me)),
          p('members', _sujayD, _direct, member(_direct, _sujayD, _sujay)),
          p(
            'balances',
            '$_meD:$_sujayD',
            _direct,
            balance(_direct, _meD, _sujayD, 200000),
          ),
          p('contexts', _goa, _goa, context(_goa, 'group', 'Goa trip')),
          p('members', _meG, _goa, member(_goa, _meG, me)),
          p('members', _sujayG, _goa, member(_goa, _sujayG, _sujay)),
          p('members', _samG, _goa, member(_goa, _samG, _sam)),
          p(
            'balances',
            '$_meG:$_sujayG',
            _goa,
            balance(_goa, _meG, _sujayG, -50000),
          ),
          p(
            'balances',
            '$_meG:$_samG',
            _goa,
            balance(_goa, _meG, _samG, 30000),
          ),
          p('contexts', _solo, _solo, context(_solo, 'direct', 'New friend')),
          p('members', _meS, _solo, member(_solo, _meS, me)),
          p(
            'members',
            _invited,
            _solo,
            member(_solo, _invited, null, state: 'invited'),
          ),
        ],
        nextCursor: null,
      ),
      expectedCursor: null,
    );
    return SharedPairIndex.read(store, me);
  }

  test('a friend shows the non-group part and each group you share', () async {
    final lines = (await index()).linesFor(_direct, 200000);
    expect(lines, hasLength(2));
    expect(lines[0].groupName, isNull);
    expect(lines[0].owedToYou, isTrue);
    expect(lines[0].amount.paise, 200000);
    expect(lines[1].groupName, 'Goa trip');
    expect(lines[1].owedToYou, isFalse);
    expect(lines[1].amount.paise, 50000);
    expect(
      lines[0].sentence('Sujay'),
      'Sujay owes you ₹2,000.00 in non-group expenses',
    );
    expect(lines[1].sentence('Sujay'), 'You owe Sujay ₹500.00 in “Goa trip”');
  });

  test('the total is the sum of the places, both directions kept', () async {
    final lines = (await index()).linesFor(_direct, 200000);
    final total = sharedSummaryOfLines(
      lines,
      const SharedBalanceSummary(
        owedToYou: Money.zero(),
        youOwe: Money.zero(),
        netBalance: Money.zero(),
      ),
    );
    expect(total.owedToYou.paise, 200000);
    expect(total.youOwe.paise, 50000);
    expect(total.netBalance.paise, 150000);
  });

  test('nothing settled outside groups: only the group lines', () async {
    final lines = (await index()).linesFor(_direct, 0);
    expect(lines.map((l) => l.groupName), ['Goa trip']);
  });

  test(
    'a friend who shares no group gets no lines (one would only repeat)',
    () async {
      expect((await index()).linesFor(_solo, 1000), isEmpty);
    },
  );

  test('an unknown context gets no lines', () async {
    expect((await index()).linesFor('nope', 1000), isEmpty);
  });
}
