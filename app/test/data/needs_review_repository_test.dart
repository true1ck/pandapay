import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('add then fetchAll round-trips an item, newest first', () async {
    final repo = NeedsReviewRepository();
    await repo.add(NeedsReviewItem(
      id: '1',
      sender: 'VM-HDFCBK',
      body: 'first message',
      receivedAt: DateTime(2026, 1, 1),
    ));
    await repo.add(NeedsReviewItem(
      id: '2',
      sender: 'AX-AxisBk',
      body: 'second message',
      reason: 'unparseable_amount',
      receivedAt: DateTime(2026, 1, 2),
    ));

    final all = await repo.fetchAll();
    expect(all, hasLength(2));
    expect(all.first.id, '2'); // newest first
    expect(all.first.reason, 'unparseable_amount');
    expect(all.last.body, 'first message');
  });

  test('remove drops exactly the matching item', () async {
    final repo = NeedsReviewRepository();
    await repo.add(NeedsReviewItem(id: '1', sender: 's1', body: 'b1', receivedAt: DateTime(2026, 1, 1)));
    await repo.add(NeedsReviewItem(id: '2', sender: 's2', body: 'b2', receivedAt: DateTime(2026, 1, 2)));

    await repo.remove('1');

    final all = await repo.fetchAll();
    expect(all, hasLength(1));
    expect(all.first.id, '2');
  });

  test('AI suggestions update only an existing review item', () async {
    final repo = NeedsReviewRepository();
    const id = 'source-1';
    final suggestions = <Map<String, dynamic>>[
      {
        'factIndex': 0,
        'factType': 'posted_movement',
        'payload': {'amountInr': 125.0, 'entryKind': 'spend'},
      },
    ];
    expect(await repo.updateAiSuggestions(id, suggestions), isFalse);
    await repo.add(NeedsReviewItem(
      id: id,
      sender: 'VM-BANK',
      body: 'Rs.125 spent',
      receivedAt: DateTime(2026, 1, 1),
    ));
    expect(await repo.updateAiSuggestions(id, suggestions), isTrue);
    expect((await repo.fetchAll()).single.aiSuggestions, suggestions);
    expect(await repo.updateAiSuggestions(id, suggestions), isFalse);
    await repo.remove(id);
    expect(await repo.updateAiSuggestions(id, suggestions), isFalse);
    expect(await repo.fetchAll(), isEmpty);
  });

  test('removeAll drops every id in the set', () async {
    final repo = NeedsReviewRepository();
    await repo.add(NeedsReviewItem(id: '1', sender: 's1', body: 'b1', receivedAt: DateTime(2026, 1, 1)));
    await repo.add(NeedsReviewItem(id: '2', sender: 's2', body: 'b2', receivedAt: DateTime(2026, 1, 2)));
    await repo.add(NeedsReviewItem(id: '3', sender: 's3', body: 'b3', receivedAt: DateTime(2026, 1, 3)));

    await repo.removeAll(['1', '3']);

    final all = await repo.fetchAll();
    expect(all, hasLength(1));
    expect(all.first.id, '2');
  });

  test('cleans old promotional review items while retaining real alerts', () async {
    final prefs = await SharedPreferences.getInstance();
    final oldOffer = NeedsReviewItem(
      id: 'old-offer',
      sender: 'TX-WAKFTT-P',
      body: 'Treat yourself to a sofa at just Rs.28,125. Grab offer now.',
      receivedAt: DateTime(2026, 1, 1),
    );
    final realTxn = NeedsReviewItem(
      id: 'real-txn',
      sender: 'AD-FEDSCP-S',
      body: 'Your txn of Rs.1018 at a restaurant earned you 5% rewards.',
      receivedAt: DateTime(2026, 1, 2),
    );
    await prefs.setStringList('pandapay_app.needs_review_queue_v1', [
      jsonEncode(oldOffer.toJson()),
      jsonEncode(realTxn.toJson()),
    ]);
    final repo = NeedsReviewRepository();
    expect((await repo.fetchAll()).map((item) => item.id), ['real-txn']);
    expect(prefs.getStringList('pandapay_app.needs_review_queue_v1'), hasLength(1));
  });

  test('fetchAll on an empty store returns an empty list, not an error', () async {
    final repo = NeedsReviewRepository();
    expect(await repo.fetchAll(), isEmpty);
  });

  test('does not enqueue the same SMS twice when delivery timestamps are close', () async {
    final repo = NeedsReviewRepository();
    final receivedAt = DateTime(2026, 1, 2, 10, 0);
    await repo.add(NeedsReviewItem(
      id: 'first',
      sender: 'VM-SLICE',
      body: 'Rs. 875 spent on your credit card xx9080 at slice on 29-Sep-26.',
      receivedAt: receivedAt,
    ));
    await repo.add(NeedsReviewItem(
      id: 'duplicate',
      sender: 'vm-slice',
      body: '  Rs. 875 spent on your credit card xx9080 at slice on 29-Sep-26.  ',
      receivedAt: receivedAt.add(const Duration(minutes: 2)),
    ));

    final all = await repo.fetchAll();
    expect(all, hasLength(1));
    expect(all.single.id, 'first');
  });

  test('keeps identical SMS text when it arrived on a different day', () async {
    final repo = NeedsReviewRepository();
    await repo.add(NeedsReviewItem(
      id: 'day-one',
      sender: 'VM-SLICE',
      body: 'Rs. 875 spent on your credit card xx9080 at slice.',
      receivedAt: DateTime(2026, 1, 2),
    ));
    await repo.add(NeedsReviewItem(
      id: 'day-two',
      sender: 'VM-SLICE',
      body: 'Rs. 875 spent on your credit card xx9080 at slice.',
      receivedAt: DateTime(2026, 1, 3),
    ));

    expect(await repo.fetchAll(), hasLength(2));
  });

  test('isNoiseItem returns true for security/service alerts and false for investments/mandates', () {
    final vicareAlert = NeedsReviewItem(
      id: 'vicare',
      sender: 'ViCARE',
      body: 'Call Forwarding is now active',
      receivedAt: DateTime(2026, 1, 1),
    );
    final hdfcCheckAlert = NeedsReviewItem(
      id: 'check-alert',
      sender: 'VM-HDFCBK-S',
      body:
          'Transaction Check Alert! We tried to contact you twice to confirm the following txn: Rs.2,000.00 on Card XX4321 at AMAZON on 16-10-26. If this was not you, call 1860-266-2661',
      receivedAt: DateTime(2026, 1, 1),
    );
    final kotakNeo = NeedsReviewItem(
      id: 'kotak-neo',
      sender: 'KOTAKN',
      body:
          'Kotak Neo: Running A/c settlement payout of INR 15,500.00 initiated for your demat account. You should receive funds in A/c XX1234 by EOD.',
      receivedAt: DateTime(2026, 1, 1),
    );
    final mandate = NeedsReviewItem(
      id: 'mandate',
      sender: 'HDFCBK',
      body: 'AutoPay mandate successfully created for Rs.500.00',
      receivedAt: DateTime(2026, 1, 1),
    );

    expect(NeedsReviewRepository.isNoiseItem(vicareAlert), isTrue);
    expect(NeedsReviewRepository.isNoiseItem(hdfcCheckAlert), isTrue);
    expect(NeedsReviewRepository.isNoiseItem(kotakNeo), isFalse);
    expect(NeedsReviewRepository.isNoiseItem(mandate), isFalse);
  });

  test('fetchAll cleans out legacy security/service alerts from storage while keeping investment settlements', () async {
    final prefs = await SharedPreferences.getInstance();
    final vicareAlert = NeedsReviewItem(
      id: 'legacy-vicare',
      sender: 'ViCARE',
      body: 'Call Forwarding is now active',
      receivedAt: DateTime(2026, 1, 1),
    );
    final checkAlert = NeedsReviewItem(
      id: 'legacy-check-alert',
      sender: 'VM-HDFCBK-S',
      body:
          'Transaction Check Alert! We tried to contact you twice to confirm the following txn: Rs.2,000.00 on Card XX4321',
      receivedAt: DateTime(2026, 1, 2),
    );
    final kotakNeo = NeedsReviewItem(
      id: 'legacy-kotak',
      sender: 'KOTAKN',
      body:
          'Kotak Neo: Running A/c settlement payout of INR 15,500.00 initiated for your demat account.',
      receivedAt: DateTime(2026, 1, 3),
    );
    await prefs.setStringList('pandapay_app.needs_review_queue_v1', [
      jsonEncode(vicareAlert.toJson()),
      jsonEncode(checkAlert.toJson()),
      jsonEncode(kotakNeo.toJson()),
    ]);

    final repo = NeedsReviewRepository();
    final items = await repo.fetchAll();

    expect(items.map((i) => i.id), ['legacy-kotak']);
    final remaining = prefs.getStringList('pandapay_app.needs_review_queue_v1');
    expect(remaining, hasLength(1));
    expect(jsonDecode(remaining!.single)['id'], 'legacy-kotak');
  });

  test('fetchAll cleans out legacy security/service alerts from SQLite storage while keeping investment settlements', () async {
    final db = openInMemoryForTesting();
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    final vicareAlert = NeedsReviewItem(
      id: 'sql-vicare',
      sender: 'ViCARE',
      body: 'Call Forwarding is now active',
      receivedAt: DateTime(2026, 1, 1),
    );
    final checkAlert = NeedsReviewItem(
      id: 'sql-check-alert',
      sender: 'VM-HDFCBK-S',
      body: 'Transaction Check Alert! Confirm txn: Rs.2,000.00 on Card XX4321',
      receivedAt: DateTime(2026, 1, 2),
    );
    final kotakNeo = NeedsReviewItem(
      id: 'sql-kotak',
      sender: 'KOTAKN',
      body: 'Kotak Neo: Running A/c settlement payout of INR 15,500.00 initiated for your demat account.',
      receivedAt: DateTime(2026, 1, 3),
    );

    for (final item in [vicareAlert, checkAlert, kotakNeo]) {
      db.db.execute(
        'INSERT INTO local_needs_review VALUES (?,?,?)',
        ['user:test', item.id, jsonEncode(item.toJson())],
      );
    }

    final repo = NeedsReviewRepository(
      namespace: 'user:test',
      loadDatabase: () async => db,
    );
    final items = await repo.fetchAll();

    expect(items.map((i) => i.id), ['sql-kotak']);
    final remainingRows = db.db.select(
      'SELECT id FROM local_needs_review WHERE namespace=?',
      ['user:test'],
    );
    expect(remainingRows.map((r) => r['id']), ['sql-kotak']);
    db.close();
  });

  test('fetchAll purges regulatory balance reports, unsolicited tips, insurance renewals, wallet zero balance, and service alerts automatically', () async {
    final prefs = await SharedPreferences.getInstance();
    final items = [
      NeedsReviewItem(
        id: 'noise-reg-fund',
        sender: 'VM-ZERODH',
        body: 'Zerodha Broking reported your Fund bal Rs 4500 and securities bal Rs 25000. Balances excludes your Bank.',
        receivedAt: DateTime(2026, 1, 1),
      ),
      NeedsReviewItem(
        id: 'noise-tips',
        sender: 'AD-NSEIND',
        body: 'NSE Alert: Beware of dealing in unsolicited tips through SMS. Never trade on unsolicited tips.',
        receivedAt: DateTime(2026, 1, 2),
      ),
      NeedsReviewItem(
        id: 'noise-insurance',
        sender: 'VK-POLBZR',
        body: 'Your car insurance is due for renewal. Renew now with Policybazaar to get 50% off.',
        receivedAt: DateTime(2026, 1, 3),
      ),
      NeedsReviewItem(
        id: 'noise-wallet',
        sender: 'VM-PAYTMW',
        body: 'Your wallet balance is Rs 0. Add money to wallet to enjoy instant checkouts.',
        receivedAt: DateTime(2026, 1, 4),
      ),
      NeedsReviewItem(
        id: 'noise-forwarding',
        sender: 'VZ-ViCARE',
        body: 'Alert: Call Forwarding is now active on your mobile number.',
        receivedAt: DateTime(2026, 1, 5),
      ),
      NeedsReviewItem(
        id: 'noise-check-alert',
        sender: 'VM-HDFCBK-S',
        body: 'Transaction Check Alert! We tried to contact you to confirm txn on Card 1234.',
        receivedAt: DateTime(2026, 1, 6),
      ),
      NeedsReviewItem(
        id: 'legit-txn',
        sender: 'AD-HDFCBK',
        body: 'Spent Rs. 1,500 on HDFC Bank Card 1234 at Freshmart.',
        receivedAt: DateTime(2026, 1, 7),
      ),
    ];

    for (final item in items.take(6)) {
      expect(NeedsReviewRepository.isNoiseItem(item), isTrue, reason: item.body);
    }
    expect(NeedsReviewRepository.isNoiseItem(items.last), isFalse);

    await prefs.setStringList(
      'pandapay_app.needs_review_queue_v1',
      items.map((i) => jsonEncode(i.toJson())).toList(),
    );
    final repoPrefs = NeedsReviewRepository();
    final fetchedPrefs = await repoPrefs.fetchAll();
    expect(fetchedPrefs.map((i) => i.id).toList(), ['legit-txn']);
    final remainingPrefs = prefs.getStringList('pandapay_app.needs_review_queue_v1');
    expect(remainingPrefs, hasLength(1));
    expect(jsonDecode(remainingPrefs!.single)['id'], 'legit-txn');

    final db = openInMemoryForTesting();
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    for (final item in items) {
      db.db.execute(
        'INSERT INTO local_needs_review VALUES (?,?,?)',
        ['user:test', item.id, jsonEncode(item.toJson())],
      );
    }
    final repoSqlite = NeedsReviewRepository(
      namespace: 'user:test',
      loadDatabase: () async => db,
    );
    final fetchedSqlite = await repoSqlite.fetchAll();
    expect(fetchedSqlite.map((i) => i.id).toList(), ['legit-txn']);
    final remainingSqlite = db.db.select(
      'SELECT id FROM local_needs_review WHERE namespace=?',
      ['user:test'],
    );
    expect(remainingSqlite.map((r) => r['id']).toList(), ['legit-txn']);
    db.close();
  });

  test('addNeedsReviewSync deduplicates exact id and fuzzy sender/body/time matches', () async {
    final db = openInMemoryForTesting();
    const ns = 'user:test';
    final item1 = NeedsReviewItem(
      id: 'src-1',
      sender: 'VM-HDFCBK',
      body: 'Your electricity bill of Rs. 1,450 is due on 25-Oct',
      receivedAt: DateTime(2026, 10, 20, 10, 0),
    );
    final fuzzyDuplicate = NeedsReviewItem(
      id: 'commitment:src-1',
      sender: 'vm-hdfcbk ',
      body: 'Your  electricity bill of Rs. 1,450 is due on 25-Oct ',
      receivedAt: DateTime(2026, 10, 20, 10, 2), // 2 min apart
    );
    final differentItem = NeedsReviewItem(
      id: 'src-2',
      sender: 'VM-HDFCBK',
      body: 'Your gas bill of Rs. 850 is due on 28-Oct',
      receivedAt: DateTime(2026, 10, 20, 10, 1),
    );

    addNeedsReviewSync(db, ns, item1);
    addNeedsReviewSync(db, ns, fuzzyDuplicate); // should be skipped due to fuzzy dedup
    addNeedsReviewSync(db, ns, differentItem);

    final rows = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(rows.map((r) => r['id']), ['src-1', 'src-2']);
    db.close();
  });
}
