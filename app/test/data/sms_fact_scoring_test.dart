import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/sms_fact_scoring.dart';

Map<String, dynamic> fact(String type, Map<String, dynamic> payload) => {
  'factType': type,
  'payload': payload,
};

const swiggyBody =
    'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on 24-10-26. '
    'UPI Ref 429812345678. Avail Bal: Rs.45,120.50';

const balajiReceiptBody =
    'Hello, your payment of Rs. 700.0 to Balaji Sports has been recorded. '
    'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r '
    '- myBillBook';

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
        'Rs 500.00 debited from A/c XX1234 at SOME STORE on 24-Oct-26. '
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

  test('SBI currencyless transfer keeps name, compact date and reference', () {
    const body =
        'Dear UPI User A/C X5121 debited by 50.00 on date 17Oct26 trf to '
        'Sunali Mundra Refno 665663775318 If not u? call-1800111109 for other '
        'services-18001234-SBI';
    final receivedAt = DateTime.utc(2026, 10, 17, 8);
    final transfer = fact('posted_movement', {
      'amountRole': 'posted',
      'amountInr': 50.0,
      'occurredAt': '2026-10-17T00:00:00.000Z',
      'entryKind': 'spend',
      'instrument': 'upi_bank',
      'accountLast4': '5121',
      'merchant': 'Transfer to Sunali Mundra',
      'transferParty': 'Sunali Mundra',
      'reference': '665663775318',
      'category': 'other',
      'isComplete': true,
      'confidence': 0.95,
    });
    expect(smsDateAppears(body, '2026-10-17T00:00:00.000Z'), isTrue);
    final assessment = assessSmsFacts([transfer], body, receivedAt: receivedAt);
    expect(assessment.facts.single.evidence, greaterThan(0.8));
    expect(assessment.autoResolvable, isTrue);
  });

  test('merchant receipt is completion evidence but not an independent ledger entry', () {
    const body =
        'Hello, your payment of Rs. 700.0 to Balaji Sports has been recorded. '
        'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r '
        '- myBillBook';
    final receivedAt = DateTime.utc(2026, 10, 27, 9);
    expect(smsIsReceiptOnlyMessage(body), isTrue);
    expect(smsHasReceiptCompletion(body), isTrue);
    final receipt = fact('posted_movement', {
      'amountRole': 'posted',
      'amountInr': 700.0,
      'occurredAt': receivedAt.toIso8601String(),
      'entryKind': 'spend',
      'instrument': 'upi_bank',
      'merchant': 'Balaji Sports',
      'category': 'other',
      'isComplete': true,
      'confidence': 0.95,
    });
    final assessment = assessSmsFacts(
      [receipt],
      body,
      receivedAt: receivedAt,
    );
    expect(assessment.facts.single.merchantEvidenced, isTrue);
    expect(assessment.facts.single.receiptOnly, isTrue);
    expect(assessment.facts.single.receiptCompletion, isTrue);
    expect(assessment.autoResolvable, isFalse);
  });

  test('absent or hash-like merchants cannot auto-accept a spend', () {
    const body =
        'A/c XX5121 debited by 50.00 on 17Oct26. Ref 665663775318. '
        'Avail Bal: 1,200.00.';
    Map<String, dynamic> spend(String merchant) => fact('posted_movement', {
      'amountRole': 'posted',
      'amountInr': 50.0,
      'occurredAt': '2026-10-17T00:00:00.000Z',
      'entryKind': 'spend',
      'instrument': 'upi_bank',
      'accountLast4': '5121',
      'merchant': merchant,
      'category': 'other',
      'isComplete': true,
      'confidence': 0.99,
    });
    for (final merchant in ['Phantom Bazaar', 'ljbffep4r', '665663775318']) {
      final assessment = assessSmsFacts([spend(merchant)], body);
      expect(
        assessment.facts.single.merchantEvidenced,
        isFalse,
        reason: merchant,
      );
      expect(assessment.autoResolvable, isFalse, reason: merchant);
    }
    expect(smsIsWeakMerchantName('X5121'), isTrue);
  });

  test('canonical, short, numeric and Unicode merchant names stay valid', () {
    for (final merchant in [
      'Refund',
      'Reward or cashback',
      'Transfer between own accounts',
      'Transfer to Sunali Mundra',
      '7-Eleven',
      '99acres',
      '3M',
      'Café Müller',
      'सुजय स्टोर्स',
    ]) {
      expect(
        smsIsWeakMerchantName(merchant),
        isFalse,
        reason: '$merchant should be a valid identity',
      );
    }
    expect(smsCleanMerchantName('Balaji Sports'), 'Balaji Sports');
    expect(smsCleanMerchantName('ljbffep4r'), isNull);
  });

  test('future, failed and downloaded notices never complete a spend', () {
    for (final body in [
      'Your payment of Rs 700 to Balaji Sports will be recorded tomorrow.',
      'Your payment of Rs 700 to Balaji Sports failed.',
      'Your payment receipt has been downloaded.',
      'Rs 700 will be debited on 17Oct26.',
    ]) {
      expect(smsHasCompletionEvidence(body), isFalse, reason: body);
    }
    expect(
      smsHasReceiptCompletion(
        'Your payment of Rs 700 to Balaji Sports has been recorded.',
      ),
      isTrue,
    );
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

  test('receipt with only a payment-method mention or card digits stays receipt-only', () {
    const body =
        'Hello, your payment of Rs. 700.0 to Balaji Sports has been recorded. '
        'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r '
        '- myBillBook Paid by credit card on 17Oct2026.';
    expect(smsIsReceiptOnlyMessage(body), isTrue);
    final receipt = fact('posted_movement', {
      'amountRole': 'posted',
      'amountInr': 700.0,
      'occurredAt': '2026-10-17T00:00:00.000Z',
      'entryKind': 'spend',
      'instrument': 'upi_bank',
      'merchant': 'Balaji Sports',
      'category': 'other',
      'isComplete': true,
      'confidence': 0.95,
    });
    final assessment = assessSmsFacts([receipt], body);
    expect(assessment.facts.single.receiptOnly, isTrue);
    expect(assessment.facts.single.autoResolveEligible, isFalse);
    expect(assessment.autoResolvable, isFalse);

    // A receipt linked to an actual instrument debit is independent evidence.
    expect(
      smsIsReceiptOnlyMessage(
        'A/c X5121 debited by 700.00 to Balaji Sports on 17-10-26. '
        'View the payment receipt here: https://mybillbook.in/cpp/?t=x',
      ),
      isFalse,
    );
    expect(
      smsIsReceiptOnlyMessage(
        'Your card ending 1234 was charged Rs. 700.00 at Balaji Sports on '
        '17-10-26. View the payment receipt here: https://mybillbook.in/cpp/?t=x',
      ),
      isFalse,
    );
  });

  test('canonical aliases require their own transaction context', () {
    Map<String, dynamic> movement(String merchant) => fact('posted_movement', {
      'amountRole': 'posted',
      'amountInr': 420.0,
      'occurredAt': '2026-10-24T00:00:00.000Z',
      'entryKind': 'spend',
      'instrument': 'upi_bank',
      'merchant': merchant,
      'category': 'other',
      'isComplete': true,
      'confidence': 0.95,
    });
    bool grounded(String merchant, String body) => assessSmsFacts(
      [movement(merchant)],
      body,
    ).facts.single.merchantEvidenced;

    const swiggyDebit =
        'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on 24-10-26. '
        'UPI Ref 429812345678. Avail Bal: Rs.45,120.50';
    const cardPurchase =
        'Rs 420.00 debited from your Credit Card XX1234 at Swiggy on 24-10-26.';
    const cashback = 'Rs 50 cashback credited on 24-10-26.';
    const amazonPurchase = 'Rs 500 debited for Amazon purchase on 24-10-26.';
    for (final entry in [
      ['Bank transfer', swiggyDebit],
      ['Credit card bill payment', cardPurchase],
      ['Card statement adjustment', cardPurchase],
      ['Amazon Pay Later', amazonPurchase],
      ['Refund', cashback],
      ['Reversal', cashback],
    ]) {
      expect(
        grounded(entry[0], entry[1]),
        isFalse,
        reason: '${entry[0]} on ${entry[1]}',
      );
    }

    for (final entry in [
      [
        'Bank transfer',
        'Rs 5,000 credited from HDFC Bank A/c XX1234 via NEFT transfer on '
            '24-10-26.',
      ],
      [
        'Credit card bill payment',
        'Payment of Rs 5,000 towards your HDFC Credit Card bill on 24-10-26.',
      ],
      [
        'Card statement adjustment',
        'Rs 500 credited to your HDFC Credit Card on 24-10-26.',
      ],
      ['Amazon Pay Later', 'Availing Pay Later credit of Rs 500 on 24-10-26.'],
      ['Refund', 'Refund of Rs 200 credited on 24-10-26.'],
      ['Reversal', 'Reversal of Rs 200 credited on 24-10-26.'],
      ['Reward or cashback', 'Rs 50 cashback credited on 24-10-26.'],
      ['Wallet load', 'Wallet loaded with Rs 500 on 24-10-26.'],
    ]) {
      expect(
        grounded(entry[0], entry[1]),
        isTrue,
        reason: '${entry[0]} on ${entry[1]}',
      );
    }
  });

  test('processing fees complete while pending-processing wording stays tentative', () {
    expect(
      smsHasCompletionEvidence(
        'Processing fee of Rs 199 debited from A/c XX1234 on 24-10-26.',
      ),
      isTrue,
    );
    for (final body in [
      'Your payment of Rs 200 to Swiggy is currently processing. '
          'Amount debited from A/c XX1234.',
      'Your payment of Rs 200 to Swiggy is being processed after the debit.',
      'Your payment is still in progress.',
      'Your payment of Rs 200 to Swiggy is pending.',
      'Rs 500 shall be debited on 24-Oct-26.',
      'Rs 500 would be debited on 24-Oct-26.',
    ]) {
      expect(smsHasCompletionEvidence(body), isFalse, reason: body);
    }
  });

  test('receipt-only messages gate every actionable fact, not only ledger facts', () {
    final bill = fact('bill_obligation', {
      'amountRole': 'due_total',
      'amountDueInr': 700.0,
      'billerName': 'Balaji Sports',
      'isComplete': true,
      'confidence': 0.99,
    });
    final scored = assessSmsFacts([bill], balajiReceiptBody);
    expect(scored.facts.single.receiptOnly, isTrue);
    expect(scored.facts.single.autoResolveEligible, isFalse);
    expect(scored.autoResolvable, isFalse);
  });
}
