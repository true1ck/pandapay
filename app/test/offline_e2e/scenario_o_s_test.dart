// WP-Q1 scenarios o, p, q, r, s: sign-out with queued work, captive Wi-Fi,
// poison rows and gateway answers, an expired token, and a reconnect storm.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local_first/pending_overlays.dart';
import 'package:pandapay/features/account/account_local_first.dart';
import 'package:pandapay/features/account/support_submit.dart';
import 'package:pandapay/features/auth/account_sign_out.dart';
import 'package:pandapay/features/auth/account_sign_out_provider.dart';
import 'package:pandapay/features/cards/add_card_local_first.dart';
import 'package:pandapay/features/sync_status/sync_status_providers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'harness.dart';

String _uuid(int n) =>
    'cccccccc-cccc-4ccc-8ccc-${n.toRadixString(16).padLeft(12, '0')}';

void main() {
  late OfflineApp app;
  setUp(() async => app = await OfflineApp.create());
  tearDown(() => app.dispose());

  /// 3 new expenses, 2 edits and 1 queued command, all made offline.
  Future<({String card, List<String> txns})> queueSomeWork({
    bool backgroundFlush = false,
  }) async {
    final card = app.server.seedCard(last4: '1111')['id'] as String;
    final txns = [
      for (var i = 0; i < 3; i++)
        app.server.seedTransaction(amount: 10.0 + i, cardId: card)['id'] as String,
    ];
    await app.start(backgroundFlush: backgroundFlush);
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();
    final outbox = await app.c.read(outboxRepositoryProvider.future);
    for (var i = 0; i < 3; i++) {
      await outbox.enqueue(
        userCardId: card,
        amount: Money.fromRupees(100.0 + i),
        merchantName: 'Queued $i',
        occurredAt: DateTime.now(),
        clientMutationId: _uuid(i + 1),
      );
    }
    final queue = await app.c.read(syncQueueProvider.future);
    queue.enqueueUpdate(
        entity: 'transactions', entityId: txns[0], fields: {'note': 'n0'});
    queue.enqueueUpdate(
        entity: 'transactions', entityId: txns[1], fields: {'note': 'n1'});
    await queueCommand(app.ref,
        kind: 'ignore_transaction',
        target: txns[2],
        payload: {'id': txns[2], 'reason': 'manual'});
    return (card: card, txns: txns);
  }

  test('o1. sign-out offline with queued work: the report names the counts',
      () async {
    await queueSomeWork();
    final signOut = app.c.read(accountSignOutProvider);
    final report = await signOut.report();
    expect(report.unsynced, 6);
    expect(report.connection, SignOutConnection.offline);
    expect(report.losesSomething, isTrue);
    final byKind = {for (final k in report.pendingKinds) k.plural: k.count};
    expect(byKind['new expenses'], 3);
    expect(byKind['edits'], 2);
    expect(byKind['queued changes'], 1);
    expect(app.server.log, isEmpty);
  });

  test('o2. online sign-out flushes everything first, incl. a queued card add',
      () async {
    await queueSomeWork();
    // A card added offline and a transaction on it.
    final added = await addCardLocalFirst(app.ref,
        cardProductId: 'product-2', last4: '7777');
    final outbox = await app.c.read(outboxRepositoryProvider.future);
    await outbox.enqueue(
      userCardId: added.id,
      amount: Money.fromRupees(55),
      merchantName: 'On new card',
      occurredAt: DateTime.now(),
      clientMutationId: _uuid(40),
    );
    app.server.assignOwnCardIds = true; // remap path, the harder one
    await app.setNet(NetMode.online); // no background flush listener here
    expect(app.pending, 8);

    final signOut = app.c.read(accountSignOutProvider);
    await signOut.flushOutboxes();
    final report = await signOut.report();
    expect(report.unsynced, 0, reason: 'nothing may be lost: ${app.queueDump}');
    expect(report.connection, SignOutConnection.ok);
    expect(app.server.activeTransactions.where((t) =>
        (t['merchant_name'] as String).startsWith('Queued')), hasLength(3));
    final card =
        app.server.cards.values.singleWhere((c) => c['last4'] == '7777');
    expect(
        app.server.activeTransactions
            .singleWhere((t) => t['merchant_name'] == 'On new card')['user_card_id'],
        card['id']);
    expect(app.server.duplicates, isEmpty);
    expect(app.attention, 0);
  });

  test('o3. a rejected session keeps local data; signing in again resumes',
      () async {
    final w = await queueSomeWork(backgroundFlush: true);
    app.refreshRejected = true;
    app.server.mode = NetMode.unauthorized;
    await app.setNet(NetMode.unauthorized);
    app.c.read(outboxFlushRequestProvider.notifier).state++;
    await app.until(() => app.c.read(accessTokenProvider) == null,
        what: 'the rejected session to end');
    await app.idle(200);
    // Nothing was wiped: the queues and the stored rows are still there.
    expect(app.pending, 6);
    final rows = app.db.db.select(
        "SELECT COUNT(*) AS n FROM financial_entities WHERE namespace=?",
        [app.namespace]).single['n'] as int;
    expect(rows, greaterThan(0));

    // The same person signs in again; the server is fine now.
    app.server.mode = NetMode.online;
    app.signInAgain();
    await app.setNet(NetMode.online);
    await app.flushAll();
    expect(app.server.transactions[w.txns[0]]!['note'], 'n0');
    expect(app.server.transactions[w.txns[1]]!['note'], 'n1');
    expect(app.server.transactions[w.txns[2]]!['status'], 'ignored');
    expect(app.server.activeTransactions.where((t) =>
        (t['merchant_name'] as String).startsWith('Queued')), hasLength(3));
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
  });

  test('p. captive Wi-Fi: reads are local and instant, writes queue', () async {
    final card = app.server.seedCard(last4: '1111')['id'] as String;
    app.server.seedTransaction(amount: 25, cardId: card, merchant: 'Cafe',
        at: DateTime.now().subtract(const Duration(hours: 3)));
    await app.start();
    await app.firstSyncOnline();
    await app.stop();

    // The phone is back on a Wi-Fi that answers nothing.
    app.server.mode = NetMode.captive;
    await app.start(online: true);
    app.server.mode = NetMode.captive;
    app.reachableOverride = false;
    app.server.clearLog();
    final watch = Stopwatch()..start();
    final cards = await app.c.read(userCardsProvider.future);
    final txns = await app.c.read(transactionsProvider.future);
    try {
      await app.c.read(budgetsProvider.future);
    } catch (_) {}
    watch.stop();
    expect(cards, hasLength(1));
    expect(txns.map((t) => t.merchantName), contains('Cafe'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'no 15-30 s UI stall on dead Wi-Fi');

    // A write: quick add is purely local, the flush is background work.
    final outbox = await app.c.read(outboxRepositoryProvider.future);
    final write = Stopwatch()..start();
    await outbox.enqueue(
      userCardId: card,
      amount: Money.fromRupees(70),
      merchantName: 'While captive',
      occurredAt: DateTime.now(),
      clientMutationId: _uuid(77),
    );
    expect(write.elapsed, lessThan(const Duration(seconds: 1)));
    expect((await app.summaryNow()).mode, SyncStatusMode.unreachable);
    expect((await app.summaryNow()).pendingCount, 1);

    // Wi-Fi recovers.
    app.reachableOverride = null;
    await app.setNet(NetMode.online);
    await app.flushAll();
    expect(app.server.activeTransactions.where((t) =>
        t['merchant_name'] == 'While captive'), hasLength(1));
    expect(app.pending, 0);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('p2. a write on captive Wi-Fi is queued after its bounded live attempt',
      () async {
    await app.start();
    await app.firstSyncOnline();
    app.server.mode = NetMode.captive;
    final watch = Stopwatch()..start();
    final result = await submitTicketLocalFirst(app.ref,
        accessToken: app.token, kind: 'bug', message: 'Synthetic');
    watch.stop();
    expect(result, AccountWrite.queued);
    expect(watch.elapsed, lessThan(const Duration(seconds: 12)),
        reason: 'the live attempt is bounded (8 s)');
    expect(app.pending, 1);
    await app.setNet(NetMode.online);
    await app.flushAll();
    expect(app.server.tickets, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 90)));

  group('q. what the server says about one row', () {
    Future<String> card() async {
      final id = app.server.seedCard(last4: '1111')['id'] as String;
      await app.start();
      await app.firstSyncOnline();
      await app.goOffline();
      return id;
    }

    Future<void> three(String card) async {
      final outbox = await app.c.read(outboxRepositoryProvider.future);
      for (final (i, name) in ['A', 'Poison', 'C'].indexed) {
        await outbox.enqueue(
          userCardId: card,
          amount: Money.fromRupees(10.0 + i),
          merchantName: name,
          occurredAt: DateTime.now(),
          clientMutationId: _uuid(100 + i),
        );
      }
    }

    test('q1. a 500 for one row: the others go through, it retries later',
        () async {
      final c = await card();
      await three(c);
      app.server.failWhen = (m, p, b) =>
          m == 'POST' && p == '/transactions' && b?['merchantName'] == 'Poison'
              ? 500
              : null;
      await app.goOnline();
      await app.flushAll(expectDrain: false);
      expect(
          app.server.activeTransactions
              .map((t) => t['merchant_name'])
              .where((n) => n == 'A' || n == 'C' || n == 'Poison'),
          unorderedEquals(['A', 'C']));
      expect(app.pending, 1);
      expect(app.attention, 0, reason: 'a 500 is retried, not parked');

      app.server.failWhen = null;
      app.advance(const Duration(hours: 1));
      await app.flushAll();
      expect(app.server.activeTransactions.where((t) =>
          t['merchant_name'] == 'Poison'), hasLength(1));
    });

    test('q2. a 400 for one row parks it; the strip asks for attention',
        () async {
      final c = await card();
      await three(c);
      app.server.failWhen = (m, p, b) =>
          m == 'POST' && p == '/transactions' && b?['merchantName'] == 'Poison'
              ? 400
              : null;
      await app.goOnline();
      await app.flushAll(expectDrain: false);
      expect(app.server.activeTransactions
          .where((t) => t['merchant_name'] == 'A' || t['merchant_name'] == 'C'),
          hasLength(2));
      expect(app.pending, 0);
      expect(app.attention, 1);
      final s = await app.summaryNow();
      expect(s.mode, SyncStatusMode.needsAttention);
      expect(s.attentionCount, 1);
    });

    for (final html in [false, true]) {
      test(
          'q3. ${html ? '404 from a proxy' : '403 phone_required'} does not '
          'delete or park a queued command', () async {
        final c = await card();
        final t = app.server.seedTransaction(amount: 5, cardId: c)['id'] as String;
        await queueCommand(app.ref,
            kind: 'ignore_transaction',
            target: t,
            payload: {'id': t, 'reason': 'manual'});
        if (html) {
          app.server.htmlFailPrefix['/transactions/'] = 404;
        } else {
          app.server.failWhen =
              (m, p, b) => p.endsWith('/ignore') ? 403 : null;
        }
        await app.goOnline();
        await app.flushAll(expectDrain: false);
        expect(app.pending, 1, reason: 'the command is still queued');
        expect(app.attention, 0, reason: 'and not parked');
        expect(app.server.transactions[t]!['status'], 'active');

        app.server.htmlFailPrefix.clear();
        app.server.failWhen = null;
        app.advance(const Duration(hours: 1));
        await app.flushAll();
        expect(app.server.transactions[t]!['status'], 'ignored');
      });
    }
  });

  test('r. long offline, token expired: queued work replays after the refresh',
      () async {
    final w = await queueSomeWork(backgroundFlush: true);
    // The access token stored before going offline no longer works.
    app.server.acceptedTokens = {jwtFor(app.userId, salt: 'r1')};
    await app.goOnline();
    app.c.read(outboxFlushRequestProvider.notifier).state++;
    await app.flushAll();
    expect(app.refreshCalls, greaterThanOrEqualTo(1));
    expect(app.server.unauthorizedAnswers, greaterThan(0));
    expect(app.c.read(accessTokenProvider), isNotNull,
        reason: 'the refresh kept the session');
    expect(app.server.transactions[w.txns[0]]!['note'], 'n0');
    expect(app.server.transactions[w.txns[2]]!['status'], 'ignored');
    expect(app.server.activeTransactions.where((t) =>
        (t['merchant_name'] as String).startsWith('Queued')), hasLength(3));
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
  });

  test('s. reconnect storm: 200 mixed changes drain in order, bounded requests',
      () async {
    final card = app.server.seedCard(last4: '1111')['id'] as String;
    final editIds = [
      for (var i = 0; i < 50; i++)
        app.server.seedTransaction(amount: 1.0 + i, cardId: card)['id'] as String,
    ];
    final ignoreIds = [
      for (var i = 0; i < 40; i++)
        app.server.seedTransaction(amount: 500.0 + i, cardId: card)['id'] as String,
    ];
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final outbox = await app.c.read(outboxRepositoryProvider.future);
    final queue = await app.c.read(syncQueueProvider.future);
    for (var i = 0; i < 80; i++) {
      await outbox.enqueue(
        userCardId: card,
        amount: Money.fromRupees(1000.0 + i),
        merchantName: 'Storm ${i.toString().padLeft(3, '0')}',
        occurredAt: DateTime.utc(2026, 11, 1).add(Duration(minutes: i)),
        clientMutationId: _uuid(1000 + i),
      );
    }
    for (final id in editIds) {
      queue.enqueueUpdate(
          entity: 'transactions', entityId: id, fields: {'note': 'e-$id'});
    }
    for (final id in ignoreIds) {
      await queueCommand(app.ref,
          kind: 'ignore_transaction',
          target: id,
          payload: {'id': id, 'reason': 'manual'});
    }
    for (var i = 0; i < 30; i++) {
      await queueCommand(app.ref,
          kind: OverlayCommand.budgetSave,
          target: 'category|${_uuid(2000 + i)}|monthly',
          payload: {
            'id': _uuid(3000 + i),
            'scope': 'category',
            'scopeRefId': _uuid(2000 + i),
            'period': 'monthly',
            'amountInr': 100.0 + i,
            'rollover': false,
            'clientEditedAt': DateTime.now().toUtc().toIso8601String(),
          });
    }
    expect(app.pending, 200);
    expect((await app.summaryNow()).pendingCount, 200);

    // Reconnect and let the app's own triggers do the work: no extra pokes.
    await app.goOnline();
    await app.until(() => app.pending == 0, what: 'the storm to drain');
    await app.idle(300);

    final posted = app.server.log
        .where((r) => r.method == 'POST' && r.path == '/transactions')
        .map((r) => r.body!['merchantName'] as String)
        .where((n) => n.startsWith('Storm'))
        .toList();
    expect(posted, hasLength(80), reason: 'each queued expense sent once');
    expect(posted, orderedEquals([...posted]..sort()),
        reason: 'sent in the order they were queued');
    expect(app.server.activeTransactions.where((t) =>
        (t['merchant_name'] as String).startsWith('Storm')), hasLength(80));
    for (final id in editIds) {
      expect(app.server.transactions[id]!['note'], 'e-$id');
    }
    for (final id in ignoreIds) {
      expect(app.server.transactions[id]!['status'], 'ignored');
    }
    expect(app.server.activeBudgets.where((b) => b['scope'] == 'category'),
        hasLength(30));
    final pushes = app.server.count('POST', '/sync/push');
    expect(pushes, lessThanOrEqualTo(6), reason: 'edits go in chunks');
    final writes = app.server.log.where((r) => r.method != 'GET').length;
    expect(writes, lessThan(200 + 20), reason: 'bounded: $writes requests');
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
    expect(app.attention, 0);
  }, timeout: const Timeout(Duration(seconds: 120)));
}

