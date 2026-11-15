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

// Splits opens from this phone: the network is down for the whole file.
const _ctx = fixtures.contextId;
const _own = '88888888-8888-4888-8888-888888888888';
const _priya = '99999999-9999-4999-8999-999999999999';
const _expense = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _revision = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _priyaProfile = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _dinner = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _dinnerV1 = 'dddddddd-0000-4ddd-8ddd-000000000001';
const _dinnerV2 = 'dddddddd-0000-4ddd-8ddd-000000000002';
const _dinnerV3 = 'dddddddd-0000-4ddd-8ddd-000000000003';
const _settlement = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

SharedProjection _p(String entity, String id, Map<String, Object?> payload) =>
    SharedProjection(
      entity: entity,
      id: id,
      contextId: _ctx,
      revision: 1,
      payload: payload,
    );

void main() {
  late AppDatabase db;
  late SharedExpensesRuntime runtime;
  late AuthenticatedHttpClient client;
  final accountId = fixtures.accountA.substring(5);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final token =
        'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': accountId}))).replaceAll('=', '')}.signature';
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
    await runtime.store.applyPage(
      SharedChangePage(
        records: [
          _p('contexts', _ctx, {
            'contextId': _ctx,
            'kind': 'group',
            'name': 'Flatmates',
            'state': 'active',
            'membershipState': 'active',
            'committedSequence': '4',
          }),
          _p('members', _own, {
            'contextId': _ctx,
            'memberId': _own,
            'profileId': accountId,
            'role': 'owner',
            'state': 'active',
            'displayName': 'Me',
          }),
          _p('members', _priya, {
            'contextId': _ctx,
            'memberId': _priya,
            'profileId': _priyaProfile,
            'role': 'member',
            'state': 'active',
            'displayName': 'Priya',
          }),
          _p('expenses', _expense, {
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
                  {'memberId': _priya, 'amountMinor': '60000'},
                ],
                'shares': [
                  {'memberId': _own, 'amountMinor': '30000'},
                  {'memberId': _priya, 'amountMinor': '30000'},
                ],
              },
            },
          }),
          // Priya paid ₹600 split equally: you owe her ₹300.
          _p('balances', '$_own:$_priya', {
            'contextId': _ctx,
            'lowMemberId': _own,
            'highMemberId': _priya,
            'balanceMinor': '-30000',
          }),
        ],
        nextCursor: null,
      ),
      expectedCursor: null,
    );
  });
  tearDown(() {
    runtime.dispose();
    client.close();
    db.close();
  });

  test('an expense opens from the phone with no network', () async {
    final page = await runtime.runCacheOnly(
      () => runtime.expenseReviewPage(_ctx, _expense),
      allowLocal: true,
    );
    final row = (page['items'] as List).single as Map;
    expect(row['title'], 'Groceries');
    expect(row['reviewState'], 'accepted');
    expect(
      row['canRespond'],
      isFalse,
      reason: 'only the server may offer that',
    );
    expect(row['yourShareMinor'], '30000');
    expect((page['memberNames'] as Map)[_priya], 'Priya');
  });

  test('a pop-up gets the people in a split with no network', () async {
    final roster = await runtime.quickRoster(_ctx);
    expect(roster.members.map((m) => m.name), containsAll(['You', 'Priya']));
  });

  Future<void> seedHistory() => runtime.store.applyPage(
    SharedChangePage(
      records: [
        // The first version of "Dinner": Priya paid 500, split equally.
        _p('expenses', '$_dinner:$_dinnerV1', {
          'recordType': 'revision',
          'contextId': _ctx,
          'expenseId': _dinner,
          'revisionId': _dinnerV1,
          'authorProfileId': _priyaProfile,
          'expectedHeadRevisionId': null,
          'title': 'Dinner',
          'occurredOn': '2026-11-05',
          'totalMinor': '50000',
          'void': false,
          'snapshot': {
            'contributions': [
              {'memberId': _priya, 'amountMinor': '50000'},
            ],
            'shares': [
              {'memberId': _own, 'amountMinor': '25000'},
              {'memberId': _priya, 'amountMinor': '25000'},
            ],
          },
        }),
        // Edited: renamed, now 600, and a different date.
        _p('expenses', '$_dinner:$_dinnerV2', {
          'recordType': 'revision',
          'contextId': _ctx,
          'expenseId': _dinner,
          'revisionId': _dinnerV2,
          'authorProfileId': _priyaProfile,
          'expectedHeadRevisionId': _dinnerV1,
          'title': 'Team dinner',
          'occurredOn': '2026-11-06',
          'totalMinor': '60000',
          'void': false,
          'snapshot': {
            'contributions': [
              {'memberId': _priya, 'amountMinor': '60000'},
            ],
            'shares': [
              {'memberId': _own, 'amountMinor': '30000'},
              {'memberId': _priya, 'amountMinor': '30000'},
            ],
          },
        }),
        _p('activity', 'ev-settle', {
          'contextId': _ctx,
          'eventId': 'ev-settle',
          'kind': 'settlement.reported',
          'originId': _settlement,
          'actorProfileId': accountId,
          'payload': {
            'settlementId': _settlement,
            'payerMemberId': _own,
            'receiverMemberId': _priya,
            'amountMinor': '30000',
          },
        }),
      ],
      nextCursor: null,
    ),
    expectedCursor: null,
  );

  test(
    'a new expense says who added it, the amount, who paid and your part',
    () async {
      await seedHistory();
      final card = runtime.describeActivity({
        'contextId': _ctx,
        'contextName': 'Flatmates',
        'kind': 'expense.accepted',
        'originId': _dinnerV1,
        'createdAt': '2026-11-05T10:00:00Z',
      });
      expect(card.description, 'Priya added “Dinner”');
      expect(
        card.details.single,
        '₹500.00 · Priya paid · split equally · 5 Nov 2026',
      );
      expect(card.impact, 'You owe Priya ₹250.00');
      expect(card.category, 'expense');
      expect(card.contextLabel, 'Flatmates');
    },
  );

  test('an edit says what changed, from what to what', () async {
    await seedHistory();
    final card = runtime.describeActivity({
      'contextId': _ctx,
      'contextName': 'Flatmates',
      'kind': 'expense.accepted',
      'originId': _dinnerV2,
      'createdAt': '2026-11-06T10:00:00Z',
    });
    expect(card.description, 'Priya renamed “Dinner” to “Team dinner”');
    expect(card.details, [
      'Name: “Dinner” → “Team dinner”',
      'Amount: ₹500.00 → ₹600.00',
      'Date: 5 Nov 2026 → 6 Nov 2026',
      'and 1 more changes',
    ]);
    expect(card.impact, 'You owe Priya ₹300.00');
  });

  test(
    'an edit that keeps the name says edited, with only what moved',
    () async {
      await seedHistory();
      // The same expense edited again, only the amount.
      await runtime.store.applyPage(
        SharedChangePage(
          records: [
            _p('expenses', '$_dinner:$_dinnerV3', {
              'recordType': 'revision',
              'contextId': _ctx,
              'expenseId': _dinner,
              'revisionId': _dinnerV3,
              'authorProfileId': accountId,
              'expectedHeadRevisionId': _dinnerV2,
              'title': 'Team dinner',
              'occurredOn': '2026-11-06',
              'totalMinor': '80000',
              'void': false,
              'snapshot': {
                'contributions': [
                  {'memberId': _priya, 'amountMinor': '80000'},
                ],
                'shares': [
                  {'memberId': _own, 'amountMinor': '40000'},
                  {'memberId': _priya, 'amountMinor': '40000'},
                ],
              },
            }),
          ],
          nextCursor: null,
        ),
        expectedCursor: null,
      );
      final card = runtime.describeActivity({
        'contextId': _ctx,
        'contextName': 'Flatmates',
        'kind': 'expense.accepted',
        'originId': _dinnerV3,
        'createdAt': '2026-11-07T10:00:00Z',
      });
      expect(card.description, 'You edited “Team dinner”');
      expect(card.details, [
        'Amount: ₹600.00 → ₹800.00',
        'Your share: ₹300.00 → ₹400.00',
      ]);
    },
  );

  test(
    'a payment says who paid whom, how much, and what happens next',
    () async {
      await seedHistory();
      final card = runtime.describeActivity({
        'contextId': _ctx,
        'contextName': 'Flatmates',
        'kind': 'settlement.reported',
        'originId': _settlement,
        'createdAt': '2026-11-08T10:00:00Z',
      });
      expect(card.description, 'You paid Priya ₹300.00');
      expect(card.details, ['Waiting for the other person to confirm']);
      expect(card.category, 'payment');
    },
  );

  test('people and groups say who, and where', () async {
    final joined = runtime.describeActivity({
      'contextId': _ctx,
      'contextName': 'Flatmates',
      'kind': 'membership.claimed',
      'originId': _priya,
      'createdAt': '2026-11-01T10:00:00Z',
    });
    expect(joined.description, 'Priya joined');
    expect(joined.details, ['In “Flatmates”']);
    final invited = runtime.describeActivity({
      'contextId': _ctx,
      'contextName': 'Flatmates',
      'kind': 'member.invited',
      'originId': _priya,
      'createdAt': '2026-11-01T09:00:00Z',
    });
    expect(invited.description, 'Someone invited Priya');
    expect(invited.details.first, 'To join “Flatmates”');
    final created = runtime.describeActivity({
      'contextId': _ctx,
      'contextName': 'Flatmates',
      'kind': 'context.created',
      'originId': _ctx,
      'createdAt': '2026-11-01T08:00:00Z',
    });
    expect(created.description, 'Someone created the group “Flatmates”');
  });

  test('an event the phone has no record of still says something useful', () {
    final card = runtime.describeActivity({
      'contextId': _ctx,
      'contextName': 'Flatmates',
      'kind': 'expense.accepted',
      'originId': 'unknown-revision',
      'createdAt': '2026-11-01T08:00:00Z',
    });
    expect(card.description, 'An expense was added or changed');
    expect(card.contextLabel, 'Flatmates');
  });

  test(
    'a group page knows its own balance, so its top line is never empty',
    () async {
      final group = await runtime.loadGroup(_ctx);
      expect(group.summary, isNotNull);
      expect(group.summary!.youOwe.paise, 30000);
      expect(group.summary!.owedToYou.paise, 0);
      expect(group.summary!.netBalance.paise, -30000);
    },
  );
}
