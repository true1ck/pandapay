import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/sms_fact_scoring.dart';

Map<String, dynamic> fact(String type, Map<String, dynamic> payload) => {
  'factType': type,
  'payload': payload,
};

const swiggyBody =
    'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on 24-10-26. '
    'UPI Ref 429812345678. Avail Bal: Rs.45,120.50';

Map<String, dynamic> swiggyFact({
  bool isComplete = true,
  double confidence = 0.98,
}) => fact('posted_movement', {
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
  'confidence': confidence,
});

const partialBody =
    'A/c XX1797 debited for INR 750.00 on 24-10-26. Info: POS-TXN. '
    'Avail Bal: 21,400.00.';

Map<String, dynamic> partialFact() => fact('posted_movement', {
  'amountRole': 'posted',
  'entryKind': 'spend',
  'amountInr': 750.0,
  'occurredAt': '2026-10-24T00:00:00.000Z',
  'instrument': 'upi_bank',
  'accountLast4': '1797',
  'category': 'other',
  'isComplete': false,
  'confidence': 0.65,
});

const axisBillBody =
    'Your Axis Bank Credit Card XX8891 statement generated. Total Due: '
    'Rs 14,850.00, Min Due: Rs 750.00, Due Date: 12-Nov-2026.';

Map<String, dynamic> axisBillFact({bool isComplete = true}) =>
    fact('bill_obligation', {
      'amountRole': 'due_total',
      'amountDueInr': 14850.0,
      'dueDate': '2026-11-12T00:00:00.000Z',
      'instrument': 'credit_card',
      'last4': '8891',
      'issuerName': 'Axis Bank',
      'billerName': 'Axis Bank Credit Card',
      'category': 'bills',
      'targetKind': 'card_bill',
      'isComplete': isComplete,
      'confidence': 0.99,
    });

