import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/queue_registry.dart';
import 'package:pandapay/data/local/subscription_overrides_store.dart';
import 'package:pandapay/data/local_first/command_outbox.dart';
import 'package:pandapay/data/portable_backup/local_snapshot_source.dart';
import 'package:pandapay/features/sync_state/user_state_pull.dart';
import 'package:pandapay/features/sync_state/user_state_sync.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

// Synthetic data only.
const _ns = 'user:11111111-1111-4111-8111-111111111111';
const _card = '33333333-3333-4333-8333-333333333333';

void main() {
  late AppDatabase db;
  late FinancialStore store;
  late CommandOutbox outbox;
  late UserStateLocal local;
  late SubscriptionOverridesStore subs;

  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    outbox = CommandOutbox(db, namespace: _ns);
    local = UserStateLocal(store, _ns);
    subs = SubscriptionOverridesStore(db, _ns);
    resetUserStateUnsupported();
    UserStatePuller.resetCursors();
  });
  tearDown(() => db.close());

  UserStateItem bill(String key, int ms, {String card = _card, bool del = false}) =>
      UserStateItem(
        kind: UserStateKind.billCardAssignment,
        key: key,
        payload: del
            ? null
            : {'userCardId': card, 'billKey': key, 'amountDuePaise': 1200000},
        clientEditedAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        deleted: del,
      );

  void saveBill(String key) => store.saveCardBillAssignment(
    _ns,
    key,
    userCardId: _card,
    amountDuePaise: 500000,
    dueDate: DateTime.utc(2026, 12, 1),
  );

  group('merge (last writer wins)', () {
    test('serverWins rules', () {
      expect(serverWins(serverMs: 5), isTrue);
      expect(serverWins(localMs: 4, serverMs: 5), isTrue);
      expect(serverWins(localMs: 5, serverMs: 5), isFalse);
      expect(serverWins(localMs: 1, pendingMs: 9, serverMs: 5), isFalse);
    });

    test('a newer server item overwrites the local one', () {
      saveBill('obs1');
      final localMs = local.read(UserStateKind.billCardAssignment, 'obs1')!.editedAtMs;
      expect(applyUserStateItem(local, bill('obs1', localMs + 1000)), isTrue);
      expect(
        local.read(UserStateKind.billCardAssignment, 'obs1')!.payload['amountDuePaise'],
        1200000,
      );
    });

    test('a newer local edit is kept', () {
      saveBill('obs1');
      final localMs = local.read(UserStateKind.billCardAssignment, 'obs1')!.editedAtMs;
      expect(applyUserStateItem(local, bill('obs1', localMs - 1000)), isFalse);
      expect(
        local.read(UserStateKind.billCardAssignment, 'obs1')!.payload['amountDuePaise'],
        500000,
      );
    });

    test('a tombstone deletes unless a newer local edit exists', () {
      saveBill('obs1');
      final ms = local.read(UserStateKind.billCardAssignment, 'obs1')!.editedAtMs;
      expect(applyUserStateItem(local, bill('obs1', ms - 1, del: true)), isFalse);
      expect(local.read(UserStateKind.billCardAssignment, 'obs1'), isNotNull);
      expect(applyUserStateItem(local, bill('obs1', ms + 1, del: true)), isTrue);
      expect(local.read(UserStateKind.billCardAssignment, 'obs1'), isNull);
    });

    test('a queued local delete beats an older server copy', () {
      expect(
        applyUserStateItem(local, bill('obs1', 1000), pendingMs: 2000),
        isFalse,
      );
      expect(local.read(UserStateKind.billCardAssignment, 'obs1'), isNull);
    });

    test('an item naming a card the phone lacks is kept', () {
      expect(applyUserStateItem(local, bill('obs9', 1000, card: 'unknown-card')), isTrue);
      expect(
        local.read(UserStateKind.billCardAssignment, 'obs9')!.payload['userCardId'],
        'unknown-card',
      );
      expect(store.cardBillAssignments(_ns)['obs9'], isNotNull);
    });

    test('an applied item does not queue a push', () {
      applyUserStateItem(local, bill('obs1', 1000));
      expect(outbox.pendingCount, 0);
    });

    test('bank balance and subscription override round trip', () {
      final bank = UserStateItem(
        kind: UserStateKind.bankBalance,
        key: 'hdfc:1234',
        payload: {'amount': 1234.5, 'label': 'hdfc:1234'},
        clientEditedAt: DateTime.utc(2026, 11, 1),
        deleted: false,
      );
      expect(applyUserStateItem(local, bank), isTrue);
      expect(store.manualBankBalances(_ns)['hdfc:1234']!.balance.paise, 123450);
      final sub = UserStateItem(
        kind: UserStateKind.subscriptionOverride,
        key: 'v2:abc',
        payload: {'hidden': true},
        clientEditedAt: DateTime.utc(2026, 11, 1),
        deleted: false,
      );
      expect(applyUserStateItem(local, sub), isTrue);
      expect(subs.all()['v2:abc'], {'hidden': true});
    });
  });

  group('push queue', () {
    test('a local change queues one put carrying clientEditedAt', () {
      saveBill('obs1');
      expect(enqueueUserState(outbox, local, UserStateKind.billCardAssignment, 'obs1'), isTrue);
      final c = outbox.pendingOf(UserStateCommand.kinds).single;
      expect(c.kind, UserStateCommand.put);
      expect(c.target, 'bill_card_assignment/obs1');
      expect(c.payload['clientEditedAt'], isA<String>());
      expect((c.payload['payload'] as Map)['userCardId'], _card);
    });

    test('put then delete of the same item coalesces to the delete', () {
      store.setManualBankBalance(_ns, issuer: 'hdfc', accountLast4: '1234', balance: Money.fromRupees(10));
      enqueueUserState(outbox, local, UserStateKind.bankBalance, 'hdfc:1234');
      store.clearManualBankBalance(_ns, issuer: 'hdfc', accountLast4: '1234');
      enqueueUserState(outbox, local, UserStateKind.bankBalance, 'hdfc:1234');
      final all = outbox.pendingOf(UserStateCommand.kinds);
      expect(all, hasLength(1));
      expect(all.single.kind, UserStateCommand.delete);
    });

    test('bank payload keeps the local shape and adds amount and label', () {
      store.setManualBankBalance(_ns, issuer: 'hdfc', accountLast4: '1234', balance: Money.fromRupees(10));
      final p = local.read(UserStateKind.bankBalance, 'hdfc:1234')!.payload;
      expect(p['amount'], 10);
      expect(p['label'], 'hdfc:1234');
      expect(p['accountLabel'], 'hdfc:1234');
      expect(p['balance_paise'], 1000);
    });

    test('the sign-out report counts a queued user_state_put', () {
      saveBill('obs1');
      enqueueUserState(outbox, local, UserStateKind.billCardAssignment, 'obs1');
      expect(QueueRegistry(db).countsFor('command_outbox', _ns).total, 1);
    });

    test('kill and restart keeps the queue', () {
      saveBill('obs1');
      enqueueUserState(outbox, local, UserStateKind.billCardAssignment, 'obs1');
      final again = CommandOutbox(db, namespace: _ns);
      expect(again.pendingOf(UserStateCommand.kinds), hasLength(1));
    });
  });

  group('handlers', () {
    late List<http.Request> calls;
    Map<String, CommandHandler> handlers(http.Response Function(http.Request) respond) {
      calls = [];
      final client = MockClient((r) async {
        calls.add(r);
        return respond(r);
      });
      final api = UserStateApi(apiBaseUrl: 'https://x.test', accessToken: 't', client: client);
      return userStateHandlers(api: () async => api, local: () async => local);
    }

    Future<int> flushWith(http.Response Function(http.Request) respond) {
      saveBill('obs1');
      enqueueUserState(outbox, local, UserStateKind.billCardAssignment, 'obs1');
      return outbox.flush(handlers(respond));
    }

    test('200 delivers and removes the command; body shape', () async {
      expect(await flushWith((_) => http.Response('{"item":{}}', 200)), 1);
      expect(outbox.pendingCount, 0);
      final r = calls.single;
      expect(r.method, 'PUT');
      expect(r.url.path, '/user-state/bill_card_assignment/obs1');
      final body = jsonDecode(r.body) as Map;
      expect(body.keys.toSet(), {'payload', 'clientEditedAt'});
      expect((body['clientEditedAt'] as String).endsWith('Z'), isTrue);
    });

    test('superseded adopts the server item without re-enqueueing', () async {
      final newer = DateTime.now().toUtc().add(const Duration(hours: 1));
      final n = await flushWith(
        (_) => http.Response(
          jsonEncode({
            'superseded': true,
            'item': {
              'kind': 'bill_card_assignment',
              'key': 'obs1',
              'payload': {'userCardId': _card, 'billKey': 'obs1', 'amountDuePaise': 777},
              'clientEditedAt': newer.toIso8601String(),
              'deleted': false,
            },
          }),
          200,
        ),
      );
      expect(n, 1);
      expect(local.read(UserStateKind.billCardAssignment, 'obs1')!.payload['amountDuePaise'], 777);
      expect(outbox.pendingCount, 0);
    });

    test('404 (old server) stops, does not park, and is not asked again', () async {
      expect(await flushWith((_) => http.Response('{"error":"Not Found"}', 404)), 0);
      expect(outbox.parked(), isEmpty);
      expect(outbox.pendingCount, 1);
      expect(userStateUnsupported, isTrue);
      final before = calls.length;
      db.db.execute('UPDATE command_outbox SET next_attempt_at=0');
      await outbox.flush(handlers((_) => http.Response('{}', 200)));
      expect(calls.length, 0, reason: 'no request after the first 404');
      expect(before, 1);
      expect(outbox.parked(), isEmpty);
    });

    test('422 parks with a plain reason', () async {
      await flushWith((_) => http.Response('{"error":"invalid_payload"}', 422));
      final parked = outbox.parked().single;
      expect(parked.error, contains('422'));
      expect(parked.error, isNot(contains('1200000')));
    });

    test('503 retries with backoff', () async {
      await flushWith((_) => http.Response('{"error":"encryption_unavailable"}', 503));
      expect(outbox.parked(), isEmpty);
      expect(outbox.pendingCount, 1);
    });

    test('offline then reconnect sends exactly one PUT per key', () async {
      saveBill('obs1');
      enqueueUserState(outbox, local, UserStateKind.billCardAssignment, 'obs1');
      saveBill('obs1');
      enqueueUserState(outbox, local, UserStateKind.billCardAssignment, 'obs1');
      var offline = true;
      final h = handlers((_) => http.Response('{}', 200));
      final failing = {
        for (final e in h.entries)
          e.key: (Map<String, Object?> p) async {
            if (offline) throw http.ClientException('down');
            return e.value(p);
          },
      };
      await outbox.flush(failing);
      expect(outbox.pendingCount, 1);
      offline = false;
      await outbox.flush(failing);
      expect(outbox.pendingCount, 0);
      expect(calls.where((c) => c.method == 'PUT'), hasLength(1));
    });
  });

  group('pull', () {
    UserStateApi apiReturning(List<http.Response> pages, List<Uri> seen) {
      var i = 0;
      return UserStateApi(
        apiBaseUrl: 'https://x.test',
        accessToken: 't',
        client: MockClient((r) async {
          seen.add(r.url);
          return pages[i++ < pages.length ? i - 1 : pages.length - 1];
        }),
      );
    }

    String page(List<Map<String, Object?>> items, String cursor) =>
        jsonEncode({'items': items, 'cursor': cursor});

    test('first pull on a new device populates everything', () async {
      final seen = <Uri>[];
      final api = apiReturning([
        http.Response(
          page([
            {
              'kind': 'bill_card_assignment',
              'key': 'obs1',
              'payload': {'userCardId': 'card-not-here-yet', 'billKey': 'obs1'},
              'clientEditedAt': '2026-11-01T00:00:00Z',
              'deleted': false,
            },
            {
              'kind': 'bank_balance',
              'key': 'hdfc:1234',
              'payload': {'amount': 50, 'label': 'hdfc:1234'},
              'clientEditedAt': '2026-11-01T00:00:00Z',
              'deleted': false,
            },
            {
              'kind': 'subscription_override',
              'key': 'manual:abc',
              'payload': {'manual': true, 'displayName': 'Synthetic', 'amountInr': 99.0, 'cadenceDays': 30},
              'clientEditedAt': '2026-11-01T00:00:00Z',
              'deleted': false,
            },
          ], 'c1'),
          200,
        ),
      ], seen);
      final n = await UserStatePuller(api: api, local: local, commands: outbox).pull();
      expect(n, 3);
      expect(seen.single.queryParameters.containsKey('since'), isFalse);
      expect(store.cardBillAssignments(_ns)['obs1']!['user_card_id'], 'card-not-here-yet');
      expect(store.manualBankBalances(_ns)['hdfc:1234']!.balance.paise, 5000);
      expect(subs.all().containsKey('manual:abc'), isTrue);
      expect(outbox.pendingCount, 0, reason: 'pulled items must not queue pushes');
      // Second pull uses the cursor.
      await UserStatePuller(api: api, local: local, commands: outbox).pull();
      expect(seen.last.queryParameters['since'], 'c1');
    });

    test('a queued local edit is not overwritten by an older server copy', () async {
      saveBill('obs1');
      enqueueUserState(outbox, local, UserStateKind.billCardAssignment, 'obs1');
      final api = apiReturning([
        http.Response(
          page([
            {
              'kind': 'bill_card_assignment',
              'key': 'obs1',
              'payload': {'userCardId': _card, 'amountDuePaise': 1},
              'clientEditedAt': '2020-01-01T00:00:00Z',
              'deleted': false,
            },
          ], 'c1'),
          200,
        ),
      ], []);
      expect(await UserStatePuller(api: api, local: local, commands: outbox).pull(), 0);
      expect(store.cardBillAssignments(_ns)['obs1']!['amount_due_paise'], 500000);
    });

    test('undecryptable items are skipped, never applied or deleted', () async {
      store.setManualBankBalance(_ns, issuer: 'hdfc', accountLast4: '1234', balance: Money.fromRupees(10));
      final api = apiReturning([
        http.Response(
          jsonEncode({
            'items': [
              {
                'kind': 'bank_balance',
                'key': 'hdfc:1234',
                'payload': null,
                'clientEditedAt': '2099-01-01T00:00:00Z',
                'deleted': false,
                'undecryptable': true,
              },
            ],
            'cursor': '1',
            'hasMore': false,
          }),
          200,
        ),
      ], []);
      expect(await UserStatePuller(api: api, local: local, commands: outbox).pull(), 0);
      expect(store.manualBankBalances(_ns)['hdfc:1234']!.balance.paise, 1000);
    });

    test('pages until hasMore is false, cursor kept opaque', () async {
      final seen = <Uri>[];
      final api = apiReturning([
        http.Response(jsonEncode({'items': [], 'cursor': 'abc', 'hasMore': true}), 200),
        http.Response(jsonEncode({'items': [], 'cursor': 'def', 'hasMore': false}), 200),
      ], seen);
      await UserStatePuller(api: api, local: local, commands: outbox).pull();
      expect(seen, hasLength(2));
      expect(seen.last.queryParameters['since'], 'abc');
    });

    test('404 on an old server marks the feature unsupported', () async {
      final api = apiReturning([http.Response('{"error":"Not Found"}', 404)], []);
      await expectLater(
        UserStatePuller(api: api, local: local, commands: outbox).pull(),
        throwsA(isA<UserStateUnsupported>()),
      );
      expect(userStateUnsupported, isTrue);
      expect(await UserStatePuller(api: api, local: local, commands: outbox).pull(), 0);
    });

    test('5xx surfaces as a retryable ApiException', () async {
      final api = apiReturning([http.Response('{}', 503)], []);
      await expectLater(
        UserStatePuller(api: api, local: local, commands: outbox).pull(),
        throwsA(isA<ApiException>()),
      );
    });
  });

  test('backup exclusions say the three kinds are synced', () {
    for (final name in ['bill_card_assignments', 'manual_bank_balances', 'subscription_overrides']) {
      final line = LocalPortableSnapshotSource.declaredExclusions.singleWhere((e) => e.startsWith('$name ('));
      expect(line, contains('synced to the server (user_local_state)'));
    }
  });
}
