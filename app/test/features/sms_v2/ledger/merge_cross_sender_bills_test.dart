import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

Commitment bill(
  String title,
  int rupees,
  DateTime due, {
  String? digits,
  double confidence = 0.9,
  CommitmentStatus status = CommitmentStatus.due,
}) => Commitment(
  id: 'v2:$title$rupees${due.day}',
  title: title,
  category: CommitmentCategory.other,
  amount: Money.fromPaise(rupees * 100),
  dueOn: due,
  identifier: digits,
  status: status,
  confidence: confidence,
);

void main() {
  final dec3 = DateTime(2026, 12, 3);
  final dec8 = DateTime(2026, 12, 8);

  test('issuer statement and bill-pay alert for one card bill become one', () {
    final rows = mergeCrossSenderBills([
      bill('axis bill', 2267, dec3, digits: '••••7105'),
      bill('AxisBankCC', 2267, dec3),
    ]);
    expect(rows.length, 1);
    expect(rows.single.identifier, '••••7105');
  });

  test('the same bill under two names merges whichever arrives first', () {
    final rows = mergeCrossSenderBills([
      bill('Goa', 1316, dec8),
      bill('GoaElectricity', 1316, dec8),
    ]);
    expect(rows.length, 1);
  });

  test('same amount and day with unrelated names stay two bills', () {
    final rows = mergeCrossSenderBills([
      bill('Airtel', 500, dec3),
      bill('Rent', 500, dec3),
    ]);
    expect(rows.length, 2);
  });

  test('same name but a different amount or day stays apart', () {
    expect(
      mergeCrossSenderBills([
        bill('Goa', 1316, dec8),
        bill('GoaElectricity', 1400, dec8),
      ]).length,
      2,
    );
    expect(
      mergeCrossSenderBills([
        bill('Goa', 1316, dec8),
        bill('GoaElectricity', 1316, DateTime(2026, 12, 9)),
      ]).length,
      2,
    );
  });

  test('paid on either side keeps the merged bill paid', () {
    final paidOn = DateTime(2026, 12, 1);
    final rows = mergeCrossSenderBills([
      bill('axis bill', 2267, dec3, digits: '••••7105'),
      bill('AxisBankCC', 2267, dec3, status: CommitmentStatus.paid)
          .copyWith(paidOn: paidOn),
    ]);
    expect(rows.single.status, CommitmentStatus.paid);
    expect(rows.single.identifier, '••••7105');
    expect(rows.single.paidOn, paidOn);
  });

  test('a bill with no amount is never merged', () {
    final noAmount = Commitment(
      id: 'x',
      title: 'Goa',
      category: CommitmentCategory.other,
      dueOn: dec8,
    );
    expect(mergeCrossSenderBills([noAmount, noAmount.copyWith(id: 'y')]).length,
        2);
  });
}
