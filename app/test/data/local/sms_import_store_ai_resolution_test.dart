import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/auto_resolved_history_repository.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_auto_resolution_controller.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/local/sms_learning_feedback.dart';
import 'package:pandapay/data/local_sms_parser.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FinancialStore store;
  late SmsImportStore importStore;
  const ns = 'user:ai_resolution';
  const sourceKey =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    importStore = SmsImportStore(store);
  });

  tearDown(() {
    store.dispose();
    db.close();
  });

  NeedsReviewItem reviewItem({String id = sourceKey, String? body}) =>
      NeedsReviewItem(
        id: id,
        sender: 'HDFCBK',
        body:
            body ??
            'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on '
                '24-10-26. UPI Ref 429812345678. Avail Bal: Rs.45,120.50',
        reason: 'ambiguous_account_debit',
        receivedAt: DateTime(2026, 10, 24, 10),
      );

  void insertReviewRow(NeedsReviewItem item) {
    db.db.execute(
      'INSERT OR REPLACE INTO local_needs_review VALUES (?,?,?)',
      [ns, item.id, jsonEncode(item.toJson())],
    );
  }

  int reviewCount() => db.db
      .select('SELECT COUNT(*) AS n FROM local_needs_review WHERE namespace=?', [
        ns,
      ])
      .single['n'] as int;

  List<Map<String, dynamic>> transactions() => store.entities(
    ns,
    'transactions',
  );

  Map<String, dynamic> swiggySuggestion({bool isComplete = true}) => {
    'factIndex': 0,
    'factType': 'posted_movement',
    'payload': {
      'amountRole': 'posted',
      'entryKind': 'spend',
      'amountInr': 420.0,
      'occurredAt': '2026-10-24T00:00:00.000Z',
      'instrument': 'upi_bank',
      'accountLast4': '1797',
      'issuerName': 'HDFC Bank',
      'merchant': 'Swiggy',
      'category': 'dining',
      'isComplete': isComplete,
      'confidence': 0.98,
    },
  };

  Map<String, dynamic> partialSuggestion() => {
    'factIndex': 0,
    'factType': 'posted_movement',
    'payload': {
      'amountRole': 'posted',
      'entryKind': 'spend',
      'amountInr': 750.0,
      'occurredAt': '2026-10-24T00:00:00.000Z',
      'instrument': 'upi_bank',
      'accountLast4': '1797',
      'category': 'other',
      'isComplete': false,
      'confidence': 0.65,
    },
  };

  Map<String, dynamic> billSuggestion(DateTime due) => {
    'factIndex': 0,
    'factType': 'bill_obligation',
    'payload': {
      'amountRole': 'due_total',
      'amountDueInr': 1450.0,
      'dueDate': due.toUtc().toIso8601String(),
      'billerName': 'BESCOM',
      'accountLast4': '8475',
      'category': 'bills',
      'targetKind': 'utility_or_other_bill',
      'isComplete': true,
      'confidence': 0.96,
    },
  };

  String billBody(DateTime due) {
    final day = due.day.toString().padLeft(2, '0');
    final month = due.month.toString().padLeft(2, '0');
    return 'BESCOM Electricity bill for CA 102938475 is Rs 1,450.00. '
        'Due date is $day-$month-${due.year}.';
  }

  /// UTC midnight so the printed date and the scored anchor are the same day.
  DateTime utcDayOffset(int days) {
    final now = DateTime.now();
    return DateTime.utc(now.year, now.month, now.day).add(Duration(days: days));
  }

  test('Tier 1 spend writes a transaction and history, then removes review', () {
    final item = reviewItem();
    insertReviewRow(item);

    final result = importStore.resolveAiSuggestions(ns, item, [
      swiggySuggestion(),
    ]);

    expect(result.outcome, SmsAiResolutionOutcome.autoResolved);
    expect(result.score, greaterThanOrEqualTo(0.85));
    expect(result.historyId, 'ai:$sourceKey');
    expect(reviewCount(), 0);

    final rows = transactions();
    expect(rows, hasLength(1));
    expect(rows.single['id'], 'local-ai:$sourceKey');
    expect(rows.single['source_key'], sourceKey);
    expect(rows.single['amount_inr'], 420.0);
    expect(rows.single['category_id'], 'dining');
    expect(rows.single['category_name'], 'Dining');
    expect(rows.single['instrument'], 'upi_bank');
    expect(rows.single['entry_kind'], 'spend');
    expect(rows.single['source'], 'sms');
    expect(rows.single['status'], 'active');

    final history = AutoResolvedHistoryRepository(
      db,
      namespace: ns,
    ).fetchAll();
    expect(history, hasLength(1));
    final entry = history.single;
    expect(entry.id, 'ai:$sourceKey');
    expect(entry.resolvedKind, 'transaction');
    expect(entry.title, 'Swiggy');
    expect(entry.amountPaise, 42000);
    expect(entry.categorySlug, 'dining');
    expect(entry.categoryName, 'Dining');
    expect(entry.confidence, result.score);
    expect(entry.isUserModified, isFalse);
  });

  test('replay is idempotent: one transaction, one history row', () {
    final item = reviewItem();
    insertReviewRow(item);

    importStore.resolveAiSuggestions(ns, item, [swiggySuggestion()]);
    final replay = importStore.resolveAiSuggestions(ns, item, [
      swiggySuggestion(),
    ]);

    expect(replay.outcome, SmsAiResolutionOutcome.autoResolved);
    expect(transactions(), hasLength(1));
    expect(
      AutoResolvedHistoryRepository(db, namespace: ns).count(),
      1,
    );
  });

  test('Tier 1 future bill writes local_commitments and history', () {
    final due = utcDayOffset(7);
    final item = reviewItem(body: billBody(due));
    insertReviewRow(item);

    final result = importStore.resolveAiSuggestions(ns, item, [
      billSuggestion(due),
    ]);

    expect(result.outcome, SmsAiResolutionOutcome.autoResolved);
    expect(reviewCount(), 0);
    expect(transactions(), isEmpty);

    final commitments = db.db.select(
      'SELECT payload FROM local_commitments WHERE namespace=?',
      [ns],
    );
    expect(commitments, hasLength(1));
    final payload =
        jsonDecode(commitments.single['payload'] as String)
            as Map<String, dynamic>;
    expect(payload['id'], 'commitment:$sourceKey');
    expect(payload['amount_paise'], 145000);
    expect(payload['title'], 'BESCOM');
    expect(payload['status'], 'due');
    expect(payload['source'], 'sms');

    final history = AutoResolvedHistoryRepository(
      db,
      namespace: ns,
    ).fetchAll();
    expect(history.single.resolvedKind, 'bill');
    expect(history.single.amountPaise, 145000);
    expect(history.single.dueDate, isNotNull);
  });

  test('expired bill writes a past receipt, not an open commitment', () {
    final due = utcDayOffset(-15);
    final item = reviewItem(body: billBody(due));
    insertReviewRow(item);

    final result = importStore.resolveAiSuggestions(ns, item, [
      billSuggestion(due),
    ]);

    expect(result.outcome, SmsAiResolutionOutcome.autoResolved);
    expect(reviewCount(), 0);
    final commitments = db.db.select(
      'SELECT * FROM local_commitments WHERE namespace=?',
      [ns],
    );
    expect(commitments, isEmpty);

    final receipts = PastBillReceiptRepository(db, namespace: ns).fetchAll();
    expect(receipts, hasLength(1));
    expect(receipts.single.id, 'commitment:$sourceKey');
    expect(receipts.single.amount?.paise, 145000);
    expect(receipts.single.status, PastBillReceiptStatus.historicalUnpaid);
  });

  test('Tier 2 keeps the review row and files nothing', () {
    final item = reviewItem(
      body:
          'A/c XX1797 debited for INR 750.00 on 24-10-26. Info: POS-TXN. '
          'Avail Bal: 21,400.00.',
    );
    insertReviewRow(item);

    final result = importStore.resolveAiSuggestions(ns, item, [
      partialSuggestion(),
    ]);

    expect(result.outcome, SmsAiResolutionOutcome.needsReview);
    expect(result.score, greaterThanOrEqualTo(0.45));
    expect(result.score, lessThan(0.85));
    expect(reviewCount(), 1);
    expect(transactions(), isEmpty);
    expect(AutoResolvedHistoryRepository(db, namespace: ns).count(), 0);
  });

  test('server reviewRequired=true keeps an otherwise high score in review', () {
    final item = reviewItem();
    insertReviewRow(item);

    final result = importStore.resolveAiSuggestions(
      ns,
      item,
      [swiggySuggestion()],
      reviewRequired: true,
    );

    expect(result.outcome, SmsAiResolutionOutcome.needsReview);
    expect(reviewCount(), 1);
    expect(transactions(), isEmpty);
  });

  test('a server confidence score overrides the local composite', () {
    final item = reviewItem();
    insertReviewRow(item);

    final discarded = importStore.resolveAiSuggestions(
      ns,
      item,
      [swiggySuggestion()],
      serverScore: 0.2,
    );
    expect(discarded.outcome, SmsAiResolutionOutcome.discarded);
    expect(reviewCount(), 0);
    expect(transactions(), isEmpty);
  });

  test('Tier 3 removes the review row silently', () {
    final item = reviewItem(
      body: 'Get 10% cashback on your next Amazon purchase. Offer valid.',
    );
    insertReviewRow(item);

    final result = importStore.resolveAiSuggestions(ns, item, const []);

    expect(result.outcome, SmsAiResolutionOutcome.discarded);
    expect(result.score, 0);
    expect(reviewCount(), 0);
    expect(AutoResolvedHistoryRepository(db, namespace: ns).count(), 0);
  });

  test('a movement fact without an amount stays in review', () {
    final item = reviewItem();
    insertReviewRow(item);
    final suggestion = swiggySuggestion();
    (suggestion['payload'] as Map<String, dynamic>).remove('amountInr');

    final result = importStore.resolveAiSuggestions(ns, item, [suggestion]);

    expect(result.outcome, SmsAiResolutionOutcome.needsReview);
    expect(reviewCount(), 1);
    expect(transactions(), isEmpty);
  });

  test('a mandate is logged as history and never turned into a bill', () {
    final item = reviewItem(
      body:
          'AutoPay e-mandate successfully registered for NETFLIX '
          'Entertainment with max limit INR 1,500.00 on HDFC Bank Card '
          'ending 1234. UMN: HDFC998877.',
    );
    insertReviewRow(item);

    final result = importStore.resolveAiSuggestions(ns, item, [
      {
        'factIndex': 0,
        'factType': 'mandate_lifecycle',
        'payload': {
          'amountRole': 'ceiling',
          'limitInr': 1500.0,
          'asOfAt': '2026-10-25T00:00:00.000Z',
          'mandateStatus': 'registered',
          'targetKind': 'service_merchant',
          'serviceName': 'Netflix',
          'merchant': 'Netflix',
          'instrument': 'credit_card',
          'last4': '1234',
          'reference': 'HDFC998877',
          'isComplete': true,
          'confidence': 0.99,
        },
      },
    ]);

    expect(result.outcome, SmsAiResolutionOutcome.autoResolved);
    expect(reviewCount(), 0);
    expect(transactions(), isEmpty);
    expect(db.db.select('SELECT * FROM local_commitments'), isEmpty);
    final history = AutoResolvedHistoryRepository(
      db,
      namespace: ns,
    ).fetchAll();
    expect(history.single.resolvedKind, 'mandate');
    expect(history.single.amountPaise, 150000);
  });

  test('a user category correction categories the next message instantly', () {
    const body =
        'Rs 349.00 spent on HDFC Bank Card ending 1234 at BUNDL '
        'TECHNOLOGIES on 20-Oct-26.';

    final baseline = LocalSmsParser.parse(
      namespace: ns,
      sender: 'HDFCBK',
      body: body,
      receivedAt: DateTime(2026, 10, 20),
    );
    expect(baseline?.transaction?.categoryId, 'dining');

    final feedback = SmsLearningFeedback(db, namespace: ns);
    feedback.recordCategoryCorrection(
      merchantOrPattern: '  bundl   technologies ',
      categorySlug: 'groceries',
    );
    final rules = feedback.loadRulesSync();
    expect(rules, {'BUNDL TECHNOLOGIES': 'groceries'});
    expect(feedback.pendingSync(), hasLength(1));

    final corrected = LocalSmsParser.parse(
      namespace: ns,
      sender: 'HDFCBK',
      body: body,
      receivedAt: DateTime(2026, 10, 20),
      userCategoryRules: rules,
    );
    expect(corrected?.transaction?.categoryId, 'groceries');
    expect(corrected?.transaction?.categoryName, 'Groceries');
    expect(corrected?.transaction?.amount.paise, 34900);
  });

  SmsAutoResolutionController controller() => SmsAutoResolutionController(
    database: db,
    store: store,
    reviewRepository: NeedsReviewRepository(
      namespace: ns,
      loadDatabase: () async => db,
    ),
    namespace: ns,
  );

  test('changeCategory retags receipt, transaction and learns a rule', () async {
    final item = reviewItem();
    insertReviewRow(item);
    importStore.resolveAiSuggestions(ns, item, [swiggySuggestion()]);
    final entry = AutoResolvedHistoryRepository(db, namespace: ns).fetchAll().single;

    await controller().changeCategory(entry, 'groceries');

    final updated = AutoResolvedHistoryRepository(
      db,
      namespace: ns,
    ).fetchAll().single;
    expect(updated.categorySlug, 'groceries');
    expect(updated.categoryName, 'Groceries');
    expect(updated.isUserModified, isTrue);

    final rows = transactions();
    expect(rows, hasLength(1));
    expect(rows.single['category_id'], 'groceries');
    expect(rows.single['category_name'], 'Groceries');
    expect(rows.single['amount_inr'], 420.0);

    expect(SmsLearningFeedback(db, namespace: ns).loadRulesSync(), {
      'SWIGGY': 'groceries',
    });
  });

  test('moveToReview deletes the auto-filed row and reopens review', () async {
    final item = reviewItem();
    insertReviewRow(item);
    importStore.resolveAiSuggestions(ns, item, [swiggySuggestion()]);
    final entry = AutoResolvedHistoryRepository(db, namespace: ns).fetchAll().single;
    expect(reviewCount(), 0);

    await controller().moveToReview(entry);

    expect(transactions(), isEmpty);
    expect(AutoResolvedHistoryRepository(db, namespace: ns).count(), 0);
    expect(reviewCount(), 1);
    final payload =
        jsonDecode(
              db.db.select(
                    'SELECT payload FROM local_needs_review WHERE namespace=? '
                    'AND id=?',
                    [ns, sourceKey],
                  ).single['payload']
                  as String,
            )
            as Map<String, dynamic>;
    expect(payload['reason'], 'moved_from_auto_resolved');
    expect(payload['sender'], 'HDFCBK');
    expect(payload['body'], contains('previously auto-categorized by AI'));
  });

  test('moveToReview removes a bill commitment and reopens review', () async {
    final due = utcDayOffset(7);
    final item = reviewItem(body: billBody(due));
    insertReviewRow(item);
    importStore.resolveAiSuggestions(ns, item, [billSuggestion(due)]);
    expect(
      db.db.select('SELECT * FROM local_commitments WHERE namespace=?', [ns]),
      hasLength(1),
    );
    final entry = AutoResolvedHistoryRepository(db, namespace: ns).fetchAll().single;

    await controller().moveToReview(entry);

    expect(
      db.db.select('SELECT * FROM local_commitments WHERE namespace=?', [ns]),
      isEmpty,
    );
    expect(AutoResolvedHistoryRepository(db, namespace: ns).count(), 0);
    expect(reviewCount(), 1);
    final payload =
        jsonDecode(
              db.db.select(
                    'SELECT payload FROM local_needs_review WHERE namespace=? '
                    'AND id=?',
                    [ns, sourceKey],
                  ).single['payload']
                  as String,
            )
            as Map<String, dynamic>;
    expect(payload['reason'], 'moved_from_auto_resolved');
    expect(payload['kind'], 'commitment');
  });
}
