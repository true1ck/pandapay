import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/providers.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/response_cache.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ResponseCache cache;
  late ProviderContainer container;
  const ns = 'user:review-providers';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    cache = ResponseCache(db);
    container = ProviderContainer(overrides: [
      cacheNamespaceProvider.overrideWithValue(ns),
      appDatabaseProvider.overrideWith((ref) async => db),
      responseCacheProvider.overrideWith((ref) async => cache),
      userCardsRepositoryProvider.overrideWithValue(null),
      myCardsProvider.overrideWith((ref) async => []),
    ]);
  });
  tearDown(() {
    container.dispose();
    cache.financialStore.dispose();
    db.close();
  });

  NeedsReviewItem receipt(String id) => NeedsReviewItem(
    id: id, sender: 'VM-WLFRIN', receivedAt: DateTime.now(),
    body: 'Thank you for choosing Wellness Forever. View e-bill of Rs 177.98',
    aiSuggestions: const [{'factIndex': 0, 'factType': 'posted_movement'}],
  );

  test('count and list follow sync capture and removal, scoped to the account', () async {
    final countSub = container.listen(needsReviewCountProvider, (_, _) {});
    final listSub = container.listen(needsReviewItemsProvider, (_, _) {});
    addTearDown(countSub.close);
    addTearDown(listSub.close);
    expect(await container.read(needsReviewCountProvider.future), 0);
    expect(await container.read(needsReviewItemsProvider.future), isEmpty);

    addNeedsReviewSync(db, ns, receipt('one'));
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(needsReviewCountProvider.future), 1);
    expect((await container.read(needsReviewItemsProvider.future)).single.id, 'one');

    final countFuture = container.read(needsReviewCountProvider.future);
    addNeedsReviewSync(db, 'user:other-account', receipt('foreign'));
    await Future<void>.delayed(Duration.zero);
    expect(identical(container.read(needsReviewCountProvider.future), countFuture), isTrue);

    await container.read(needsReviewRepositoryProvider).remove('one');
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(needsReviewCountProvider.future), 0);
    expect(await container.read(needsReviewItemsProvider.future), isEmpty);
  });

  test('automatic reconciliation publishes committed financial and count changes', () async {
    final countSub = container.listen(needsReviewCountProvider, (_, _) {});
    addTearDown(countSub.close);
    expect(await container.read(needsReviewCountProvider.future), 0);
    final events = <String>[];
    final changes = cache.financialStore.changes.listen((change) {
      if (change.namespace == ns) events.add(change.entity);
    });
    addTearDown(changes.cancel);
    final item = NeedsReviewItem(
      id: 'wallet', sender: 'VM-MBKWIK', receivedAt: DateTime.now(),
      body: 'Rs.10.0 has been debited from your MobiKwik wallet. Remaining balance: Rs.12.17',
    );
    addNeedsReviewSync(db, ns, item);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(needsReviewCountProvider.future), 1);

    expect(await container.read(needsReviewRepositoryProvider).fetchAll(), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(needsReviewCountProvider.future), 0);
    expect(events, containsAll(['transactions', 'needs_review']));
    expect(cache.financialStore.entities(ns, 'transactions').single['amount_inr'], 10);

    final before = events.length;
    await container.read(needsReviewRepositoryProvider).remove('already-gone');
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(before));
  });

  test('financial observers receive reconciliation outside the review provider', () async {
    final revisionSub = container.listen(
      financialStoreRevisionProvider('transactions'), (_, _) {},
    );
    addTearDown(revisionSub.close);
    await container.read(responseCacheProvider.future);
    await Future<void>.delayed(Duration.zero);
    final events = <String>[];
    final changes = cache.financialStore.changes.listen((change) => events.add(change.entity));
    addTearDown(changes.cancel);
    final repo = NeedsReviewRepository(namespace: ns, loadDatabase: () async => db);
    addNeedsReviewSync(db, ns, NeedsReviewItem(
      id: 'standalone-wallet', sender: 'VM-MBKWIK', receivedAt: DateTime.now(),
      body: 'Rs.10.0 has been debited from your MobiKwik wallet. Remaining balance: Rs.12.17',
    ));
    expect(await repo.fetchAll(), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(events, contains('transactions'));
    expect(container.read(financialStoreRevisionProvider('transactions')).valueOrNull,
      greaterThan(0));
  });

  test('notifications from another database cannot refresh this cache', () async {
    final countSub = container.listen(needsReviewCountProvider, (_, _) {});
    addTearDown(countSub.close);
    expect(await container.read(needsReviewCountProvider.future), 0);
    final otherDb = openInMemoryForTesting();
    addTearDown(otherDb.close);
    final future = container.read(needsReviewCountProvider.future);
    addNeedsReviewSync(otherDb, ns, receipt('different-database'));
    await Future<void>.delayed(Duration.zero);
    expect(identical(container.read(needsReviewCountProvider.future), future), isTrue);
    expect(await container.read(needsReviewCountProvider.future), 0);
  });

  test('new spend evidence reconciles an already-open review list', () async {
    final listSub = container.listen(needsReviewItemsProvider, (_, _) {});
    final countSub = container.listen(needsReviewCountProvider, (_, _) {});
    addTearDown(listSub.close);
    addTearDown(countSub.close);
    await container.read(needsReviewItemsProvider.future);
    await container.read(needsReviewCountProvider.future);
    final item = NeedsReviewItem(
      id: 'unmatched-receipt', sender: 'VM-WLFRIN', receivedAt: DateTime.now(),
      body: 'Thank you for choosing Wellness Forever. View e-bill of Rs 177.98',
    );
    addNeedsReviewSync(db, ns, item);
    await Future<void>.delayed(Duration.zero);
    expect((await container.read(needsReviewItemsProvider.future)).single.id, item.id);
    expect(await container.read(needsReviewCountProvider.future), 1);

    cache.financialStore.saveProvisional(ns, TransactionEntry(
      id: 'matching-spend', amount: Money.fromPaise(17798),
      occurredAt: item.receivedAt, merchantName: 'Wellness Forever',
      source: 'sms', status: 'active',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(needsReviewItemsProvider.future), isEmpty);
    expect(await container.read(needsReviewCountProvider.future), 0);
    expect(PastBillReceiptRepository(db, namespace: ns).fetchAll().single
      .linkedTransactionId, 'matching-spend');
  });

  for (final (label, details, amount) in [
    ('known premium', 'Premium due Rs 2150.', Money.fromRupees(2150)),
    ('unknown premium', 'Sum insured Rs 500000. Premium not specified.', null),
  ]) {
    test('reconciled commitments refresh their existing provider ($label)', () async {
      await container.read(needsReviewRepositoryProvider).count();
      final sub = container.listen(commitmentsProvider, (_, _) {});
      addTearDown(sub.close);
      expect(await container.read(commitmentsProvider.future), isEmpty);
      final item = NeedsReviewItem(
        id: 'insurance', sender: 'VM-HDFCER-S', receivedAt: DateTime.now(),
        body: 'Vehicle insurance for DL01CD5678 will expire tomorrow. $details',
      );
      // Check the parser contract separately from notification propagation.
      final parsed = LocalSmsParser.parse(
        namespace: ns, sender: item.sender, body: item.body,
        receivedAt: item.receivedAt,
      );
      expect(parsed?.disposition, LocalSmsDisposition.localCommitment);
      expect(parsed?.amountDue, amount);
      addNeedsReviewSync(db, ns, item);
      expect(await container.read(needsReviewRepositoryProvider).fetchAll(), isEmpty);
      await Future<void>.delayed(Duration.zero);
      final rows = await container.read(commitmentsProvider.future);
      expect(rows.single.id, 'commitment:insurance');
      expect(rows.single.amount, amount);
    });
  }

  test('failed reconciliation never publishes a successful financial write', () async {
    final repo = container.read(needsReviewRepositoryProvider);
    await repo.count();
    final events = <String>[];
    final changes = cache.financialStore.changes.listen((change) => events.add(change.entity));
    addTearDown(changes.cancel);
    final item = NeedsReviewItem(
      id: 'wallet-failure', sender: 'VM-MBKWIK', receivedAt: DateTime.now(),
      body: 'Rs.10.0 has been debited from your MobiKwik wallet. Remaining balance: Rs.12.17',
    );
    db.db.execute('INSERT INTO local_needs_review VALUES (?,?,?)', [
      ns, item.id, jsonEncode(item.toJson()),
    ]);
    db.db.execute("CREATE TRIGGER reject_review_write BEFORE INSERT ON financial_entities "
      "BEGIN SELECT RAISE(ABORT, 'disk unavailable'); END");
    await expectLater(repo.fetchAll(), throwsA(isA<Exception>()));
    await Future<void>.delayed(Duration.zero);
    expect(events, isNot(contains('transactions')));
    expect(await repo.count(), 1);
  });

  test('history deduplicates structured cycles without parsing raw SMS', () async {
    final due = DateTime.now().subtract(const Duration(days: 100));
    final archive = PastBillReceiptRepository(db, namespace: ns);
    archive.archiveBill(
        id: 'archived-statement', sender: 'BANK', merchant: 'Bank Card',
        amount: Money.fromRupees(100), receivedAt: due,
        dueDate: due, cardLast4: '1234',
        body: 'Your statement is ready. No account number is quoted here.',
    );
    for (final (id, last4) in [('same-cycle', '1234'), ('other-card', '5678')]) {
      cache.financialStore.saveObservation(ns, id, {
        'id': id, 'event_type': 'bill', 'biller_name': 'Bank Card',
        'received_at': due.toIso8601String(), 'due_date': due.toIso8601String(),
        'amount_due_paise': 10000, 'card_last4': last4,
      });
    }
    final rows = await container.read(pastBillReceiptsProvider.future);
    expect(rows, hasLength(2));
    expect(rows.map((row) => row.cardLast4), unorderedEquals(['1234', '5678']));
    expect(rows.singleWhere((row) => row.cardLast4 == '1234').body,
      'Your statement is ready. No account number is quoted here.');
  });
}
