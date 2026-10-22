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

  test('fetchAll auto-resolves merchant e-bill receipts when a matching spend transaction exists in SQLite', () async {
    final db = openInMemoryForTesting();
    const ns = 'user:test';
    final repo = NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    );

    // 1. Existing spend transaction of ₹177.98 at Wellness forever goa recorded in SQLite
    final txnTime = DateTime(2026, 10, 13, 14, 0);
    db.db.execute('''
      CREATE TABLE IF NOT EXISTS financial_entities (
        namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
        payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
        pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
        occurred_at INTEGER, amount_paise INTEGER,
        PRIMARY KEY(namespace, entity, id)
      );
    ''');
    db.db.execute(
      '''
      INSERT INTO financial_entities(namespace, entity, id, payload, observed_at, occurred_at, amount_paise)
      VALUES (?, 'transactions', 'txn-wellness-1', ?, ?, ?, ?)
      ''',
      [
        ns,
        jsonEncode({
          'id': 'txn-wellness-1',
          'amount_inr': 177.98,
          'occurred_at': txnTime.toIso8601String(),
          'merchant_name': 'Wellness forever goa',
          'entry_kind': 'spend',
        }),
        txnTime.millisecondsSinceEpoch,
        txnTime.millisecondsSinceEpoch,
        17798,
      ],
    );

    // 2. Wellness Forever e-bill SMS received within 24 hours (5 minutes later)
    final ebillWellness = NeedsReviewItem(
      id: 'ebill-wellness-1',
      sender: 'VM-WLFRIN',
      body: 'Thank you for choosing Wellness Forever. View e-bill of Rs 177.98 - https://b.wlfr.in/c/xyz',
      receivedAt: txnTime.add(const Duration(minutes: 5)),
    );

    // 3. Another merchant e-bill SMS with NO matching spend transaction
    final ebillUnmatched = NeedsReviewItem(
      id: 'ebill-unmatched',
      sender: 'VM-PHARMA',
      body: 'Thank you for choosing Apollo Pharmacy. View e-bill of Rs 450.00 - https://apollopharmacy.in/b/123',
      receivedAt: txnTime.add(const Duration(hours: 1)),
    );

    // Queue both in Needs Review
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?)',
      [ns, ebillWellness.id, jsonEncode(ebillWellness.toJson())],
    );
    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?)',
      [ns, ebillUnmatched.id, jsonEncode(ebillUnmatched.toJson())],
    );

    // Fetch review items
    final remainingItems = await repo.fetchAll();

    // Verify Wellness Forever e-bill is auto-resolved and removed because ₹177.98 spend exists
    expect(remainingItems.map((i) => i.id).toList(), ['ebill-unmatched']);
    expect(remainingItems.single.body, contains('450.00'));

    // Verify Wellness Forever e-bill was automatically deleted from SQLite local_needs_review
    final storedRows = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(storedRows.map((r) => r['id']).toList(), ['ebill-unmatched']);

    // Also verify that add() and addNeedsReviewSync() skip adding if matching spend exists
    await repo.add(ebillWellness);
    final afterAdd = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(afterAdd.map((r) => r['id']).toList(), ['ebill-unmatched']);

    addNeedsReviewSync(db, ns, ebillWellness);
    final afterSync = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(afterSync.map((r) => r['id']).toList(), ['ebill-unmatched']);

    db.close();
  });
  test('fetchAll auto-resolves legacy wallet spends, bill reminders, and AutoPay alerts from SQLite local_needs_review', () async {
    final db = openInMemoryForTesting();
    const ns = 'user-test-retriage';
    final repo = NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    );

    final walletItem = NeedsReviewItem(
      id: 'wallet-item-1',
      sender: 'VM-MOBIKW',
      body: 'Rs.10.0 has been debited from your MobiKwik wallet. Remaining balance: Rs.12.17',
      receivedAt: DateTime(2026, 10, 1),
    );

    final billReminder = NeedsReviewItem(
      id: 'bill-reminder-1',
      sender: 'AX-AxisBk',
      body: 'Payment of INR 132 for Axis Bank Credit Card no. XX7105 is due on 03-10-26 with minimum amount due of INR 100. Ignore if paid.',
      receivedAt: DateTime(2026, 10, 2),
    );

    final mandateItem = NeedsReviewItem(
      id: 'mandate-item-1',
      sender: 'CP-GOVT',
      body: 'Dear customer, your Atal Pension Yojana contribution amount for the Month April is Rs 46/-, Kindly maintain sufficient bal',
      receivedAt: DateTime(2026, 10, 3),
    );

    final unknownCardSpend = NeedsReviewItem(
      id: 'unknown-card-spend',
      sender: 'AD-HDFCBK',
      body: 'Spent Rs. 1,500 on Unknown Bank Card 9999 at Store.',
      receivedAt: DateTime(2026, 10, 4),
    );

    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    for (final item in [walletItem, billReminder, mandateItem, unknownCardSpend]) {
      db.db.execute(
        'INSERT INTO local_needs_review VALUES (?,?,?)',
        [ns, item.id, jsonEncode(item.toJson())],
      );
    }

    final remaining = await repo.fetchAll();

    // 1. Only the unknown card spend remains in Needs Review
    expect(remaining.map((i) => i.id).toList(), ['unknown-card-spend']);

    // 2. Wallet spend was persisted to financial_entities as spend transaction
    final txnRows = db.db.select(
      "SELECT payload, amount_paise FROM financial_entities WHERE namespace = ? AND entity = 'transactions'",
      [ns],
    );
    expect(txnRows, hasLength(1));
    expect(txnRows.single['amount_paise'], 1000); // Rs 10.00 = 1000 paise

    // 3. Bill reminder was persisted to financial_entities as sms_observations
    final obsRows = db.db.select(
      "SELECT payload FROM financial_entities WHERE namespace = ? AND entity = 'sms_observations'",
      [ns],
    );
    expect(obsRows, hasLength(1));
    expect(obsRows.single['payload'], contains('7105'));

    // 4. Mandate alert was persisted to local_commitments
    final commitmentRows = db.db.select(
      'SELECT payload FROM local_commitments WHERE namespace = ?',
      [ns],
    );
    expect(commitmentRows, hasLength(1));
    expect(commitmentRows.single['payload'], contains('Atal Pension Yojana'));

    db.close();
  });
  test('isSecurityOrServiceAlert and isNoiseItem catch card usage settings, expired insurance quotes (+ taxes*), and unsolicited loan/card offers', () {
    final cardUsageAlert = NeedsReviewItem(
      id: 'card-usage-1',
      sender: 'VM-HDFCBK',
      body: 'Modification Success! Card usage settings for Credit Card ending with XX1366 modified. If this was not done by you, please call customer care.',
      receivedAt: DateTime(2026, 10, 1),
    );
    final expiredInsurance = NeedsReviewItem(
      id: 'insurance-quote-1',
      sender: 'CP-POLBAZ',
      body: 'Last Chance: renew your expired Two Wheeler Insurance... Premium: Rs.1245.00 + taxes*. Visit policybazaar.com',
      receivedAt: DateTime(2026, 10, 2),
    );
    final carInsuranceExpiry = NeedsReviewItem(
      id: 'car-insurance-1',
      sender: 'VM-RELGEN-S',
      body: 'Your car insurance will expire on 28-Oct-26. Renew today to avoid vehicle inspection: https://relgen.in/c',
      receivedAt: DateTime(2026, 10, 3),
    );
    final loanOffer = NeedsReviewItem(
      id: 'loan-offer-1',
      sender: 'AD-BAJAJA',
      body: 'Congratulations! You are eligible for loan of Rs. 5,00,000 at low interest rates. Instant disbursal.',
      receivedAt: DateTime(2026, 10, 4),
    );
    final cardLimitOffer = NeedsReviewItem(
      id: 'card-limit-1',
      sender: 'AX-AxisBk',
      body: 'Avail card with limit of Rs. 1,50,000 with zero joining fee. Click here to claim your credit card.',
      receivedAt: DateTime(2026, 10, 5),
    );

    final noiseItems = [
      cardUsageAlert,
      expiredInsurance,
      carInsuranceExpiry,
      loanOffer,
      cardLimitOffer,
    ];

    for (final item in noiseItems) {
      expect(NeedsReviewRepository.isSecurityOrServiceAlert(item.body), isTrue, reason: item.body);
      expect(NeedsReviewRepository.isNoiseItem(item), isTrue, reason: item.body);
    }
  });

  test('ASBA and IPO lien blocks are recognized as investmentSettlement and kept in queue', () async {
    final db = openInMemoryForTesting();
    const ns = 'user-test-asba';
    final repo = NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    );

    final asbaItem = NeedsReviewItem(
      id: 'asba-1',
      sender: 'VM-HDFCBK',
      body: 'request for ASBA application no. 1234567 for RENTOMOJO LIMITED of Rs. 14950.00 has been accepted successfully.',
      receivedAt: DateTime(2026, 10, 10),
    );
    final ipoLienItem = NeedsReviewItem(
      id: 'ipo-lien-1',
      sender: 'AX-AxisBk',
      body: 'Dear Customer, lien of Rs. 14850.00 marked on your account for ASBA application no. 987654 for SWIGGY LIMITED.',
      receivedAt: DateTime(2026, 10, 11),
    );

    expect(NeedsReviewRepository.isSecurityOrServiceAlert(asbaItem.body), isFalse);
    expect(NeedsReviewRepository.isInvestmentSettlement(asbaItem.body), isTrue);
    expect(NeedsReviewRepository.isNoiseItem(asbaItem), isFalse);
    expect(NeedsReviewRepository.resolveItemKind(asbaItem).kind, NeedsReviewKind.investmentSettlement);

    expect(NeedsReviewRepository.isSecurityOrServiceAlert(ipoLienItem.body), isFalse);
    expect(NeedsReviewRepository.isInvestmentSettlement(ipoLienItem.body), isTrue);
    expect(NeedsReviewRepository.isNoiseItem(ipoLienItem), isFalse);
    expect(NeedsReviewRepository.resolveItemKind(ipoLienItem).kind, NeedsReviewKind.investmentSettlement);

    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    // Insert with default kind (transaction) as legacy items would have been stored
    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?)',
      [ns, asbaItem.id, jsonEncode(asbaItem.toJson())],
    );
    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?)',
      [ns, ipoLienItem.id, jsonEncode(ipoLienItem.toJson())],
    );

    final items = await repo.fetchAll();
    expect(items, hasLength(2));
    expect(items.map((i) => i.kind), [NeedsReviewKind.investmentSettlement, NeedsReviewKind.investmentSettlement]);

    // Verify database row payload was updated to investmentSettlement
    final storedRows = db.db.select('SELECT payload FROM local_needs_review WHERE namespace=?', [ns]);
    for (final row in storedRows) {
      final json = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      expect(json['kind'], 'investmentSettlement');
    }

    db.close();
  });

  test('purges operational noise, insurance renewal marketing, depository, maintenance, and security alerts', () async {
    final noiseMessages = [
      'Dear Customer, your Two Wheeler Insurance for HONDA ACTIVA policy no. 920222423120813150 has expired. Premium: Rs.1245.00 + taxes*. Renew with discount...',
      'Alert: Dear Customer, your Two Wheeler Insurance for HONDA ACTIVA policy no. 920222423120813150 has expired. Premium: Rs.1245.00 + taxes*...',
      'Girish Shantaram Curtikar, car insurance for your MARUTI OMNI will expire on 22 May, 2025. Please click here - https://epbz.in/POLBAZ...',
      'Hi Girish Shantaram Curtikar, your car insurance expired 22 May, 2025. Premium starts at only Rs.2471. Visit https://epbz.in/POLBAZ...',
      'CDSL: Unpledge Accepted in a/c *00025520 for 2-MIRAE ASSET INVESTMENT MANAGER, 2-MOTILAL OSWAL ASSET MANAGEMENT, Total 8 ISINs Accepted on 0...',
      'CDSL: Unpledge accepted by pledgee a/c *04953816 on 03/01/2025 for 4 shares of NIPPON LIFE INDIA AM LTD#NIPPO',
      'CDSL: Pledge accepted by pledgee a/c 04953816 for 2 Units-NIPPON LIFE INDIA AM LTD#NIPPO...',
      'Your Address in Folio- XXXXXXXX4724 is updated from KYC records based on feed received from KRA. For more details, call us at 8108622222. MotilalOswal MF',
      'We have updated your address under folio XXXXXXXX5553, based on the feed received from KRA. For more details, call us at 18602660111. Nippon India MF',
      'Due to scheduled maintenance, txns. with Axis Bank Credit Card on 30-10-25, 00:30 AM - 01:00 AM IST will be paused. Inconvenience caused is...',
      'Registration Alert:Device Name: android-motorola-motorola edge 50 fusion For HDFC Bank App on 09-03-2026, 09:24. Not you? Call 18002586161',
      'Hi Sujay, your Rs. 50 off and Rs. 30 off coupons expire...',
      'Your order from Wellness is dispatched through Blue Dart AWB 80705290890...',
      'Order Received! We have received your order ID 8584859 for Wellness Forever...',
      'Important Info: A Lifetime-Free Credit Card facility has been enabled on your HDFC Bank A/c xx1797. Check: https://1.hdfc.bank.in/...',
    ];

    for (var i = 0; i < noiseMessages.length; i++) {
      final body = noiseMessages[i];
      expect(NeedsReviewRepository.isSecurityOrServiceAlert(body), isTrue, reason: 'Failed isSecurityOrServiceAlert for: $body');
      final item = NeedsReviewItem(
        id: 'noise-$i',
        sender: 'AD-BANK',
        body: body,
        receivedAt: DateTime(2026, 10, 22),
      );
      expect(NeedsReviewRepository.isNoiseItem(item), isTrue, reason: 'Failed isNoiseItem for: $body');
    }

    final repo = NeedsReviewRepository();
    for (var i = 0; i < noiseMessages.length; i++) {
      await repo.add(NeedsReviewItem(
        id: 'noise-$i',
        sender: 'AD-BANK',
        body: noiseMessages[i],
        receivedAt: DateTime(2026, 10, 22),
      ));
    }
    // All noise messages must be dropped on add
    expect(await repo.fetchAll(), isEmpty);
  });

  test('AutoPay reminder for credit card bill is auto-resolved to sms_observations by fetchAll', () async {
    final db = openInMemoryForTesting();
    const ns = 'user-test-autopay-bill';
    final repo = NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    );

    final item = NeedsReviewItem(
      id: 'autopay-cc-bill-1',
      sender: 'HDFCBK',
      body: 'AutoPay Reminder: Rs.1147 will be deducted from HDFC Bank A/c 1797 on 08/SEP/2026 for Credit Card 8708 bill. For Query: Ask EVA resu.io/ZPCKZ7',
      receivedAt: DateTime(2026, 9, 1),
    );

    // Initial kind is mandate
    expect(NeedsReviewRepository.resolveItemKind(item).kind, NeedsReviewKind.mandate);

    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?)',
      [ns, item.id, jsonEncode(item.toJson())],
    );

    final remaining = await repo.fetchAll();
    expect(remaining, isEmpty);

    final obsRows = db.db.select(
      "SELECT payload FROM financial_entities WHERE namespace = ? AND entity = 'sms_observations'",
      [ns],
    );
    expect(obsRows, hasLength(1));
    final obsData = jsonDecode(obsRows.single['payload'] as String) as Map<String, dynamic>;
    expect(obsData['card_last4'], '8708');
    expect(obsData['amount_due_paise'], 114700);
    expect(obsData['due_date'], contains('2026-09-08'));
    expect(obsData['event_type'], 'bill');

    db.close();
  });

  test('NACH / UMRN auto-debit spend is auto-resolved to transactions by fetchAll', () async {
    final db = openInMemoryForTesting();
    const ns = 'user-test-nach-debit';
    final repo = NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    );

    final item = NeedsReviewItem(
      id: 'nach-debit-1',
      sender: 'HDFCBK',
      body: 'PAYMENT ALERT!  INR 395.00 deducted from HDFC Bank A/C No 1797 towards Capital Float UMRN: HDFC7022004230009315',
      receivedAt: DateTime(2026, 9, 2),
    );

    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?)',
      [ns, item.id, jsonEncode(item.toJson())],
    );

    final remaining = await repo.fetchAll();
    expect(remaining, isEmpty);

    final txnRows = db.db.select(
      "SELECT payload, amount_paise FROM financial_entities WHERE namespace = ? AND entity = 'transactions'",
      [ns],
    );
    expect(txnRows, hasLength(1));
    expect(txnRows.single['amount_paise'], 39500);

    final txnData = jsonDecode(txnRows.single['payload'] as String) as Map<String, dynamic>;
    expect(txnData['merchant_name'], 'Capital Float');
    expect(txnData['account_last4'], '1797');
    expect(txnData['instrument'], 'upi_bank');
    expect(txnData['entry_kind'], 'spend');

    db.close();
  });
}
