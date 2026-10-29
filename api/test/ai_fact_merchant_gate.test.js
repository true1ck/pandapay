'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  verifyModelFacts,
  hasCompletionEvidence,
  isReceiptOnlyMessage,
  hasReceiptCompletion,
} = require('../src/ai_fact_evidence');
const { computeFactScore, assessFacts } = require('../src/ai_fact_scoring');
const { cleanMerchantName, isWeakMerchantName } = require('../src/merchant_identity');

const BALAJI =
  'Hello, your payment of Rs. 700.0 to Balaji Sports has been recorded. '
  + 'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r - myBillBook';
const SBI =
  'Dear UPI User A/C X5121 debited by 50.00 on date 17Oct26 trf to Sunali Mundra '
  + 'Refno 665663775318 If not u? call-1800111109 for other services-18001234-SBI';

function spend(overrides = {}) {
  return {
    factType: 'posted_movement',
    payload: {
      amountRole: 'posted',
      amountInr: 50,
      occurredAt: '2026-10-17T00:00:00.000Z',
      entryKind: 'spend',
      instrument: 'upi_bank',
      accountLast4: '5121',
      merchant: 'Phantom Bazaar',
      category: 'other',
      isComplete: true,
      confidence: 0.99,
      ...overrides,
    },
  };
}

test('a synthetic merchant absent from the SMS cannot auto-accept despite a high composite score', () => {
  const body =
    'A/c XX5121 debited by 50.00 on 17Oct26. Ref 665663775318. '
    + 'Avail Bal: 1,200.00.';
  const fact = spend();
  const verification = verifyModelFacts([fact], { body });
  assert.equal(verification.valid, false);
  assert.match(verification.errors.join(' '), /merchant is not evidenced/);

  const scored = computeFactScore(fact, body);
  assert.equal(scored.score, 0.9225);
  assert.equal(scored.merchantEvidenced, false);
  assert.equal(scored.autoResolveEligible, false);
  const assessment = assessFacts([fact], body);
  assert.equal(assessment.composite, 0.9225);
  assert.equal(assessment.reviewRequired, true);
});

test('hash-like merchant IDs are rejected even when the raw token appears in the SMS', () => {
  const body = 'Rs 200 debited at ljbffep4r on 24-10-26.';
  const fact = spend({
    amountInr: 200,
    occurredAt: '2026-10-24T00:00:00.000Z',
    accountLast4: null,
    merchant: 'ljbffep4r',
  });
  const verification = verifyModelFacts([fact], { body });
  assert.equal(verification.valid, false);
  assert.match(verification.errors.join(' '), /invalid merchant identity/);
  const scored = computeFactScore(fact, body);
  assert.equal(scored.disambiguation, 0);
  assert.equal(scored.merchantEvidenced, false);
  assert.equal(assessFacts([fact], body).reviewRequired, true);
});

test('supported canonical, short and Unicode merchants remain valid and grounded', () => {
  const cases = [
    ['Rs 50 cashback credited on 24-10-26.', 'Reward or cashback', 'income'],
    ['Rs 200 paid to Vi on 24-10-26.', 'Vi', 'spend'],
    ['Rs 200 paid to Café Müller on 24-10-26.', 'Café Müller', 'spend'],
  ];
  for (const [body, merchant, entryKind] of cases) {
    assert.equal(isWeakMerchantName(merchant), false, merchant);
    const fact = spend({
      amountInr: body.includes('50') ? 50 : 200,
      occurredAt: '2026-10-24T00:00:00.000Z',
      accountLast4: null,
      merchant,
      entryKind,
    });
    const verification = verifyModelFacts([fact], { body });
    assert.equal(verification.valid, true, `${merchant}: ${verification.errors.join('; ')}`);
    const scored = computeFactScore(fact, body);
    assert.equal(scored.merchantEvidenced, true, merchant);
  }
  assert.equal(cleanMerchantName('Transfer to Sunali Mundra'), 'Transfer to Sunali Mundra');
  assert.equal(cleanMerchantName('ljbffep4r'), null);
});

test('SBI transfer evidence accepts currencyless amount and compact date', () => {
  const fact = spend({
    amountInr: 50,
    merchant: 'Transfer to Sunali Mundra',
    transferParty: 'Sunali Mundra',
  });
  const verification = verifyModelFacts([fact], { body: SBI });
  assert.equal(verification.valid, true, verification.errors.join('; '));
  const scored = computeFactScore(fact, SBI);
  assert.equal(scored.merchantEvidenced, true);
  assert.equal(scored.completionEvidence, true);
  assert.equal(assessFacts([fact], SBI).reviewRequired, false);
});

