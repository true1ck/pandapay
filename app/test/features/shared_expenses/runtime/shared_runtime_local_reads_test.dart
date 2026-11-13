import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/authenticated_http_client.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/data/shared_http_transport.dart';
import 'package:pandapay/features/shared_expenses/runtime/shared_runtime.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../storage/shared_store_test.dart' as fixtures;

// WP-C8 wave 2: Split screens built from this phone's own records when the
// live fetch fails. The fake network is down for the whole file. Synthetic ids.
const _ctx = fixtures.contextId;
const _friendCtx = '77777777-7777-4777-8777-777777777777';
const _own = '88888888-8888-4888-8888-888888888888';
const _other = '99999999-9999-4999-8999-999999999999';
const _expense = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _revision = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _newCtx = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

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

  Future<void> seedGroup() => runtime.store.applyPage(
    SharedChangePage(
      records: [
        _p('contexts', _ctx, _ctx, {
          'contextId': _ctx,
          'kind': 'group',
          'name': 'Flatmates',
          'state': 'active',
          'membershipState': 'active',
          'committedSequence': '4',
          'createdAt': '2026-11-01T00:00:00Z',
        }),
        _p('contexts', _friendCtx, _friendCtx, {
          'contextId': _friendCtx,
          'kind': 'direct',
          'name': 'Sam',
          'state': 'active',
          'membershipState': 'active',
          'committedSequence': '2',
          'createdAt': '2026-11-02T00:00:00Z',
        }),
        _p('members', _own, _ctx, {
          'contextId': _ctx,
          'memberId': _own,
          'profileId': accountId,
          'role': 'owner',
          'state': 'active',
          'displayName': 'Me',
        }),
        _p('members', _other, _ctx, {
          'contextId': _ctx,
          'memberId': _other,
          'profileId': null,
          'role': 'member',
          'state': 'invited',
          'displayName': 'Priya',
        }),
        _p('expenses', _expense, _ctx, {
          'recordType': 'head',
          'contextId': _ctx,
          'expenseId': _expense,
          'acceptedRevisionId': _revision,
          'accepted': {
            'revisionId': _revision,
            'title': 'Groceries',
            'occurredOn': '2026-11-03',
            'totalMinor': '60000',
            'void': false,
            'bill': null,
            'snapshot': {
              'contributions': [
                {'memberId': _own, 'amountMinor': '60000'},
              ],
              'shares': [
                {'memberId': _own, 'amountMinor': '30000'},
                {'memberId': _other, 'amountMinor': '30000'},
              ],
            },
          },
        }),
        _p('balances', '$_own:$_other', _ctx, {
          'contextId': _ctx,
          'lowMemberId': _own,
          'highMemberId': _other,
          'balanceMinor': '30000',
        }),
      ],
      nextCursor: null,
    ),
    expectedCursor: null,
  );

  test('hub is built from the stored records when the network is down', () async {
    await seedGroup();
    final hub = await runtime.loadHub();
    expect(hub.offline, isTrue);
    expect(hub.groups.items.map((r) => r.title), ['Flatmates']);
    expect(hub.friends.items.map((r) => r.title), ['Sam']);
    expect(hub.summary!.incomplete, isTrue); // totals are not known offline
  });

  test('nothing stored anywhere still ends in an error', () async {
    await expectLater(runtime.loadHub(), throwsA(anything));
    await expectLater(runtime.loadGroup(_ctx), throwsA(anything));
  });

  test('group screen: expenses, balances and totals from stored records', () async {
    await seedGroup();
    final group = await runtime.loadGroup(_ctx);
    expect(group.offline, isTrue);
    expect(group.title, 'Flatmates');
    final row = group.expenses.items.single;
    expect(row.title, 'Groceries');
    expect(row.billTotal.paise, 60000);
    expect(row.yourShare.paise, 30000);
    expect(group.balances.items.single.title, 'Priya');
    expect(group.balances.items.single.balance.owedToYou.paise, 30000);
    expect(group.totals!.billTotal.paise, 60000);
    expect(group.totals!.yourPaid.paise, 60000);
  });

  test('a group created offline shows as waiting, then once, never twice', () async {
    final id = await runtime.submit('context.create', {
      'contextId': _newCtx,
      'contextKind': 'group',
      'name': 'Goa trip',
    });
    var hub = await runtime.loadHub();
    final waiting = hub.groups.items.single;
    expect(waiting.title, 'Goa trip');
    expect(waiting.subtitle, 'Waiting to sync');
    expect(hub.activity.items.first.description, contains('Waiting to sync'));
    // The group screen opens too, with just the owner.
    final screen = await runtime.loadGroup(_newCtx);
    expect(screen.title, 'Goa trip');
    expect(screen.expenses.items, isEmpty);

    // The server confirms: receipt + the context projection arrive.
    final claim = (await runtime.store.claim(
      now: DateTime.now().millisecondsSinceEpoch + 1,
      leaseId: 'w',
    ))!;
    expect(claim.command.operationId, id);
    await runtime.store.complete(
      claim,
      SharedOperationReceipt(
        operationId: id,
        kind: 'context.create',
        requestHash: claim.command.requestHash,
        contextId: _newCtx,
        result: {'status': 'created', 'contextId': _newCtx, 'memberId': _own},
      ),
      [
        _p('contexts', _newCtx, _newCtx, {
          'contextId': _newCtx,
          'kind': 'group',
          'name': 'Goa trip',
          'state': 'active',
          'membershipState': 'active',
          'committedSequence': '1',
          'createdAt': '2026-11-14T00:00:00Z',
        }),
      ],
    );
    hub = await runtime.loadHub();
    final row = hub.groups.items.single;
    expect(row.title, 'Goa trip');
    expect(row.subtitle, isNull);
    expect(hub.activity.items, isEmpty);
  });

  test('an expense added offline to a pending group waits, then keeps the real owner id', () async {
    await runtime.submit('context.create', {
      'contextId': _newCtx,
      'contextKind': 'group',
      'name': 'Goa trip',
    });
    final editor = runtime.offlineEditorContext(_newCtx)!;
    expect(editor.name, 'Goa trip');
    expect(editor.members.map((m) => m.name), ['You']);
    expect(editor.ownMemberId, sharedPendingOwnerMemberId(_newCtx));
    final own = editor.ownMemberId;
    final propose = SharedCommand(
      operationId: _expense,
      kind: 'expense.propose',
      payload: {
        'contextId': _newCtx,
        'expenseId': _revision,
        'revisionId': _other,
        'expectedHeadRevisionId': null,
        'title': 'Taxi',
        'occurredOn': '2026-11-14',
        'snapshot': {
          'currency': 'INR',
          'totalMinor': '40000',
          'contributions': [
            {'memberId': own, 'amountMinor': '40000'},
          ],
          'shares': [
            {'memberId': own, 'amountMinor': '40000'},
          ],
          'memberOrder': [own],
        },
        'bill': {
          'currency': 'INR',
          'totalMinor': '40000',
          'contributions': [
            {'memberId': own, 'amountMinor': '40000'},
          ],
        },
        'sources': <Object?>[],
        'void': false,
      },
    );
    await runtime.store.enqueueExpenseSubmission(
      propose,
      provisional: {'title': 'Taxi'},
    );
    final group = await runtime.loadGroup(_newCtx);
    final row = group.expenses.items.single;
    expect(row.title, 'Taxi');
    expect(row.reviewLabel, 'Waiting to sync');
    expect(row.billTotal.paise, 40000);
    // The create commits with the server's owner id; the queued expense is
    // rewritten to it and is still waiting behind nothing.
    final create = (await runtime.store.claim(
      now: DateTime.now().millisecondsSinceEpoch + 1,
      leaseId: 'w',
    ))!;
    await runtime.store.complete(
      create,
      SharedOperationReceipt(
        operationId: create.command.operationId,
        kind: 'context.create',
        requestHash: create.command.requestHash,
        contextId: _newCtx,
        result: {'status': 'created', 'contextId': _newCtx, 'memberId': _own},
      ),
      const [],
    );
    final sent = (await runtime.store.claim(
      now: DateTime.now().millisecondsSinceEpoch + 2,
      leaseId: 'w',
    ))!;
    expect(sent.command.operationId, _expense);
    expect(sent.command.canonicalJson, contains(_own));
    expect(sent.command.canonicalJson, isNot(contains(own)));
  });

  test('editor context for a stored group lists active and invited people', () async {
    await seedGroup();
    final editor = runtime.offlineEditorContext(_ctx)!;
    expect(editor.ownMemberId, _own);
    expect(editor.members.map((m) => m.name), containsAll(['You', 'Priya']));
    expect(runtime.offlineEditorContext(_newCtx), isNull);
    final roster = await runtime.contextRoster(_ctx);
    expect(roster.ownMemberId, _own);
  });

  test('a friend added offline is in the hub and the editor roster', () async {
    final added = await runtime.addFriend(name: 'Asha');
    final hub = await runtime.loadHub();
    expect(hub.friends.items.single.title, 'Asha');
    expect(hub.friends.items.single.subtitle, 'Waiting to sync');
    final editor = runtime.offlineEditorContext(added.contextId)!;
    expect(editor.members.map((m) => m.name), containsAll(['You', 'Asha']));
  });
}
