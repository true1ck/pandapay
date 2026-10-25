import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';

void main() {
  late AppDatabase db;
  late FinancialStore store;
  late SmsImportStore importStore;
  const ns = 'user:test_bills';

  setUp(() {
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    importStore = SmsImportStore(store);
  });

  tearDown(() {
    store.dispose();
    db.close();
  });

  test('upcoming bill with dueDate in future routes directly to local_commitments and bypasses review', () {
    final futureDate = DateTime.now().add(const Duration(days: 7));
    final day = futureDate.day.toString().padLeft(2, '0');
    final month = futureDate.month.toString().padLeft(2, '0');
    final year = futureDate.year;

    final sms = QueuedSms(
      sender: 'TS-TSSPDCL',
      body: 'TSSPDCL Electricity Bill for service no 12345. Bill amount is Rs 1450.00. Due date is $day-$month-$year.',
      receivedAt: DateTime.now(),
    );

    importStore.captureBatch(ns, [sms]);

    // Check local_commitments
    final commitments = db.db.select(
      'SELECT payload FROM local_commitments WHERE namespace = ?',
      [ns],
    );
    expect(commitments, hasLength(1));
    final commitmentJson = jsonDecode(commitments.first['payload'] as String) as Map<String, dynamic>;
    expect(commitmentJson['amount_paise'], 145000);
    expect(commitmentJson['title'], contains('TSSPDCL'));

    // Check that it did NOT enter local_needs_review
    final reviewRows = db.db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='local_needs_review'",
    );
    if (reviewRows.isNotEmpty) {
      final inReview = db.db.select(
        'SELECT * FROM local_needs_review WHERE namespace = ?',
        [ns],
      );
      expect(inReview, isEmpty);
    }
  });

  test('past bill with dueDate in past routes directly to PastBillReceiptRepository and bypasses review', () {
    final pastDate = DateTime.now().subtract(const Duration(days: 15));
    final day = pastDate.day.toString().padLeft(2, '0');
    final month = pastDate.month.toString().padLeft(2, '0');
    final year = pastDate.year;

    final sms = QueuedSms(
      sender: 'TS-TSSPDCL',
      body: 'TSSPDCL Electricity Bill for service no 12345. Bill amount is Rs 1450.00. Due date is $day-$month-$year.',
      receivedAt: pastDate.subtract(const Duration(days: 5)),
    );

    importStore.captureBatch(ns, [sms]);

    // Check that it was NOT added to local_commitments
    final commitments = db.db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='local_commitments'",
    );
    if (commitments.isNotEmpty) {
      final active = db.db.select(
        'SELECT * FROM local_commitments WHERE namespace = ?',
        [ns],
      );
      expect(active, isEmpty);
    }

    // Check PastBillReceiptRepository
    final pastReceipts = PastBillReceiptRepository(db, namespace: ns).fetchAll();
    expect(pastReceipts, hasLength(1));
    expect(pastReceipts.first.amount?.paise, 145000);

    // Check that it did NOT enter local_needs_review
    final reviewRows = db.db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='local_needs_review'",
    );
    if (reviewRows.isNotEmpty) {
      final inReview = db.db.select(
        'SELECT * FROM local_needs_review WHERE namespace = ?',
        [ns],
      );
      expect(inReview, isEmpty);
    }
  });
}
