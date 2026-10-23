import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test('past receipt round-trips status, amount, dates, and link', () {
    final original = PastBillReceipt(
      id: 'receipt-1',
      sourceKey: 'source-1',
      merchant: 'Apollo Pharmacy',
      amount: Money.fromPaise(41310),
      occurredAt: DateTime(2026, 9, 28, 22, 8),
      receivedAt: DateTime(2026, 9, 28, 22, 10),
      status: PastBillReceiptStatus.paidLinked,
      linkedTransactionId: 'txn-1',
      sender: 'CP-APLPHR-S',
      body: 'Thank you for your purchase @ Apollo Pharmacy. Bill Rs.413.10',
    );

    final restored = PastBillReceipt.fromJson(original.toJson());
    expect(restored.id, original.id);
    expect(restored.merchant, 'Apollo Pharmacy');
    expect(restored.amount?.paise, 41310);
    expect(restored.status, PastBillReceiptStatus.paidLinked);
    expect(restored.linkedTransactionId, 'txn-1');
  });

  test('repository upsert is idempotent and namespace scoped', () {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final repo = PastBillReceiptRepository(db, namespace: 'user-a');
    final item = PastBillReceipt(
      id: 'receipt-1',
      sourceKey: 'source-1',
      merchant: 'Apollo Pharmacy',
      amount: Money.fromPaise(41310),
      occurredAt: DateTime(2026, 9, 28),
      receivedAt: DateTime(2026, 9, 28),
      status: PastBillReceiptStatus.paidUnlinked,
    );
    repo.upsert(item);
    repo.upsert(item);
    expect(repo.fetchAll(), hasLength(1));
    expect(PastBillReceiptRepository(db, namespace: 'user-b').fetchAll(), isEmpty);
  });
}
