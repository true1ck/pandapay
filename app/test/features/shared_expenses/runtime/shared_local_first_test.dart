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

  test('activity says who did what, to which expense, and what it meant', () {
    final added = runtime.describeActivity({
      'contextId': _ctx,
      'kind': 'expense.accepted',
      'actorProfileId': _priyaProfile,
      'createdAt': '2026-11-03T10:00:00Z',
      'payload': {'expenseId': _expense, 'revisionId': _revision},
    });
    expect(added.description, 'Priya added “Groceries”');
    expect(added.impactLabel, 'You borrowed');
    expect(added.impactAmount!.paise, 30000);

    final old = runtime.describeActivity({
      'contextId': _ctx,
      'kind': 'expense.accepted',
      'actorProfileId': accountId,
      'createdAt': '2026-11-02T10:00:00Z',
      'payload': {'expenseId': _expense, 'revisionId': 'an-older-revision'},
    });
    expect(old.description, 'You added “Groceries”');
    expect(
      old.impactAmount,
      isNull,
      reason: "today's figure is not that event's",
    );

    final paid = runtime.describeActivity({
      'contextId': _ctx,
      'kind': 'settlement.reported',
      'actorProfileId': accountId,
      'createdAt': '2026-11-04T10:00:00Z',
      'payload': {
        'payerMemberId': _own,
        'receiverMemberId': _priya,
        'amountMinor': '30000',
      },
    });
    expect(
      paid.description,
      'You paid Priya ₹300.00 · waiting for confirmation',
    );

    final joined = runtime.describeActivity({
      'contextId': _ctx,
      'kind': 'membership.claimed',
      'createdAt': '2026-11-01T10:00:00Z',
      'payload': {'memberId': _priya},
    });
    expect(joined.description, 'Priya joined');
  });

  test('a group page knows its own balance, so its top line is never empty', () async {
    final group = await runtime.loadGroup(_ctx);
    expect(group.summary, isNotNull);
    expect(group.summary!.youOwe.paise, 30000);
    expect(group.summary!.owedToYou.paise, 0);
    expect(group.summary!.netBalance.paise, -30000);
  });
}
