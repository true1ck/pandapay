import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_pair_index.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../storage/shared_store_test.dart' as fixtures;

// The Friends tab and the group page built from this phone's own records (the
// network is down for the whole file), in the shape found in production on
// 18 Nov 2026: Sujay is a friend with an account, and the group "Pp" has
// "Sujay" and "boy" added by typing their names.
const _friendCtx = '11111111-0000-4000-8000-000000000001';
const _group = '11111111-0000-4000-8000-000000000002';
const _meF = 'aaaaaaaa-0000-4000-8000-000000000001';
const _sujayF = 'aaaaaaaa-0000-4000-8000-000000000002';
const _meG = 'aaaaaaaa-0000-4000-8000-000000000003';
const _sujayG = 'aaaaaaaa-0000-4000-8000-000000000004';
const _boyG = 'aaaaaaaa-0000-4000-8000-000000000005';
const _sujayAccount = '22222222-0000-4000-8000-000000000001';
const _expense = 'eeeeeeee-0000-4000-8000-000000000001';
const _revision = 'ffffffff-0000-4000-8000-000000000001';

SharedProjection _p(
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

void main() {
  late AppDatabase db;
  late SharedExpensesRuntime runtime;
  late AuthenticatedHttpClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final token =
        'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': fixtures.accountA.substring(5)}))).replaceAll('=', '')}.signature';
    db = AppDatabase.forTesting(sqlite3.openInMemory());
    client = AuthenticatedHttpClient(
      refreshAccessToken: () async => null,
      inner: MockClient((_) async => throw http.ClientException('offline')),
    );
    runtime = SharedExpensesRuntime(
      store: SharedExpensesStore(db, namespace: fixtures.accountA),
      remote: SharedExpensesHttpTransport(
        apiBaseUrl: 'http://127.0.0.1:4001',
        namespace: fixtures.accountA,
        client: client,
        accessToken: () => token,
        isCurrent: () => true,
      ),
      cache: ResponseCache(db),
      isCurrent: () => true,
    );
  });
  tearDown(() {
    runtime.dispose();
    client.close();
    db.close();
  });

  final accountId = fixtures.accountA.substring(5);

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
    'createdAt': '2026-11-14T00:00:00Z',
  };

  Future<void> seed() => runtime.store.applyPage(
    SharedChangePage(
      records: [
        _p(
          'contexts',
          _friendCtx,
          _friendCtx,
          context(_friendCtx, 'direct', 'Sujay'),
        ),
        _p(
          'members',
          _meF,
          _friendCtx,
          member(_friendCtx, _meF, accountId, null),
        ),
        _p(
          'members',
          _sujayF,
          _friendCtx,
          member(_friendCtx, _sujayF, _sujayAccount, 'Sujay'),
        ),
        _p('balances', '$_meF:$_sujayF', _friendCtx, {
          'contextId': _friendCtx,
          'lowMemberId': _meF,
          'highMemberId': _sujayF,
          'balanceMinor': '650000',
        }),
        _p('contexts', _group, _group, context(_group, 'group', 'Pp')),
        _p('members', _meG, _group, member(_group, _meG, accountId, null)),
        _p(
          'members',
          _sujayG,
          _group,
          member(_group, _sujayG, null, 'Sujay', state: 'invited'),
        ),
        _p(
          'members',
          _boyG,
          _group,
          member(_group, _boyG, null, 'boy', state: 'invited'),
        ),
        _p('balances', '$_meG:$_sujayG', _group, {
          'contextId': _group,
          'lowMemberId': _meG,
          'highMemberId': _sujayG,
          'balanceMinor': '-50000',
        }),
      ],
      nextCursor: null,
    ),
    expectedCursor: null,
  );

  test('Sujay shows the group money, and boy is listed as a friend', () async {
    await seed();
    final hub = await runtime.loadHub();
    final friends = {for (final r in hub.friends.items) r.title: r};
    expect(friends.keys, containsAll(['Sujay', 'boy']));
    expect(friends.length, 2);

    final sujay = friends['Sujay']!;
    expect(sujay.id, _friendCtx);
    expect(sujay.breakdown.map((l) => l.groupName), [null, 'Pp']);
    expect(sujay.balance.owedToYou.paise, 650000);
    expect(sujay.balance.youOwe.paise, 50000);

    final boy = friends['boy']!;
    expect(boy.subtitle, 'In Pp');
    expect(boy.balance.owedToYou.isZero && boy.balance.youOwe.isZero, isTrue);
    expect(sharedGroupOfPersonRow(boy.id), _group);
  });

  test(
    'a saved group expense moves every screen before the server answers',
    () async {
      await seed();
      // I paid 3,000, split three ways. Nothing is sent: the network is down.
      await runtime.submit('expense.propose', {
        'contextId': _group,
        'expenseId': _expense,
        'revisionId': _revision,
        'expectedHeadRevisionId': null,
        'title': 'Amazon Pay Ecom',
        'occurredOn': '2026-11-18',
        'snapshot': {
          'currency': 'INR',
          'totalMinor': '300000',
          'contributions': [
            {'memberId': _meG, 'amountMinor': '300000'},
          ],
          'shares': [
            {'memberId': _meG, 'amountMinor': '100000'},
            {'memberId': _sujayG, 'amountMinor': '100000'},
            {'memberId': _boyG, 'amountMinor': '100000'},
          ],
          'memberOrder': [_meG, _sujayG, _boyG],
        },
        'sources': <Object?>[],
        'void': false,
      });

      final hub = await runtime.loadHub();
      final friends = {for (final r in hub.friends.items) r.title: r};
      // Sujay: I owed him 500 in Pp, now he owes me 500 there.
      final sujay = friends['Sujay']!;
      expect(sujay.breakdown.last.groupName, 'Pp');
      expect(sujay.breakdown.last.owedToYou, isTrue);
      expect(sujay.breakdown.last.amount.paise, 50000);
      expect(sujay.balance.owedToYou.paise, 700000);
      expect(sujay.balance.youOwe.isZero, isTrue);
      // boy owes me 1,000.
      expect(friends['boy']!.balance.owedToYou.paise, 100000);

      final group = await runtime.loadGroup(_group);
      final owes = {
        for (final r in group.balances.items)
          r.title: r.balance.owedToYou.paise,
      };
      expect(owes, {'Sujay': 50000, 'boy': 100000});
      // And the friend page for Sujay carries the group line too.
      final page = await runtime.loadGroup(_friendCtx);
      expect(page.breakdown.map((l) => l.groupName), [null, 'Pp']);
    },
  );

  test('saving tells the screens at once, before the server answers', () async {
    await seed();
    final seen = <int>[];
    runtime.addListener(() => seen.add(runtime.dataVersion));
    final before = runtime.dataVersion;
    await runtime.flushEditor();
    // The very first announcement already carries the new version, so the
    // open screens redraw from this phone without waiting on the network.
    expect(seen.first, greaterThan(before));
  });
}
