// Scenario t: the save spinner holds until every view shows the edit, and a
// connection that dies mid-request loses and doubles nothing. Synthetic data.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/refresh_views.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/card_field_patch.dart';
import 'package:pandapay/features/cards/add_card_local_first.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'harness.dart';

void main() {
  late OfflineApp app;
  setUp(() async => app = await OfflineApp.create());
  tearDown(() => app.dispose());

  String seedWorld() {
    final card = app.server.seedCard(nickname: 'Daily', last4: '1111');
    app.server.seedTransaction(
      amount: 120,
      cardId: card['id'] as String,
      merchant: 'Shop A',
      at: DateTime.now().subtract(const Duration(days: 1)),
    );
    return card['id'] as String;
  }

  test('t1. when refreshViews returns, every list already shows the edit',
      () async {
    seedWorld();
    final txnId = app.server.transactions.keys.first;
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();

    final cache = await app.c.read(responseCacheProvider.future);
    final queue = await app.c.read(syncQueueProvider.future);
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: txnId,
      fields: {'note': 'saved once'},
    );
    cache.financialStore.patchTransaction(app.namespace, txnId, {
      'note': 'saved once',
    });

    await refreshViews(app.ref);

    // No awaiting after the helper: the providers must already hold the edit.
    for (final view in [transactionsProvider, utilizationTransactionsProvider]) {
      final value = app.c.read(view);
      expect(value.hasValue, isTrue, reason: '$view must not be loading');
      expect(
        value.value!.firstWhere((t) => t.id == txnId).note,
        'saved once',
        reason: '$view',
      );
    }
  });

  test('t2. the connection dies mid-request: nothing lost, nothing doubled',
      () async {
    final cardId = seedWorld();
    final txnId = app.server.transactions.keys.first;
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    // Two kinds of work saved while offline: an edit (sync queue) and a new
    // transaction (outbox).
    final cache = await app.c.read(responseCacheProvider.future);
    final queue = await app.c.read(syncQueueProvider.future);
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: txnId,
      fields: {'note': 'edited offline'},
    );
    cache.financialStore.patchTransaction(app.namespace, txnId, {
      'note': 'edited offline',
    });
    final outbox = await app.c.read(outboxRepositoryProvider.future);
    await outbox.enqueue(
      userCardId: cardId,
      amount: Money.fromRupees(250),
      merchantName: 'Offline Cafe',
      occurredAt: DateTime.now(),
      clientMutationId: '33333333-3333-4333-8333-333333333333',
    );
    await refreshViews(app.ref);
    expect(app.pending, 2);
    expect(app.server.log, isEmpty, reason: 'nothing may reach the server');

    // Back online, but the server applies each request and the answer is lost
    // (the radio drops mid-request), so the app must retry both.
    app.server.loseNext(2, ['/sync/push', '/transactions']);
    await app.goOnline();
    await app.flushAll();

    expect(app.server.transactions[txnId]!['note'], 'edited offline');
    final cafes = app.server.activeTransactions
        .where((t) => t['merchant_name'] == 'Offline Cafe')
        .toList();
    expect(cafes, hasLength(1), reason: 'one server row for one mutation id');
    expect(app.server.activeTransactions, hasLength(2)); // Shop A + the cafe
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
    // The injected failures really happened: each request was sent twice.
    expect(app.server.count('POST', '/transactions'), 2);
    expect(app.server.pushReplays, greaterThanOrEqualTo(1));

    // The screens show the same thing the server has.
    await refreshViews(app.ref);
    final shown = app.c.read(transactionsProvider).value!;
    expect(shown.where((t) => t.merchantName == 'Offline Cafe'), hasLength(1));
    expect(shown.firstWhere((t) => t.id == txnId).note, 'edited offline');
    expect(shown.any((t) => t.id.startsWith('local-outbox:')), isFalse);
  });

  test('t3. card edit while online: stored first, one PATCH later, never flips back',
      () async {
    final cardId = seedWorld();
    await app.start();
    await app.firstSyncOnline();
    final cache = await app.c.read(responseCacheProvider.future);

    // The server is up but refuses the PATCH for a while (a 503).
    app.server.failWhen = (m, p, b) => m == 'PATCH' ? 503 : null;
    app.server.clearLog();

    // What the Edit card screen does on Save.
    final fields = <String, Object?>{
      'nickname': 'Renamed',
      'last4': '9999',
    };
    await queueCardFieldPatch(app.ref, cardId, fields);
    cache.financialStore.patchCard(
      app.namespace,
      cardId,
      cardStorePatchFromCommand(fields),
    );
    await refreshViews(app.ref);

    final first = (await app.c.read(userCardsProvider.future))
        .firstWhere((c) => c.id == cardId);
    expect(first.nickname, 'Renamed');
    expect(first.last4, '9999');
    expect(app.server.cards[cardId]!['nickname'], 'Daily',
        reason: 'the server has not got it yet');

    // The server's older copy arrives meanwhile (a wallet refresh).
    final repo = app.c.read(userCardsRepositoryProvider)!;
    cache.financialStore.replaceCards(app.namespace, await repo.fetchUserCards());
    await refreshViews(app.ref);
    final during = (await app.c.read(userCardsProvider.future))
        .firstWhere((c) => c.id == cardId);
    expect(during.nickname, 'Renamed', reason: 'must not flip back');

    // The server recovers; the edit is delivered once.
    app.server.failWhen = null;
    app.advance(const Duration(hours: 1));
    await app.flushAll();
    expect(app.server.cards[cardId]!['nickname'], 'Renamed');
    expect(app.server.cards[cardId]!['last4'], '9999');
    expect(app.pending, 0);
    expect(app.server.duplicates, isEmpty);

    // After delivery the stored copy still has it (no older value in between).
    await refreshViews(app.ref);
    final after = (await app.c.read(userCardsProvider.future))
        .firstWhere((c) => c.id == cardId);
    expect(after.nickname, 'Renamed');
  });
}
