import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../support/rules.dart';

// Foreign ATM withdrawals, EMI conversions, non-card foreign debits and forex
// markup fees, run through the real bundle (rules/sms/v2) with synthetic
// messages. A foreign-only amount is never INR; an INR posting keeps the
// foreign amount as its original.

SmsMessage _m(String sender, String body) => SmsMessage(
  sender: sender,
  body: body,
  observedAt: DateTime.utc(2026, 11, 3, 10),
  sourceKey: 'sms:fx-more:${body.hashCode}',
);

void main() {
  final bundle = testRuleBundle();
  final engine = RuleEngine();

  EngineOutcome run(String body, {String sender = 'VM-HDFCBK-S'}) =>
      engine.interpretDetailed(_m(sender, body), bundle, appVersion: 'x');

  MovementFact movement(String body, {String sender = 'VM-HDFCBK-S'}) {
    final out = run(body, sender: sender);
    expect(
      out.result.outcome,
      InterpretOutcome.matched,
      reason: '$body -> ${out.reason} ${out.detail ?? ''}',
    );
    return out.result.facts.whereType<MovementFact>().single;
  }

  group('foreign ATM withdrawals', () {
    // (body, minor, unit, instrument kind)
    const foreignOnly = <(String, int, String, InstrumentKind?)>[
      (
        'Cash withdrawal of USD 200.00 at ATM using your Debit Card XX1234 on 01-11-26.',
        20000,
        'USD',
        InstrumentKind.debitCard,
      ),
      (
        'USD 200.00 withdrawn from Credit Card x1234 at ATM on 01-11-26.',
        20000,
        'USD',
        InstrumentKind.creditCard,
      ),
      (
        'USD 200.00 withdrawn at SAMPLE ATM using Credit Card XX1234 on 01-11-26. Avl Lmt: Rs.1,00,000.00',
        20000,
        'USD',
        InstrumentKind.creditCard,
      ),
      (
        'ATM withdrawal of EUR 100.00 from Bank Card XX1234 at SAMPLE CITY on 01-11-26.',
        10000,
        'EUR',
        null,
      ),
      (
        'Your Debit Card XX1234 has been used for an ATM withdrawal of THB 5,000.00 at SAMPLE BANK ATM on 01-11-26.',
        500000,
        'THB',
        InstrumentKind.debitCard,
      ),
      (
        'Cash withdrawal of JPY 10,000 at ATM using your Forex Card XX1234 on 01-11-26.',
        10000,
        'JPY',
        InstrumentKind.prepaidCard,
      ),
      (
        'GBP 50.00 withdrawn from A/c XX1234 at ATM on 01-11-26.',
        5000,
        'GBP',
        InstrumentKind.bankAccount,
      ),
    ];
    for (final (body, minor, unit, kind) in foreignOnly) {
      test('foreign only: $body', () {
        final f = movement(body);
        expect(
          (f.direction, f.purpose, f.rail),
          (Direction.debit, MovementPurpose.atm, Rail.cash),
        );
        final a = f.amount(AmountRole.posted)!;
        expect((a.minor, a.unit), (minor, unit));
        expect(a.isInr, isFalse, reason: 'a foreign price is never paise');
        expect(f.instrument?.maskDigits, '1234');
        expect(f.instrument?.kind, kind);
      });
    }

    // (body, inr minor, original minor, currency)
    const withInr = <(String, int, int, String)>[
      (
        'Rs.17,450.00 withdrawn from Debit Card x1234 at ATM on 01-11-26 (USD 200.00)',
        1745000,
        20000,
        'USD',
      ),
      (
        'Cash withdrawal of Rs 17,450.00 (USD 200.00) at ATM using your Bank Card XX1234 on 01-11-26.',
        1745000,
        20000,
        'USD',
      ),
      (
        'USD 200.00 (approx INR 17,450.00) withdrawn at ATM using Credit Card XX1234 on 01-11-26.',
        1745000,
        20000,
        'USD',
      ),
      (
        'INR 9,120.00 debited from A/c XX1234 for ATM withdrawal at SAMPLE on 01-11-26 (EUR 100.00)',
        912000,
        10000,
        'EUR',
      ),
    ];
    for (final (body, inr, fx, cur) in withInr) {
      test('INR with original: $body', () {
        final f = movement(body);
        expect(f.purpose, MovementPurpose.atm);
        final a = f.amount(AmountRole.posted)!;
        expect((a.minor, a.unit), (inr, 'INR'));
        expect((a.original?.minor, a.original?.currency), (fx, cur));
      });
    }

    test(
      'a plain INR ATM withdrawal keeps its existing reading, with no original',
      () {
        final f = movement(
          'Rs.2000 withdrawn from Debit Card x1234 at ATM on 01-11-26',
        );
        expect(f.purpose, MovementPurpose.atm);
        expect(f.amount(AmountRole.posted)!.original, isNull);
      },
    );

    for (final body in [
      'ATM withdrawal of USD 200.00 on Card XX1234 declined due to insufficient funds.',
      'Cash withdrawal of USD 200.00 at ATM using your Debit Card XX1234 failed on 01-11-26.',
      'Your international ATM withdrawal limit of USD 500.00 is set on Debit Card XX1234.',
    ]) {
      test('never a withdrawal: $body', () {
        final out = run(body);
        final atm = out.result.facts.whereType<MovementFact>().where(
          (f) => f.purpose == MovementPurpose.atm,
        );
        expect(atm, isEmpty);
      });
    }
  });

  group('EMI conversion of a foreign card transaction is not a second spend', () {
    for (final body in [
      'Your transaction of USD 500.00 at SAMPLE STORE on Credit Card XX1234 has been converted to EMI of Rs 7,350.00 for 6 months.',
      'Dear Customer, txn of Rs 43,500.00 (USD 500.00) on your Credit Card XX1234 at SAMPLE STORE is converted into 6 EMIs of Rs 7,350.00.',
      'EMI conversion successful for transaction of USD 500.00 on Card XX1234. Monthly EMI Rs 7,350.00 for 6 months.',
      'Your foreign currency transaction of USD 500.00 on Credit Card XX1234 has been converted into EMI. EMI amount Rs 7,350.00 for 6 months.',
    ]) {
      test(body, () {
        final out = run(body);
        expect(
          out.result.outcome,
          InterpretOutcome.ignored,
          reason: '${out.winnerId}',
        );
        expect(out.result.facts.whereType<MovementFact>(), isEmpty);
      });
    }

    test(
      'a foreign purchase alert with an EMI offer tail is still the purchase',
      () {
        final f = movement(
          'Spent USD 20.00 on Card x1234 at SAMPLE AI on 2026-11-01:07:00:11. To convert this txn to EMI call us.',
        );
        expect(f.purpose, MovementPurpose.purchase);
        expect(f.amount(AmountRole.posted)!.unit, 'USD');
      },
    );
  });

  group('foreign debits from a bank account or a forex/prepaid card', () {
    // (body, minor, unit, kind, merchant)
    const cases = <(String, int, String, InstrumentKind, String?)>[
      (
        'USD 100.00 debited from your A/c XX1234 on 01-11-26 towards SAMPLE REMIT. Ref 612345678901.',
        10000,
        'USD',
        InstrumentKind.bankAccount,
        'SAMPLE REMIT',
      ),
      (
        'Your A/c XX1234 is debited with EUR 50.00 on 01-11-26 for SAMPLE.',
        5000,
        'EUR',
        InstrumentKind.bankAccount,
        'SAMPLE',
      ),
      (
        'Your Forex Card XX1234 has been debited with EUR 50.00 at SAMPLE CAFE on 01-11-26. Available balance EUR 450.00.',
        5000,
        'EUR',
        InstrumentKind.prepaidCard,
        'SAMPLE CAFE',
      ),
      (
        'EUR 50.00 spent on your Forex Card XX1234 at SAMPLE CAFE on 01-11-26. Avl Bal EUR 450.00',
        5000,
        'EUR',
        InstrumentKind.prepaidCard,
        'SAMPLE CAFE',
      ),
      (
        'Spent USD 20.00 from your Multi-Currency Card XX1234 at SAMPLE on 01-11-26.',
        2000,
        'USD',
        InstrumentKind.prepaidCard,
        'SAMPLE',
      ),
      (
        'Your Debit Card XX1234 has been debited with AED 75.00 at SAMPLE MART on 01-11-26.',
        7500,
        'AED',
        InstrumentKind.debitCard,
        'SAMPLE MART',
      ),
    ];
    for (final (body, minor, unit, kind, merchant) in cases) {
      test(body, () {
        final out = run(body);
        expect(
          out.result.outcome,
          InterpretOutcome.matched,
          reason: '${out.reason} ${out.detail}',
        );
        expect(
          out.result.facts.map((f) => f.factType),
          [FactType.movement],
          reason: 'a foreign balance is never written as an INR balance',
        );
        final f = out.result.facts.single as MovementFact;
        expect(
          (f.direction, f.purpose),
          (Direction.debit, MovementPurpose.purchase),
        );
        final a = f.amount(AmountRole.posted)!;
        expect((a.minor, a.unit), (minor, unit));
        expect(f.instrument?.kind, kind);
        expect(f.instrument?.maskDigits, '1234');
        expect(f.counterparty?.name, merchant);
      });
    }

    test('an account debit carries its transaction reference', () {
      final f = movement(
        'USD 100.00 debited from your A/c XX1234 on 01-11-26 towards SAMPLE REMIT. Ref 612345678901.',
      );
      expect(f.references['txnId'], '612345678901');
    });

    for (final body in [
      'USD 100.00 credited to your A/c XX1234 on 01-11-26 from SAMPLE.',
      'USD 100.00 debit from A/c XX1234 failed on 01-11-26.',
      'Your Forex Card XX1234 has been loaded with USD 1,000.00 on 01-11-26.',
    ]) {
      test('not a foreign debit: $body', () {
        final out = run(body);
        final debits = out.result.facts.whereType<MovementFact>().where(
          (f) =>
              f.direction == Direction.debit &&
              f.purpose == MovementPurpose.purchase,
        );
        expect(debits, isEmpty);
      });
    }
  });

  group('forex markup and cross-currency fees are INR fees', () {
    // (body, fee paise, original minor, currency, txn ref, instrument kind)
    const cases = <(String, int, int?, String?, String?, InstrumentKind?)>[
      (
        'Forex markup fee of Rs 52.50 charged on your Credit Card XX1234 for transaction of USD 20.00 at SAMPLE AI on 01-11-26.',
        5250,
        2000,
        'USD',
        null,
        InstrumentKind.creditCard,
      ),
      (
        'Cross currency markup of Rs 52.50 levied on your Credit Card XX1234 on 01-11-26.',
        5250,
        null,
        null,
        null,
        InstrumentKind.creditCard,
      ),
      (
        'Rs 52.50 debited from your Credit Card XX1234 towards foreign currency markup fee on 01-11-26.',
        5250,
        null,
        null,
        null,
        InstrumentKind.creditCard,
      ),
      (
        'Dear Customer, Rs.52.50 has been charged as Forex Markup Fee on your Bank Card XX1234 for txn ref 123456789012.',
        5250,
        null,
        null,
        '123456789012',
        null,
      ),
      (
        'INR 54.25 charged on Debit Card XX1234 as cross currency mark-up for international txn of EUR 15.50 at SAMPLE on 01-11-26. Ref No 612345678901',
        5425,
        1550,
        'EUR',
        '612345678901',
        InstrumentKind.debitCard,
      ),
      (
        'Rs 52.50 debited from A/c XX1234 on 01-11-26 towards cross currency markup charges for POS txn ref 612345678901.',
        5250,
        null,
        null,
        '612345678901',
        InstrumentKind.bankAccount,
      ),
    ];
    for (final (body, fee, fx, cur, ref, kind) in cases) {
      test(body, () {
        final f = movement(body);
        expect(
          (f.direction, f.purpose),
          (Direction.debit, MovementPurpose.fee),
        );
        final a = f.amount(AmountRole.posted)!;
        expect(
          (a.minor, a.unit),
          (fee, 'INR'),
          reason: 'the fee itself, never the transaction',
        );
        expect(a.original?.minor, fx);
        expect(a.original?.currency, cur);
        expect(f.references['txnId'], ref);
        expect(f.instrument?.kind, kind);
        expect(f.instrument?.maskDigits, '1234');
      });
    }

    test('a purchase that mentions its markup is still the purchase', () {
      final f = movement(
        'Rs 1750.00 spent on Credit Card XX1234 at SAMPLE AI. Foreign currency amount USD 20.00 with forex markup of Rs 52.50 applied.',
      );
      expect(f.purpose, MovementPurpose.purchase);
      expect(f.amount(AmountRole.posted)!.minor, 175000);
    });

    for (final body in [
      'Forex markup fee of Rs 52.50 on your Credit Card XX1234 has been reversed on 05-11-26.',
      'A forex markup fee of 3.5% will be charged on international transactions on your Credit Card XX1234.',
    ]) {
      test('not a fee debit: $body', () {
        final out = run(body);
        final fees = out.result.facts.whereType<MovementFact>().where(
          (f) =>
              f.direction == Direction.debit &&
              f.purpose == MovementPurpose.fee,
        );
        expect(fees, isEmpty);
      });
    }
  });
}