test('merchant receipt proves completion but cannot auto-post an independent transaction', () => {
  const receivedAt = '2026-10-27T09:00:00.000Z';
  const fact = spend({
    amountInr: 700,
    occurredAt: receivedAt,
    accountLast4: null,
    merchant: 'Balaji Sports',
  });
  assert.equal(isReceiptOnlyMessage(BALAJI), true);
  assert.equal(hasReceiptCompletion(BALAJI), true);
  assert.equal(hasCompletionEvidence(BALAJI), true);

  const verification = verifyModelFacts([fact], { body: BALAJI, occurredAt: receivedAt });
  assert.equal(verification.valid, false);
  assert.match(verification.errors.join(' '), /receipt-only payment/);

  const scored = computeFactScore(fact, BALAJI, receivedAt);
  assert.equal(scored.merchantEvidenced, true);
  assert.equal(scored.receiptOnly, true);
  assert.equal(scored.receiptCompletion, true);
  assert.equal(scored.autoResolveEligible, false);
  assert.equal(assessFacts([fact], BALAJI, receivedAt).reviewRequired, true);
});

test('failed, future and downloaded notices never complete a posted spend', () => {
  for (const body of [
    'Rs 500 will be debited on 24-10-26.',
    'Rs 500 shall be debited on 24-10-26.',
    'Rs 500 would be debited on 24-10-26.',
    'Rs 500 debited declined on 24-10-26.',
    'Your statement has been downloaded on 24-10-26.',
  ]) {
    const fact = spend({
      amountInr: 500,
      occurredAt: '2026-10-24T00:00:00.000Z',
      accountLast4: null,
      merchant: 'Swiggy',
    });
    const scored = computeFactScore(fact, body);
    assert.equal(scored.completionEvidence, false, body);
    assert.equal(scored.autoResolveEligible, false, body);
    assert.equal(assessFacts([fact], body).reviewRequired, true, body);
  }
});

test('receipt with only a payment-method mention or card digits stays receipt-only', () => {
  const body =
    'Hello, your payment of Rs. 700.0 to Balaji Sports has been recorded. '
    + 'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r - myBillBook '
    + 'Paid by credit card on 17Oct2026.';
  assert.equal(isReceiptOnlyMessage(body), true);
  const fact = spend({
    amountInr: 700,
    occurredAt: '2026-10-17T00:00:00.000Z',
    accountLast4: null,
    merchant: 'Balaji Sports',
  });
  const verification = verifyModelFacts([fact], { body, occurredAt: '2026-10-17T00:00:00.000Z' });
  assert.match(verification.errors.join(' '), /receipt-only payment/);
  const scored = computeFactScore(fact, body);
  assert.equal(scored.receiptOnly, true);
  assert.equal(scored.autoResolveEligible, false);

  // A receipt linked to an actual instrument debit is independent evidence.
  for (const settled of [
    'A/c X5121 debited by 700.00 to Balaji Sports on 17-10-26. '
      + 'View the payment receipt here: https://mybillbook.in/cpp/?t=x',
    'Your card ending 1234 was charged Rs. 700.00 at Balaji Sports on 17-10-26. '
      + 'View the payment receipt here: https://mybillbook.in/cpp/?t=x',
  ]) {
    assert.equal(isReceiptOnlyMessage(settled), false, settled);
  }
});

test('invented canonical aliases cannot ground a mismatched transaction', () => {
  const swiggy = 'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on 24-10-26.';
  const swiggyFact = spend({
    amountInr: 420,
    occurredAt: '2026-10-24T00:00:00.000Z',
    accountLast4: '1797',
    merchant: 'Bank transfer',
  });
  const bankScored = computeFactScore(swiggyFact, swiggy);
  assert.equal(bankScored.merchantEvidenced, false);
  assert.equal(bankScored.autoResolveEligible, false);
  assert.equal(verifyModelFacts([swiggyFact], { body: swiggy }).valid, false);

  const cashback = 'Rs 50 cashback credited on 24-10-26.';
  const refundFact = spend({
    amountInr: 50,
    occurredAt: '2026-10-24T00:00:00.000Z',
    accountLast4: null,
    merchant: 'Refund',
    entryKind: 'income',
  });
  assert.equal(computeFactScore(refundFact, cashback).merchantEvidenced, false);
});

test('processing fees complete while pending-processing wording stays tentative', () => {
  assert.equal(
    hasCompletionEvidence('Processing fee of Rs 199 debited from A/c XX1234 on 24-10-26.'),
    true,
  );
  for (const body of [
    'Your payment of Rs 200 to Swiggy is currently processing. Amount debited from A/c XX1234.',
    'Your payment of Rs 200 to Swiggy is being processed after the debit.',
    'Your payment is still in progress.',
    'Your payment of Rs 200 to Swiggy is pending.',
  ]) {
    assert.equal(hasCompletionEvidence(body), false, body);
  }
});

test('receipt-only messages gate every actionable fact, not only ledger facts', () => {
  const bill = {
    factType: 'bill_obligation',
    payload: {
      amountRole: 'due_total',
      amountDueInr: 700,
      billerName: 'Balaji Sports',
      isComplete: true,
      confidence: 0.99,
    },
  };
  const scored = computeFactScore(bill, BALAJI);
  assert.equal(scored.receiptOnly, true);
  assert.equal(scored.autoResolveEligible, false);
  assert.equal(assessFacts([bill], BALAJI).reviewRequired, true);
});
