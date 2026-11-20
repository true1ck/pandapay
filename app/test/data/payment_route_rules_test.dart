import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/payment_route_rules.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/data/user_cards_repository.dart';

void main() {
  test('a route must suit how it was paid', () {
    expect(railFitsInstrument(TxnRail.swipe, TxnInstrument.cash), isFalse);
    expect(railFitsInstrument(TxnRail.swipe, TxnInstrument.upiBank), isFalse);
    expect(railFitsInstrument(TxnRail.upiQr, TxnInstrument.upiBank), isTrue);
    expect(railFitsInstrument(TxnRail.swipe, TxnInstrument.creditCard), isTrue);
    for (final i in TxnInstrument.values) {
      expect(railFitsInstrument(TxnRail.unknown, i), isTrue);
    }
  });

  test('a debit card cannot back a credit-card payment', () {
    expect(cardFitsInstrument('debit', TxnInstrument.creditCard), isFalse);
    expect(cardFitsInstrument('credit', TxnInstrument.creditCard), isTrue);
    expect(cardFitsInstrument(null, TxnInstrument.creditCard), isTrue);
    expect(cardFitsInstrument('debit', TxnInstrument.debitCard), isTrue);
  });
}
