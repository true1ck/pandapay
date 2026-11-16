import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

TransactionEntry _row({required String source, required TxnRail rail}) =>
    TransactionEntry(
      id: 't',
      amount: Money.fromPaise(10000),
      occurredAt: DateTime(2026, 11, 16),
      source: source,
      rail: rail,
      status: 'active',
    );

void main() {
  test('only an app-logged UPI QR payment is marked as paid via PandaPay', () {
    expect(_row(source: 'manual', rail: TxnRail.upiQr).viaPandaPay, isTrue);
    expect(_row(source: 'sms', rail: TxnRail.upiQr).viaPandaPay, isFalse);
    expect(_row(source: 'manual', rail: TxnRail.swipe).viaPandaPay, isFalse);
  });
}
