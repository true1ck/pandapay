// WP-Q1 scenarios d, e, f, g: bulk actions, voice / payment-sent saves, a card
// added offline with a transaction and an override on it, and card edits.
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/card_overrides_repository.dart';
import 'package:pandapay/data/local_first/pending_overlays.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/activity/bulk_transaction_actions.dart';
import 'package:pandapay/features/cards/add_card_local_first.dart';
import 'package:pandapay/features/cards/card_state_local_first.dart';
import 'package:pandapay/features/overrides/override_local_first.dart';
import 'package:pandapay/features/voice/voice_save.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import 'harness.dart';

const _cat = '33333333-3333-4333-8333-333333333333';

void main() {
  late OfflineApp app;
  setUp(() async => app = await OfflineApp.create());
  tearDown(() => app.dispose());

  test('d. bulk categorize / assign card / delete incl. a mixed selection',
      () async {
    final cardA = app.server.seedCard(last4: '1111')['id'] as String;
    final cardB =
        app.server.seedCard(product: 'product-2', last4: '2222')['id'] as String;
    final t1 = app.server.seedTransaction(amount: 10, cardId: cardA)['id'] as String;
    final t2 = app.server.seedTransaction(amount: 20, cardId: cardA)['id'] as String;
    final t3 = app.server.seedTransaction(amount: 30, cardId: cardA)['id'] as String;
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final cache = await app.c.read(responseCacheProvider.future);
    final outbox = await app.c.read(outboxRepositoryProvider.future);
    // A bank-SMS row (device-local 'v2:' id) and a row saved offline.
    cache.financialStore.saveTransactions(app.namespace, [
      TransactionEntry(
        id: 'v2:evt-1',
        pipelineVersion: 2,
        eventId: 'evt-1',
        amount: Money.fromRupees(55),
        occurredAt: DateTime.now(),
        merchantName: 'SMS Shop',
        source: 'sms',
        status: 'active',
      ),
    ]);
    await outbox.enqueue(
      userCardId: cardA,
      amount: Money.fromRupees(99),
      merchantName: 'Queued Shop',
      occurredAt: DateTime.now(),
      clientMutationId: '44444444-4444-4444-8444-444444444444',
    );
    app.refreshViews();
    final rows = await app.c.read(transactionsProvider.future);
    TransactionEntry byId(String id) => rows.firstWhere((r) => r.id == id);
    final mixed = [
      byId(t1),
      byId(t2),
      byId('v2:evt-1'),
      byId('local-outbox:44444444-4444-4444-8444-444444444444'),
    ];

    final smsCategory = <String>[];
    final smsHidden = <String>[];
    final actions = BulkTransactionActions(
      namespace: app.namespace,
      store: cache.financialStore,
      queue: await app.c.read(syncQueueProvider.future),
      commands: await app.c.read(commandOutboxProvider.future),
      outbox: outbox,
      smsSetCategory: (r, slug) => smsCategory.addAll(r.map((e) => e.id)),
      smsHide: (r) => smsHidden.add(r.id),
    );

    final cat = await actions.setCategory(mixed, _cat, slug: 'dining');
    expect(cat.failed, isEmpty);
    expect(cat.done, 4);
    final card = await actions.assignCard(mixed, cardB);
    expect(card.failed, isEmpty);
    expect(card.skipped, 1, reason: 'the SMS row is not re-carded in bulk');
    final del = await actions.delete([byId(t3), byId('v2:evt-1')]);
    expect(del.failed, isEmpty);
    expect(smsCategory, ['v2:evt-1']);
    expect(smsHidden, ['v2:evt-1']);
    expect(app.server.log, isEmpty);
    expect(app.pending, greaterThanOrEqualTo(3));

    await app.restart(online: false);
    await app.goOnline();
    await app.flushAll();

    expect(app.server.invalidIdRequests, isEmpty,
        reason: 'v2:/local-outbox: ids never reach the server');
    expect(app.server.transactions[t1]!['category_id'], _cat);
    expect(app.server.transactions[t1]!['user_card_id'], cardB);
    expect(app.server.transactions[t2]!['user_card_id'], cardB);
    expect(app.server.transactions[t3]!['status'], 'ignored');
    final queued = app.server.activeTransactions
        .singleWhere((t) => t['merchant_name'] == 'Queued Shop');
    expect(queued['category_id'], _cat);
    expect(queued['user_card_id'], cardB);
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
    expect(app.server.unhandledWrites, isEmpty);
  });

  test('e. voice save and payment-sent log offline, lost response: no duplicate',
      () async {
    final card = app.server.seedCard(last4: '1111')['id'] as String;
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final outbox = await app.c.read(outboxRepositoryProvider.future);
    // Voice: two drafts; the second save attempt of the sheet must not
    // re-save the first.
    final ids = ['55555555-5555-4555-8555-555555555555', '66666666-6666-4666-8666-666666666666'];
    final saved = <int>{};
    var calls = 0;
    Future<List<int>> save() => saveVoiceEntries<int>(
      [0, 1],
      isSaved: saved.contains,
      markSaved: saved.add,
      save: (i) async {
        calls++;
        await outbox.enqueue(
          userCardId: card,
          amount: Money.fromRupees(100.0 + i),
          merchantName: 'Voice $i',
          occurredAt: DateTime.now(),
          clientMutationId: ids[i],
        );
      },
    );
    expect(await save(), isEmpty);
    expect(await save(), isEmpty);
    expect(calls, 2);
    // Payment-sent "Log it": the screen holds one id; a second tap is the
    // same outbox row.
    for (var i = 0; i < 2; i++) {
      await outbox.enqueue(
        userCardId: card,
        amount: Money.fromRupees(120),
        merchantName: 'Synthetic Cafe',
        occurredAt: DateTime.utc(2026, 11, 14, 10),
        merchantVpa: 'cafe@synthetic',
        mcc: '5814',
        rail: 'upi_qr',
        clientMutationId: '77777777-7777-4777-8777-777777777777',
      );
    }
    expect((await outbox.all()), hasLength(3));
    expect(app.server.log, isEmpty);

    app.server.loseNextResponses = 2;
    await app.goOnline();
    await app.flushAll();
    final names = app.server.activeTransactions
        .map((t) => t['merchant_name'] as String)
        .where((n) => n.startsWith('Voice') || n.startsWith('Synthetic Cafe'))
        .toList()
      ..sort();
    expect(names, ['Synthetic Cafe', 'Voice 0', 'Voice 1']);
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
  });

  for (final oldServer in [false, true]) {
  test('f. add card offline, log a transaction and an override on it'
      '',
      () async {
    app.server.assignOwnCardIds = oldServer;
    app.server.seedCard(last4: '1111');
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final ref = app.ref;
    final added = await addCardLocalFirst(
      ref,
      cardProductId: 'product-2',
      nickname: 'Travel',
      last4: '4444',
    );
    expect(added.queued, isTrue);
    final localId = added.id;
    // The card is in the wallet at once.
    app.refreshViews();
    final wallet = await app.c.read(userCardsProvider.future);
    expect(wallet.any((c) => c.id == localId && c.last4 == '4444'), isTrue);

    // A transaction on it, offline.
    final outbox = await app.c.read(outboxRepositoryProvider.future);
    await outbox.enqueue(
      userCardId: localId,
      amount: Money.fromRupees(640),
      merchantName: 'Travel Desk',
      occurredAt: DateTime.now(),
      clientMutationId: '88888888-8888-4888-8888-888888888888',
    );
    // And an "always use this card here" rule.
    final created = await createOverrideLocalFirst(
      ref,
      card: wallet.firstWhere((c) => c.id == localId),
      scope: OverrideScope.merchantName,
      merchantName: 'Travel Desk',
    );
    expect(created, isFalse, reason: 'queued, not on the server yet');
    expect(app.pending, 3);

    await app.restart(online: false);
    expect(app.pending, 3);
    await app.goOnline();
    app.server.loseNextResponses = 1; // the add-card answer is lost once
    await app.flushAll();

    final serverCards = app.server.cards.values
        .where((c) => c['last4'] == '4444')
        .toList();
    expect(serverCards, hasLength(1), reason: 'card created exactly once');
    final serverId = serverCards.single['id'] as String;
    final txn = app.server.activeTransactions
        .singleWhere((t) => t['merchant_name'] == 'Travel Desk');
    expect(txn['user_card_id'], serverId,
        reason: 'the transaction follows the id remap');
    expect(app.server.overrides, hasLength(1));
    expect(app.server.overrides.values.single['user_card_id'], serverId);
    expect(app.server.duplicates, isEmpty);
    expect(app.pending, 0);
    app.refreshViews();
    final after = await app.c.read(userCardsProvider.future);
    expect(after.where((c) => c.last4 == '4444'), hasLength(1));
    if (oldServer) {
      expect(serverId, isNot(localId));
      expect(after.any((c) => c.id == localId), isFalse);
    } else {
      expect(serverId, localId);
    }
  });
  }

  test('g. edit card nickname/last4/fee/points, archive and default offline',
      () async {
    final a = app.server.seedCard(last4: '1111', isDefault: true)['id'] as String;
    final b = app.server.seedCard(product: 'product-2', last4: '2222')['id'] as String;
    await app.start();
    await app.firstSyncOnline();
    await app.goOffline();
    app.server.clearLog();

    final ref = app.ref;
    final queue = await app.c.read(syncQueueProvider.future);
    // What Edit card saves for a card the server knows.
    queue.enqueueUpdate(
      entity: 'user_cards',
      entityId: a,
      fields: {
        'nickname': 'Renamed',
        'last4': '9999',
        'annual_fee_override_inr': 0,
      },
    );
    await queueCardFieldPatch(ref, a, {
      'last4': '9999',
      'annualFeeOverrideInr': 0.0,
    });
    await queuePointsBalance(ref, a, 4200);
    expect(await setCardDefault(ref, b), CardChange.queued);
    expect(await setCardArchived(ref, a, archived: true), CardChange.queued);
    expect(app.pending, greaterThanOrEqualTo(4));

    await app.restart(online: false);
    await app.goOnline();
    await app.flushAll();

    final ca = app.server.cards[a]!;
    expect(ca['nickname'], 'Renamed');
    expect(ca['last4'], '9999');
    expect(ca['annual_fee_override_inr'], 0);
    expect(ca['points_balance'], 4200);
    expect(ca['is_archived'], isTrue);
    expect(app.server.cards[b]!['is_default'], isTrue);
    expect(app.server.duplicates, isEmpty);
    expect(app.server.invalidIdRequests, isEmpty);
    expect(app.pending, 0);
    // OverlayCommand kinds used above exist.
    expect(OverlayCommand.pointsAdjust, isNotEmpty);
  });
}
