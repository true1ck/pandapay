// WP-Q1 scenarios a, b, c: cold start offline, quick add offline with a lost
// response, and transaction edits that must survive a refresh.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/features/sync_status/sync_status_providers.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'harness.dart';

void main() {
  late OfflineApp app;
  setUp(() async => app = await OfflineApp.create());
  tearDown(() => app.dispose());

  String seedWorld() {
    final card = app.server.seedCard(nickname: 'Daily', last4: '1111');
    app.server.seedCard(product: 'product-2', last4: '2222');
    app.server.seedTransaction(
      amount: 120,
      cardId: card['id'] as String,
      merchant: 'Shop A',
      at: DateTime.now().subtract(const Duration(days: 1)),
    );
    app.server.seedTransaction(
      amount: 80,
      cardId: card['id'] as String,
      merchant: 'Shop B',
      at: DateTime.now().subtract(const Duration(days: 2)),
    );
    return card['id'] as String;
  }

  test('a. cold start offline with existing local data: no logout, data shown',
      () async {
    seedWorld();
    await app.start();
    await app.firstSyncOnline();
    expect((await app.c.read(userCardsProvider.future)), hasLength(2));
    await app.stop();

    app.server.clearLog();
    await app.start(online: false);
    final cards = await app.c.read(userCardsProvider.future);
    final txns = await app.c.read(transactionsProvider.future);
    expect(cards.map((c) => c.last4), containsAll(['1111', '2222']));
    expect(txns.map((t) => t.merchantName), containsAll(['Shop A', 'Shop B']));
    // Insights / Home read local data without throwing.
    await app.c.read(budgetsProvider.future);
    await app.c.read(homeSummaryProvider.future);
    await app.c.read(categorySpendProvider.future);
    // Still signed in as the same account.
    expect(app.c.read(cacheNamespaceProvider), app.namespace);
    expect(app.c.read(accessTokenProvider), isNotNull);
    expect(app.server.log, isEmpty, reason: 'nothing may reach the server');
    expect((await app.summaryNow()).mode, SyncStatusMode.offline);
    expect(app.pending, 0);
  });

  test('b. quick add offline x2 + lost response on reconnect: one row per id',
      () async {
    final cardId = seedWorld();
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final outbox = await app.c.read(outboxRepositoryProvider.future);
    await outbox.enqueue(
      userCardId: cardId,
      amount: Money.fromRupees(250),
      merchantName: 'Offline Cafe',
      occurredAt: DateTime.now(),
      clientMutationId: '11111111-1111-4111-8111-111111111111',
    );
    await outbox.enqueue(
      userCardId: cardId,
      amount: Money.fromRupees(75),
      merchantName: 'Offline Bakery',
      occurredAt: DateTime.now(),
      clientMutationId: '22222222-2222-4222-8222-222222222222',
    );
    app.c.read(outboxFlushRequestProvider.notifier).state++;
    await app.idle();
    app.refreshViews();

    // Local state while offline: both rows show in Activity, nothing sent.
    final shown = (await app.c.read(transactionsProvider.future))
        .where((t) => t.merchantName?.startsWith('Offline') ?? false);
    expect(shown, hasLength(2));
    expect(app.pending, 2);
    expect((await app.summaryNow()).mode, SyncStatusMode.offline);
    expect((await app.summaryNow()).pendingCount, 2);
    expect(app.server.log, isEmpty);

    // Reconnect; the first answer is lost after the server applied it.
    app.server.loseNext(1, ['/transactions']);
    await app.goOnline();
    await app.flushAll();

    final srv = app.server.activeTransactions
        .where((t) => (t['merchant_name'] as String).startsWith('Offline'))
        .toList();
    expect(srv, hasLength(2), reason: 'exactly one server row per mutation id');
    expect(app.server.txnByMutation.length, 2);
    expect(app.server.count('POST', '/transactions'), 3, reason: 'one replay after the lost answer');
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
    expect((await app.summaryNow()).pendingCount, 0);
    final after = (await app.c.read(transactionsProvider.future))
        .where((t) => t.merchantName?.startsWith('Offline') ?? false);
    expect(after, hasLength(2));
    expect(after.every((t) => !t.id.startsWith('local-outbox:')), isTrue);
  });

  test('c. offline edit of note/category/card survives reconnect and refresh',
      () async {
    final cardId = seedWorld();
    final other = app.server.seedCard(product: 'product-2', last4: '3333');
    final txnId = app.server.transactions.keys.first;
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();

    final cache = await app.c.read(responseCacheProvider.future);
    final queue = await app.c.read(syncQueueProvider.future);
    // The same call the edit screen makes: local copy first, then the queue.
    queue.enqueueUpdate(
      entity: 'transactions',
      entityId: txnId,
      fields: {
        'note': 'edited offline',
        'category_id': 'dining',
        'user_card_id': other['id'],
        'instrument': 'debit_card',
      },
    );
    cache.financialStore.patchTransaction(app.namespace, txnId, {
      "note": "edited offline",
    });
    expect(app.pending, 1);

    // A restart must not lose it.
    await app.restart(online: false);
    expect(app.pending, 1);

    await app.goOnline();
    await app.flushAll();
    final row = app.server.transactions[txnId]!;
    expect(row['note'], 'edited offline');
    expect(row['category_id'], 'dining');
    expect(row['user_card_id'], other['id']);
    expect(row['instrument'], 'debit_card');
    expect(app.server.duplicates, isEmpty);

    // A full refresh afterwards must not revert it.
    app.c.invalidate(homeDataRefreshProvider);
    await app.c.read(homeDataRefreshProvider.future);
    final refreshed = (await app.c.read(transactionsProvider.future))
        .firstWhere((t) => t.id == txnId);
    expect(refreshed.note, 'edited offline');
    expect(refreshed.userCardId, other['id']);
    expect(cardId, isNotEmpty);
  });
}
