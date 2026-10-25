import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  test('bill identity is structured and original SMS stays unchanged', () {
    final db = openInMemoryForTesting();
    addTearDown(db.close);
    final repo = PastBillReceiptRepository(db, namespace: 'identity');
    const body = 'Your statement is ready. Please pay the bill in the bank app.';
    repo.archiveBill(
      id: 'bill', sender: 'BANK', merchant: 'Bank',
      amount: Money.fromRupees(100), receivedAt: DateTime(2026, 1, 1),
      dueDate: DateTime(2026, 1, 20), cardLast4: '1234', accountLast4: '5678',
      body: body,
    );
    final restored = repo.fetchAll().single;
    expect(restored.cardLast4, '1234');
    expect(restored.accountLast4, '5678');
    expect(restored.body, body);
    final legacy = {...restored.toJson()}..remove('cardLast4');
    expect(PastBillReceipt.fromJson({...legacy, 'body': 'Card ending 4321'})
      .cardLast4, '4321');
    expect(PastBillReceipt.fromJson({...legacy, 'body': 'Card ending 4321 is due'})
      .cardLast4, isNull);
  });

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
    expect(
      PastBillReceiptRepository(db, namespace: 'user-b').fetchAll(),
      isEmpty,
    );
  });

  test(
    'archive changes refresh the namespace and uncapped history is available',
    () async {
      final db = openInMemoryForTesting();
      addTearDown(db.close);
      final repo = PastBillReceiptRepository(db, namespace: 'user-a');
      final change = PastBillReceiptRepository.changes.first;
      for (final id in ['one', 'two']) {
        repo.upsert(
          PastBillReceipt(
            id: id,
            sourceKey: id,
            merchant: 'Biller',
            amount: Money.fromPaise(10000),
            occurredAt: DateTime(2026, 9, 28),
            receivedAt: DateTime(2026, 9, 28),
            status: PastBillReceiptStatus.needsConfirmation,
          ),
        );
      }

      expect(await change, 'user-a');
      expect(repo.fetchAll(limit: 1), hasLength(1));
      expect(repo.fetchAll(limit: null), hasLength(2));
    },
  );
}