void main() {
  test('complete high-confidence Swiggy spend is auto-resolvable', () {
    final assessment = assessSmsFacts([swiggyFact()], swiggyBody);
    expect(assessment.primaryFact?['factType'], 'posted_movement');
    expect(
      assessment.composite,
      greaterThanOrEqualTo(kSmsAutoResolveThreshold),
    );
    expect(assessment.isComplete, isTrue);
    expect(assessment.autoResolvable, isTrue);
    final scored = assessment.facts.single;
    expect(scored.model, closeTo(0.98, 0.0001));
    expect(scored.completeness, 1.0);
    expect(scored.disambiguation, 1.0);
    expect(scored.evidence, greaterThan(0.8));
  });

  test('partial draft (isComplete false, confidence .65) needs review', () {
    final assessment = assessSmsFacts([partialFact()], partialBody);
    expect(assessment.composite, greaterThanOrEqualTo(kSmsReviewThreshold));
    expect(assessment.composite, lessThan(kSmsAutoResolveThreshold));
    expect(assessment.isComplete, isFalse);
    expect(assessment.autoResolvable, isFalse);
  });

  test('complete card bill obligation is auto-resolvable', () {
    final assessment = assessSmsFacts([axisBillFact()], axisBillBody);
    expect(
      assessment.composite,
      greaterThanOrEqualTo(kSmsAutoResolveThreshold),
    );
    expect(assessment.autoResolvable, isTrue);
  });

  test(
    'source-evidenced utility biller can auto-resolve a normalized bill',
    () {
      const body = 'Your electricity bill of Rs 1,240 is due on 05 Nov 2026.';
      final normalizedBill = fact('bill_obligation', {
        'amountRole': 'due_total',
        'amountDueInr': 1240.0,
        'dueDate': '2026-11-04T18:30:00.000Z',
        'billerName': 'Electricity',
        'category': 'bills',
        'isComplete': true,
        'confidence': 0.9,
      });
      final assessment = assessSmsFacts([normalizedBill], body);
      expect(assessment.facts.single.disambiguation, 1.0);
      expect(assessment.autoResolvable, isTrue);
    },
  );

  test(
    'completed bill payment can use phone receipt time when SMS has no date',
    () {
      const body =
          'Your payment of Rs 3,160.80 for REF123 was completed successfully. Available balance is Rs 1.20. Details at Turtlemint.';
      final receivedAt = DateTime.utc(2026, 4, 15, 6, 59);
      final payment = fact('bill_payment', {
        'amountRole': 'posted',
        'amountInr': 3160.8,
        'occurredAt': receivedAt.toIso8601String(),
        'billerName': 'Turtlemint',
        'entryKind': 'transfer',
        'isComplete': true,
        'confidence': 0.8,
      });
      final assessment = assessSmsFacts(
        [payment],
        body,
        receivedAt: receivedAt,
      );
      expect(
        assessment.autoResolvable,
        isTrue,
        reason:
            'score=${assessment.composite} fact=${assessment.facts.single.composite} evidence=${assessment.facts.single.evidence} completeness=${assessment.facts.single.completeness}',
      );
      expect(smsHasCompletionEvidence(body), isTrue);
      expect(
        assessment.composite,
        greaterThanOrEqualTo(kSmsAutoResolveThreshold),
      );
    },
  );

  test(
    'completed posted movement can use phone receipt time when SMS has no date',
    () {
      const body = 'Rs 420.00 debited for Swiggy UPI successfully.';
      final receivedAt = DateTime.utc(2026, 10, 24, 12, 30);
      final movement = fact('posted_movement', {
        'amountRole': 'posted',
        'amountInr': 420.0,
        'occurredAt': receivedAt.toIso8601String(),
        'entryKind': 'spend',
        'instrument': 'upi_bank',
        'merchant': 'Swiggy',
        'category': 'dining',
        'isComplete': true,
        'confidence': 0.9,
      });
      final assessment = assessSmsFacts(
        [movement],
        body,
        receivedAt: receivedAt,
      );
      expect(assessment.autoResolvable, isTrue);
      expect(
        assessment.composite,
        greaterThanOrEqualTo(kSmsAutoResolveThreshold),
      );
      expect(assessment.facts.single.evidence, 0.75);
    },
  );

  test('unsupported merchant and multi-fact results stay in review', () {
    const body = 'Rs 420.00 debited successfully.';
    final receivedAt = DateTime.utc(2026, 10, 24, 12, 30);
    final unsupportedParty = fact('posted_movement', {
      'amountRole': 'posted',
      'amountInr': 420.0,
      'occurredAt': receivedAt.toIso8601String(),
      'entryKind': 'spend',
      'instrument': 'upi_bank',
      'merchant': 'Unrelated Vendor',
      'category': 'dining',
      'isComplete': true,
      'confidence': 0.9,
    });
    final unsupported = assessSmsFacts(
      [unsupportedParty],
      body,
      receivedAt: receivedAt,
    );
    expect(unsupported.facts.single.disambiguation, 0.0);
    expect(unsupported.autoResolvable, isFalse);

    final multiple = assessSmsFacts([swiggyFact(), swiggyFact()], swiggyBody);
    expect(multiple.actionableFacts, hasLength(2));
    expect(multiple.autoResolvable, isFalse);
  });

  test('receipt timestamp window matches server precision exactly', () {
    const body = 'Rs 420.00 debited for Swiggy UPI successfully.';
    final receivedAt = DateTime.utc(2026, 10, 24, 12, 30);
    final factAt = receivedAt.add(const Duration(minutes: 5, seconds: 59));
    final movement = fact('posted_movement', {
      'amountRole': 'posted',
      'amountInr': 420.0,
      'occurredAt': factAt.toIso8601String(),
      'entryKind': 'spend',
      'instrument': 'upi_bank',
      'merchant': 'Swiggy',
      'category': 'dining',
      'isComplete': true,
      'confidence': 0.9,
    });
    final assessment = assessSmsFacts([movement], body, receivedAt: receivedAt);
    expect(assessment.facts.single.evidence, 0.55);
    expect(assessment.autoResolvable, isFalse);
  });

  test('posted movement amount cannot be taken from nearby balance_after', () {
    const body =
        'Rs 1,249.00 sent to SWIGGY UPI, available balance: Rs 18,422.65';
    final receivedAt = DateTime.utc(2026, 9, 5, 0, 0);
    Map<String, dynamic> movement(double amount) => fact('posted_movement', {
      'amountRole': 'posted',
      'amountInr': amount,
      'occurredAt': receivedAt.toIso8601String(),
      'entryKind': 'spend',
      'instrument': 'upi_bank',
      'merchant': 'Swiggy',
      'category': 'dining',
      'isComplete': true,
      'confidence': 0.99,
    });

    final trueAmount = assessSmsFacts(
      [movement(1249)],
      body,
      receivedAt: receivedAt,
    );
    final balanceAmount = assessSmsFacts(
      [movement(18422.65)],
      body,
      receivedAt: receivedAt,
    );
    expect(trueAmount.facts.single.evidence, 0.75);
    expect(trueAmount.autoResolvable, isTrue);
    expect(balanceAmount.facts.single.evidence, 0.35);
    expect(balanceAmount.autoResolvable, isFalse);
  });

  test(
    'bill payment cannot use a nearby available balance as the transaction amount',
    () {
      const body =
          'Your payment of Rs 3,160.80 for REF123 was completed successfully. Available balance is Rs 1.20.';
      final receivedAt = DateTime.utc(2026, 4, 15, 6, 59);
      final payment = fact('bill_payment', {
        'amountRole': 'posted',
        'amountInr': 1.2,
        'occurredAt': receivedAt.toIso8601String(),
        'billerName': 'Turtlemint',
        'isComplete': true,
        'confidence': 0.99,
      });
      final assessment = assessSmsFacts(
        [payment],
        body,
        receivedAt: receivedAt,
      );
      expect(assessment.autoResolvable, isFalse);
    },
  );

  test('a complete flag the model did not assert blocks auto-resolution', () {
    final assessment = assessSmsFacts([
      axisBillFact(isComplete: false),
    ], axisBillBody);
    expect(
      assessment.composite,
      greaterThanOrEqualTo(kSmsAutoResolveThreshold),
    );
    expect(assessment.autoResolvable, isFalse);
  });

  test(
    'payment completion phrase does not accept failed or scheduled wording',
    () {
      expect(
        smsHasCompletionEvidence(
          'Your payment of Rs 500 will be completed tomorrow.',
        ),
        isFalse,
      );
      expect(
        smsHasCompletionEvidence(
          'Your payment of Rs 500 failed and was not completed.',
        ),
        isFalse,
      );
    },
  );

  test('noise sorts to the review tier with no actionable fact', () {
    final assessment = assessSmsFacts(
      [
        fact('promotion', {
          'amountRole': 'proposed',
          'proposedAmountInr': 500.0,
          'isComplete': true,
        }),
      ],
      'Get 10% cashback on your next Amazon purchase. Offer valid till 30 Nov.',
    );
    expect(assessment.composite, 0);
    expect(assessment.primaryFact, isNull);
    expect(assessment.isComplete, isFalse);
    expect(assessment.autoResolvable, isFalse);
    expect(assessment.composite, lessThan(kSmsReviewThreshold));
  });

  test('informational facts never gate the decision', () {
    final assessment = assessSmsFacts([
      swiggyFact(),
      fact('balance_snapshot', {
        'availableBalanceInr': 45120.5,
        'asOfAt': '2026-10-24T00:00:00.000Z',
        'instrument': 'upi_bank',
        'accountLast4': '1797',
        'isComplete': false,
      }),
    ], swiggyBody);
    expect(assessment.facts, hasLength(2));
    expect(assessment.autoResolvable, isTrue);
  });

  test('promotional footers do not disqualify completion evidence', () {
    const body =
        'Rs 500.00 debited from A/c XX1234 on 24-Oct-26. '
        'You are eligible for a personal loan of Rs 5 Lakh.';
    expect(smsHasCompletionEvidence(body), isTrue);
    final assessment = assessSmsFacts([
      fact('posted_movement', {
        'amountRole': 'posted',
        'entryKind': 'spend',
        'amountInr': 500.0,
        'occurredAt': '2026-10-24T00:00:00.000Z',
        'instrument': 'upi_bank',
        'accountLast4': '1234',
        'merchant': 'SOME STORE',
        'category': 'other',
        'isComplete': true,
        'confidence': 0.9,
      }),
    ], body);
    expect(assessment.facts.single.evidence, 1.0);
    expect(assessment.autoResolvable, isTrue);
  });

  test('completion verbs cover disbursement and investment families', () {
    expect(
      smsHasCompletionEvidence('Loan of Rs 2,00,000 disbursed to A/c XX1234.'),
      isTrue,
    );
    expect(
      smsHasCompletionEvidence('Rs 5,000 invested in Axis Bluechip Fund.'),
      isTrue,
    );
    expect(
      smsHasCompletionEvidence('Payout of Rs 1,944.38 processed today.'),
      isTrue,
    );
    expect(
      smsHasCompletionEvidence('Rs 500 will be debited on 24-Oct-26.'),
      isFalse,
    );
  });
}
