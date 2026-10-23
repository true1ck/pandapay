import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

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
  test('isSecurityOrServiceAlert matches new operational noise patterns', () {
    final noiseAlerts = [
      'CDSL: Pledge setup initiated for Demat A/c 12345678.',
      'Unpledge request for 50 shares of TCS confirmed.',
      'Margin pledge created successfully in demat account.',
      'CVL KRA: Address update request has been successfully processed.',
      'Update of KYC address record in KRA has been confirmed.',
      'Due to scheduled maintenance, banking services will be unavailable from 2am to 5am.',
      'Scheduled maintenance activity is planned for your account portal tonight.',
      'New device registration successful for Mobile Banking on Samsung Galaxy.',
      'Your request for registration of device for UPI has been received.',
      'Your expired insurance policy needs immediate renewal.',
      'Car insurance policy has expired. Renew immediately to stay covered.',
      'Use coupon code SAVE50 to get flat 50% discount on your next ride.',
      'Apply coupon FESTIVE to save Rs. 200 on groceries.',
      'Your order has been dispatched via BlueDart courier AWB 987654.',
      'Item has been dispatched and is on its way to your address.',
      'Package dispatched via Delhivery tracker #12345.',
    ];

    for (final body in noiseAlerts) {
      expect(NeedsReviewRepository.isSecurityOrServiceAlert(body), isTrue, reason: body);
      final item = NeedsReviewItem(
        id: 'noise-test',
        sender: 'VM-ALERT',
        body: body,
        receivedAt: DateTime(2026, 10, 1),
      );
      expect(NeedsReviewRepository.isNoiseItem(item), isTrue, reason: body);
    }
  });

  test('resolveItemKind marks merchant e-bills and receipts as NeedsReviewKind.receipt', () {
    final receiptItem = NeedsReviewItem(
      id: 'receipt-1',
      sender: 'VM-DMART',
      body: 'Thank you for shopping at DMart. View e-bill of Rs 450.00 - https://dmart.in/b/123',
      receivedAt: DateTime(2026, 10, 1),
    );

    final resolved = NeedsReviewRepository.resolveItemKind(receiptItem);
    expect(resolved.kind, NeedsReviewKind.receipt);
    expect(NeedsReviewRepository.isNoiseItem(receiptItem), isFalse);
    expect(NeedsReviewRepository.isNoiseItem(resolved), isFalse);
  });

  test('hasMatchingSpendTransactionSync supports 72h window, payment entry_kind, and avoids distinct store false positives', () {
    final db = openInMemoryForTesting();
    const ns = 'user-test-matching-72h';
    final txnTime = DateTime(2026, 10, 5, 12, 0);

    db.db.execute('''
      CREATE TABLE IF NOT EXISTS financial_entities (
        namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
        payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
        pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
        occurred_at INTEGER, amount_paise INTEGER,
        PRIMARY KEY(namespace, entity, id)
      );
    ''');

    // 1. Spend transaction at Apollo Pharmacy 48 hours earlier with entry_kind = 'payment'
    db.db.execute(
      '''
      INSERT INTO financial_entities(
        namespace, entity, id, payload, observed_at, pending, source_key, occurred_at, amount_paise
      ) VALUES (?, 'transactions', 'txn-apollo-1', ?, ?, 0, 'src1', ?, ?)
      ''',
      [
        ns,
        jsonEncode({
          'id': 'txn-apollo-1',
          'amount_inr': 350.00,
          'occurred_at': txnTime.toIso8601String(),
          'merchant_name': 'Apollo Pharmacy Store 12',
          'entry_kind': 'payment',
        }),
        txnTime.millisecondsSinceEpoch,
        txnTime.millisecondsSinceEpoch,
        35000,
      ],
    );

    // Matching receipt 48 hours later from Apollo Pharmacy (within 72h window)
    final matchingApollo = NeedsReviewItem(
      id: 'ebill-apollo',
      sender: 'VM-APOLLO',
      body: 'Thank you for visiting Apollo Pharmacy. View e-bill of Rs 350.00 - https://apollo.in/b/1',
      receivedAt: txnTime.add(const Duration(hours: 48)),
    );

    // Unmatched receipt with SAME amount (Rs 350) 48h later but DISTINCT store (Starbucks)
    final unmatchedStarbucks = NeedsReviewItem(
      id: 'ebill-starbucks',
      sender: 'VM-STARBK',
      body: 'Thank you for visiting Starbucks Coffee. View e-bill of Rs 350.00 - https://sbux.in/b/2',
      receivedAt: txnTime.add(const Duration(hours: 48)),
    );

    // Receipt with SAME store and amount but 80 hours later (outside 72h window)
    final expiredWindowApollo = NeedsReviewItem(
      id: 'ebill-apollo-too-late',
      sender: 'VM-APOLLO',
      body: 'Thank you for visiting Apollo Pharmacy. View e-bill of Rs 350.00 - https://apollo.in/b/3',
      receivedAt: txnTime.add(const Duration(hours: 80)),
    );

    expect(
      NeedsReviewRepository.hasMatchingSpendTransactionSync(db, ns, matchingApollo),
      isTrue,
    );
    expect(
      NeedsReviewRepository.hasMatchingSpendTransactionSync(db, ns, unmatchedStarbucks),
      isFalse,
    );
    expect(
      NeedsReviewRepository.hasMatchingSpendTransactionSync(db, ns, expiredWindowApollo),
      isFalse,
    );

    db.close();
  });

  test('fetchAll auto-purges receipts older than 30 days and re-triages mandate/bill/spend items', () async {
    final db = openInMemoryForTesting();
    const ns = 'user-test-retriage-comprehensive';
    final repo = NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    );

    final now = DateTime.now();

    // 1. Receipt older than 30 days without matching spend
    final oldReceipt = NeedsReviewItem(
      id: 'old-receipt',
      sender: 'VM-STORE',
      body: 'Thank you for shopping at Metro. View e-bill of Rs 890.00 - https://metro.in/b/99',
      receivedAt: now.subtract(const Duration(days: 35)),
      kind: NeedsReviewKind.receipt,
    );

    // 2. Fresh receipt (received 2 days ago) with NO matching spend -> should be kept
    final freshUnmatchedReceipt = NeedsReviewItem(
      id: 'fresh-receipt',
      sender: 'VM-STORE',
      body: 'Thank you for shopping at Metro. View e-bill of Rs 640.00 - https://metro.in/b/100',
      receivedAt: now.subtract(const Duration(days: 2)),
      kind: NeedsReviewKind.receipt,
    );

    // 3. Mandate item (e.g. APY or standing instruction)
    final mandateItem = NeedsReviewItem(
      id: 'mandate-1',
      sender: 'CP-GOVT',
      body: 'Dear customer, your Atal Pension Yojana contribution amount for the Month May is Rs 46/-, Kindly maintain sufficient bal',
      receivedAt: now.subtract(const Duration(days: 1)),
      kind: NeedsReviewKind.mandate,
    );

    // 4. Credit card AutoPay notice
    final autopayNotice = NeedsReviewItem(
      id: 'autopay-notice-1',
      sender: 'VM-HDFCBK',
      body: 'AutoPay Reminder: Rs.1147 will be deducted from HDFC Bank A/c 1797 on 08/SEP/2026 for Credit Card 8708 bill.',
      receivedAt: now.subtract(const Duration(days: 1)),
      kind: NeedsReviewKind.transaction,
    );

    // 5. NACH / UMRN bank debit transaction
    final nachDebit = NeedsReviewItem(
      id: 'nach-debit-1',
      sender: 'VM-HDFCBK',
      body: 'PAYMENT ALERT! INR 395.00 deducted from HDFC Bank A/C No 1797 towards Capital Float UMRN: HDFC7022004230009315',
      receivedAt: now.subtract(const Duration(hours: 5)),
      kind: NeedsReviewKind.transaction,
    );

    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    for (final item in [oldReceipt, freshUnmatchedReceipt, mandateItem, autopayNotice, nachDebit]) {
      db.db.execute(
        'INSERT INTO local_needs_review VALUES (?,?,?)',
        [ns, item.id, jsonEncode(item.toJson())],
      );
    }

    final remaining = await repo.fetchAll();

    // 1. Only the fresh unmatched receipt remains in Needs Review
    expect(remaining.map((i) => i.id).toList(), ['fresh-receipt']);

    // 2. Old receipt was automatically purged
    final storedRows = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(storedRows.map((r) => r['id']).toList(), ['fresh-receipt']);

    // 3. Mandate alert was persisted to local_commitments
    final commitmentRows = db.db.select(
      'SELECT payload FROM local_commitments WHERE namespace = ?',
      [ns],
    );
    expect(commitmentRows, hasLength(1));
    expect(commitmentRows.single['payload'], contains('Atal Pension Yojana'));

    // 4. AutoPay notice was persisted to sms_observations
    final obsRows = db.db.select(
      "SELECT payload FROM financial_entities WHERE namespace = ? AND entity = 'sms_observations'",
      [ns],
    );
    expect(obsRows, hasLength(1));
    expect(obsRows.single['payload'], contains('8708'));

    // 5. NACH spend debit was persisted to financial_entities as spend transaction
    final txnRows = db.db.select(
      "SELECT payload, amount_paise FROM financial_entities WHERE namespace = ? AND entity = 'transactions'",
      [ns],
    );
    expect(txnRows, hasLength(1));
    expect(txnRows.single['amount_paise'], 39500); // INR 395.00 = 39500 paise

    db.close();
  });

  test('LocalSmsParser credit card AutoPay notice and NACH debit parsing', () {
    final autopay = LocalSmsParser.parse(
      namespace: 'test',
      sender: 'VM-HDFCBK',
      body: 'AutoPay Reminder: Rs.1147 will be deducted from HDFC Bank A/c 1797 on 08/SEP/2026 for Credit Card 8708 bill.',
      receivedAt: DateTime(2026, 9, 1),
    );

    expect(autopay, isNotNull);
    expect(autopay!.cardLast4, '8708');
    expect(autopay.eventType, LocalSmsEventType.bill);
    expect(autopay.amountDue, const Money.fromPaise(114700));
    expect(autopay.dueDate, DateTime(2026, 9, 8));
    expect(autopay.disposition, LocalSmsDisposition.localObservation);
    expect(autopay.reasonCodes, contains('due_date_detected'));
    expect(autopay.reasonCodes, contains('autopay_notice'));

    final nach = LocalSmsParser.parse(
      namespace: 'test',
      sender: 'VM-HDFCBK',
      body: 'PAYMENT ALERT! INR 395.00 deducted from HDFC Bank A/C No 1797 towards Capital Float UMRN: HDFC7022004230009315',
      receivedAt: DateTime(2026, 9, 1),
    );

    expect(nach, isNotNull);
    expect(nach!.eventType, LocalSmsEventType.transaction);
    expect(nach.disposition, LocalSmsDisposition.sync);
    expect(nach.transaction, isNotNull);
    expect(nach.transaction!.entryKind, TxnEntryKind.spend);
    expect(nach.transaction!.amount, const Money.fromPaise(39500));
    expect(nach.transaction!.merchantName, 'Capital Float');
  });

  test('fetchAll and add auto-resolve live refund SMS when matching debit exists', () async {
    final db = openInMemoryForTesting();
    const ns = 'user:refund-test';
    final repo = NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    );

    // 1. Existing spend debit of ₹1000 at Swiggy in SQLite
    final txnTime = DateTime(2026, 10, 10, 12, 0);
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
      VALUES (?, 'transactions', 'txn-swiggy-debit', ?, ?, ?, ?)
      ''',
      [
        ns,
        jsonEncode({
          'id': 'txn-swiggy-debit',
          'amount_inr': 1000.0,
          'occurred_at': txnTime.toIso8601String(),
          'merchant_name': 'Swiggy Bangalore',
          'entry_kind': 'spend',
        }),
        txnTime.millisecondsSinceEpoch,
        txnTime.millisecondsSinceEpoch,
        100000,
      ],
    );

    // 2. Swiggy partial refund SMS of ₹450 received 3 days later
    final refundSwiggy = NeedsReviewItem(
      id: 'refund-swiggy-1',
      sender: 'VM-HDFCBK',
      body: 'Dear customer, Rs. 450.00 has been refunded from Swiggy to your card ending 1234 on 13-Oct-26.',
      receivedAt: txnTime.add(const Duration(days: 3)),
    );

    // 3. Another refund SMS with NO matching spend (Amazon refund with no Amazon debit)
    final refundUnmatched = NeedsReviewItem(
      id: 'refund-unmatched-1',
      sender: 'AX-AxisBk',
      body: 'Refund of INR 800.00 for order at Amazon credited back to your account.',
      receivedAt: txnTime.add(const Duration(days: 4)),
    );

    // Queue both in local_needs_review
    db.db.execute(
      'CREATE TABLE IF NOT EXISTS local_needs_review(namespace TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(namespace,id))',
    );
    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?)',
      [ns, refundSwiggy.id, jsonEncode(refundSwiggy.toJson())],
    );
    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?)',
      [ns, refundUnmatched.id, jsonEncode(refundUnmatched.toJson())],
    );

    // fetchAll auto-resolves Swiggy refund and keeps unmatched refund
    final remaining = await repo.fetchAll();
    expect(remaining.map((i) => i.id).toList(), ['refund-unmatched-1']);

    // Verify Swiggy refund was removed from SQLite local_needs_review
    final storedRows = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(storedRows.map((r) => r['id']).toList(), ['refund-unmatched-1']);

    // Verify refund adjustment link was persisted to financial_entities
    final adjustmentRows = db.db.select(
      "SELECT payload FROM financial_entities WHERE namespace = ? AND entity = 'refund_adjustments'",
      [ns],
    );
    expect(adjustmentRows, hasLength(1));
    final adjustmentData = jsonDecode(adjustmentRows.single['payload'] as String) as Map<String, dynamic>;
    expect(adjustmentData['debit_txn_id'], 'txn-swiggy-debit');
    expect(adjustmentData['original_debit_amount_paise'], 100000);
    expect(adjustmentData['refund_amount_paise'], 45000);
    expect(adjustmentData['net_amount_paise'], 55000);
    expect(adjustmentData['days_apart'], anyOf(2, 3));

    // Verify add() and addNeedsReviewSync() also auto-link and do not queue when matching spend exists
    await repo.add(refundSwiggy);
    final afterAdd = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(afterAdd.map((r) => r['id']).toList(), ['refund-unmatched-1']);

    addNeedsReviewSync(db, ns, refundSwiggy);
    final afterSync = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(afterSync.map((r) => r['id']).toList(), ['refund-unmatched-1']);

    db.close();
  });
  test('fetchAll auto-removes mutual fund folio allotment when matching investment debit exists within 72 hours', () async {
    final db = openInMemoryForTesting();
    final ns = 'mf-test-${DateTime.now().microsecondsSinceEpoch}';
    final repo = NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    );

    // Seed matching investment debit transaction in financial_entities (Rs 5,000 on Oct 5 10:00)
    final debitOccurred = DateTime(2026, 10, 5, 10, 0);
    final debitPayload = {
      'id': 'txn-mf-sip-debit',
      'entry_kind': 'investment',
      'amount_inr': 5000,
      'amount': {'paise': 500000},
      'merchant_name': 'HDFC MF SIP Mandate',
      'occurred_at': debitOccurred.toIso8601String(),
    };
    db.db.execute('''
      CREATE TABLE IF NOT EXISTS financial_entities (
        namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
        payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
        pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
        occurred_at INTEGER, amount_paise INTEGER,
        PRIMARY KEY(namespace, entity, id)
      );
    ''');
    db.db.execute('''
      INSERT INTO financial_entities (namespace, entity, id, payload, observed_at, pending, source_key, occurred_at, amount_paise)
      VALUES (?, 'transactions', 'txn-mf-sip-debit', ?, ?, 0, 'src-sip', ?, 500000)
    ''', [
      ns,
      jsonEncode(debitPayload),
      debitOccurred.millisecondsSinceEpoch,
      debitOccurred.millisecondsSinceEpoch,
    ]);

    // 1. Folio allotment matching the debit (Rs 5,000 on Oct 5 14:00 - within 4 hours)
    final matchedAllotment = NeedsReviewItem(
      id: 'review-allotment-matched',
      sender: 'HDFCMF',
      body: 'Folio 12345/67: Purchase of Rs 5000 in HDFC Top 100 Fund processed. 54.321 units allotted at NAV 92.0450 on 05-Oct-2026.',
      receivedAt: DateTime(2026, 10, 5, 14, 0),
    );

    // 2. Unmatched folio allotment (Rs 12,000 - no matching investment debit exists)
    final unmatchedAllotment = NeedsReviewItem(
      id: 'review-allotment-unmatched',
      sender: 'CAMSSM',
      body: 'Folio 99887766: Purchase of Rs 12000 in Parag Parikh Flexi Cap Fund processed. 45.67 units allotted at NAV 262.75 on 05-Oct-2026.',
      receivedAt: DateTime(2026, 10, 5, 15, 0),
    );

    db.db.execute(
      'INSERT INTO local_needs_review VALUES (?,?,?), (?,?,?)',
      [
        ns, matchedAllotment.id, jsonEncode(matchedAllotment.toJson()),
        ns, unmatchedAllotment.id, jsonEncode(unmatchedAllotment.toJson()),
      ],
    );

    final beforeFetch = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(beforeFetch.map((r) => r['id']).toSet(), {'review-allotment-matched', 'review-allotment-unmatched'});

    // Fetch all: matched allotment must be auto-removed, unmatched kept
    final items = await repo.fetchAll();
    expect(items.map((i) => i.id).toList(), ['review-allotment-unmatched']);

    final afterFetch = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(afterFetch.map((r) => r['id']).toList(), ['review-allotment-unmatched']);

    // addNeedsReviewSync also drops matched allotment
    addNeedsReviewSync(db, ns, matchedAllotment);
    final afterSync = db.db.select('SELECT id FROM local_needs_review WHERE namespace=?', [ns]);
    expect(afterSync.map((r) => r['id']).toList(), ['review-allotment-unmatched']);

    db.close();
  });
}
