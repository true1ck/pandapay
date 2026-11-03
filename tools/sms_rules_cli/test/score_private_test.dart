import 'package:test/test.dart';

import '../tool/score_private.dart';

void main() {
  Map<String, Object?> leg(
    String type,
    String role, {
    bool spend = false,
    bool income = false,
    bool investment = false,
  }) => {
    'type': type,
    'role': role,
    'ledger': [
      {'isSpend': spend, 'isIncome': income, 'isInvestment': investment},
    ],
  };

  test(
    'a card receipt and duplicate notices do not inherit a money effect',
    () {
      expect(ledgerEffect([leg('card_bill_payment', 'credit_leg')]), 'none');
      expect(ledgerEffect([leg('card_bill_payment', 'debit_leg')]), 'transfer');
      expect(
        ledgerEffect([leg('purchase', 'duplicate_notice', spend: true)]),
        'none',
      );
    },
  );

  test('an IPO hold does not inherit the allotment debit', () {
    expect(
      ledgerEffect([leg('ipo_application', 'hold_placed', investment: true)]),
      'none',
    );
    expect(
      ledgerEffect([leg('ipo_application', 'debit_leg', investment: true)]),
      'investment_invested',
    );
  });

  test('wallet spending, income and refunds keep distinct effects', () {
    expect(
      ledgerEffect([leg('wallet_topup', 'debit_leg', spend: true)]),
      'spending',
    );
    expect(
      ledgerEffect([leg('income', 'credit_leg', income: true)]),
      'money_in',
    );
    expect(ledgerEffect([leg('refund', 'reversal')]), 'refund');
  });
}
