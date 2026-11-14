// Scenario v: review fixes for the local-first queues. Successive partial
// edits accumulate, a refused edit stops overlaying, a command naming a
// phone-only card waits for it, and a 503 Retry-After stops every queue.
// Synthetic data only.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/connectivity/server_backoff.dart';
import 'package:pandapay/features/cards/add_card_local_first.dart';
import 'package:pandapay/features/cards/card_state_local_first.dart';
import 'package:pandapay/features/payments/payment_method_command.dart';

import 'harness.dart';

void main() {
  late OfflineApp app;
  setUp(() async => app = await OfflineApp.create());
  tearDown(() async {
    ServerBackoff.process.resetForTest();
    await app.dispose();
  });

  Future<void> edit(String id, Map<String, Object?> fields) => queueCommand(
    app.ref,
    kind: PaymentMethodCommand.setTyped,
    target: id,
    payload: {'id': id, ...fields},
  );

  group('v1. two partial edits of one transaction both reach the server', () {
    final cases = <String, (Map<String, Object?>, String, Object?)>{
      'category': ({'categoryId': 'cat-food'}, 'category_id', 'cat-food'),
      'date': (
        {'occurredAt': '2026-11-12T08:00:00.000Z'},
        'occurred_at',
        '2026-11-12T08:00:00.000Z',
      ),
      'card': ({'userCardId': 'CARD'}, 'user_card_id', 'CARD'),
    };
    for (final c in cases.entries) {
      test('amount, then ${c.key}', () async {
        final card = app.server.seedCard(nickname: 'Daily', last4: '1111');
        final t = app.server.seedTransaction(amount: 500);
        await app.start();
        await app.firstSyncOnline();
        await app.goOffline();

        final second = {
          for (final e in c.value.$1.entries)
            e.key: e.value == 'CARD' ? card['id'] : e.value,
        };
        await edit(t['id'] as String, {'amountInr': 700});
        // The edit screen reopens on the overlaid row and sends only the
        // field that now differs.
        await edit(t['id'] as String, second);

        await app.goOnline();
        await app.flushAll();
        final row = app.server.transactions[t['id']]!;
        expect(row['amount_inr'], 700, reason: 'the first edit must survive');
        expect(
          row[c.value.$2],
          c.value.$3 == 'CARD' ? card['id'] : c.value.$3,
        );
      });
    }
  });

  test('v2. a refused edit stops overlaying; retry un-parks it', () async {
    final t = app.server.seedTransaction(amount: 500);
    final id = t['id'] as String;
    await app.start();
    await app.firstSyncOnline();
    app.server.failWhen =
        (m, p, b) => m == 'PATCH' && p == '/transactions/$id' ? 422 : null;
    await edit(id, {'amountInr': 700});
    await app.flushAll(expectDrain: false);
    app.advance(const Duration(hours: 1));
    await app.flushAll(expectDrain: false);

    final commands = await app.c.read(commandOutboxProvider.future);
    expect(commands.parkedCount, 1, reason: app.commandRows().toString());
    final store = (await app.c.read(responseCacheProvider.future)).financialStore;
    final ns = app.namespace;
    expect(store.hasQueuedTransactionEdit(ns, id), isFalse);
    final shown = store
        .entities(ns, 'transactions')
        .firstWhere((r) => r['id'] == id);
    expect(shown['amount_inr'], 500, reason: 'the server value wins again');

    app.server.failWhen = null;
    commands.retryParked(commands.parked().single.id);
    await app.flushAll();
    expect(app.server.transactions[id]!['amount_inr'], 700);
  });

  test('v3. an edit naming a card only on the phone is held, never parked',
      () async {
    final t = app.server.seedTransaction(amount: 500);
    final id = t['id'] as String;
    await app.start();
    await app.firstSyncOnline();
    var failAdd = true;
    app.server.failWhen = (m, p, b) {
      if (failAdd && m == 'POST' && p == '/user-cards') return 500;
      final card = b?['userCardId'];
      if (m == 'PATCH' &&
          card != null &&
          !app.server.cards.containsKey(card)) {
        return 422;
      }
      return null;
    };
    final added = await addCardLocalFirst(
      app.ref,
      cardProductId: 'product-2',
      nickname: 'Travel',
      last4: '4444',
    );
    expect(added.queued, isTrue);
    await edit(id, {'userCardId': added.id});
    await app.flushAll(expectDrain: false);

    final commands = await app.c.read(commandOutboxProvider.future);
    expect(commands.parkedCount, 0, reason: app.commandRows().toString());
    expect(app.server.transactions[id]!['user_card_id'], isNull);

    failAdd = false;
    app.advance(const Duration(hours: 1));
    await app.flushAll();
    expect(app.server.transactions[id]!['user_card_id'], added.id);
    expect(commands.parkedCount, 0);
  });

  test('v9. a restore the server refuses (409) parks and the card follows the server',
      () async {
    final card = app.server.seedCard(nickname: 'Old', last4: '2222');
    final id = card['id'] as String;
    await app.start();
    await app.firstSyncOnline();
    expect(await setCardArchived(app.ref, id, archived: true), CardChange.queued);
    await app.flushAll();
    expect(app.server.cards[id]!['is_archived'], isTrue);

    app.server.failWhen =
        (m, p, b) => p == '/user-cards/$id/unarchive' ? 409 : null;
    await setCardArchived(app.ref, id, archived: false);
    await app.flushAll(expectDrain: false);

    final commands = await app.c.read(commandOutboxProvider.future);
    expect(commands.parkedCount, 1, reason: app.commandRows().toString());
    final store = (await app.c.read(responseCacheProvider.future)).financialStore;
    final local = store
        .entities(app.namespace, 'cards')
        .firstWhere((c) => c['id'] == id);
    expect(local['is_archived'], isTrue, reason: 'the server kept it archived');
  });

  test('v7. a save made while a pass is running is sent by the next pass, not dropped',
      () async {
    final a = app.server.seedTransaction(amount: 10)['id'] as String;
    final b = app.server.seedTransaction(amount: 20)['id'] as String;
    await app.start();
    await app.firstSyncOnline();
    final gate = Completer<http.Response>();
    app.server.extraRoutes['PUT /transactions/$a/spend-exclusion'] =
        (_) => gate.future;
    Future<void> exclude(String id) => queueCommand(
      app.ref,
      kind: OutboxCommand.setSpendExclusion,
      target: id,
      payload: {'id': id, 'excluded': true},
    );
    await exclude(a);
    await app.idle(200); // the pass is now waiting on A's reply
    await exclude(b); // asks for a flush while one is running
    await app.idle(100);
    // The server refuses A for good; nothing delivered, so nothing but the
    // remembered request can send B soon (the idle re-check is minutes away).
    gate.complete(http.Response('{"error":"x"}', 422));
    await app.until(
      () => app.server.transactions[b]!['exclude_from_spend'] == true,
      what: 'B to be sent by the pass that followed',
    );
  });

  test('v8. adding a card never waits on the network', () async {
    await app.start();
    await app.firstSyncOnline();
    // The server is slow to answer the add.
    final gate = Completer<http.Response>();
    app.server.extraRoutes['POST /user-cards'] = (_) => gate.future;
    final added = await addCardLocalFirst(
      app.ref,
      cardProductId: 'product-2',
      nickname: 'Travel',
      last4: '4444',
    ).timeout(const Duration(seconds: 1));
    expect(added.queued, isTrue);
    gate.complete(http.Response('{"error":"x"}', 500));
    app.server.extraRoutes.clear();
    app.advance(const Duration(hours: 1));
    await app.flushAll();
    expect(
      app.server.cards.values.where((c) => c['last4'] == '4444'),
      hasLength(1),
    );
  });

  test('v4. one 503 Retry-After stops every queue until the pause ends',
      () async {
    final ids = [
      for (var i = 0; i < 20; i++)
        app.server.seedTransaction(amount: 100.0 + i)['id'] as String,
    ];
    await app.start();
    await app.firstSyncOnline();
    var first = true;
    app.server.retryAfterSeconds = 1;
    app.server.failWhen = (m, p, b) {
      if (p.endsWith('/spend-exclusion') && first) {
        first = false;
        return 503;
      }
      return null;
    };
    int sent() =>
        app.server.log.where((r) => r.path.endsWith('/spend-exclusion')).length;
    for (final id in ids) {
      await queueCommand(
        app.ref,
        kind: OutboxCommand.setSpendExclusion,
        target: id,
        payload: {'id': id, 'excluded': true},
      );
    }
    await app.idle(300);
    expect(sent(), 1, reason: 'nothing more is sent while the server said wait');

    // The pause is about a second of real time; the command's own backoff runs
    // on the fake clock.
    app.clock = app.clock.add(const Duration(hours: 1));
    await app.until(
      () => app.server.transactions.values
          .where((t) => t['exclude_from_spend'] == true)
          .length ==
          20,
      what: 'the queue to drain by itself after the pause',
    );
    expect(sent(), 21);
  });
}
