'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  AUTO_RESOLVE,
  NEEDS_REVIEW,
  WEIGHTS,
  computeFactScore,
  assessFacts,
  dateAppears,
} = require('../src/ai_fact_scoring');

const SWIGGY_BODY =
  'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on 24-10-26. UPI Ref 429812345678. Avail Bal: Rs.45,120.50';

const swiggyFact = {
  factType: 'posted_movement',
  payload: {
    amountRole: 'posted',
    entryKind: 'spend',
    amountInr: 420.0,
    occurredAt: '2026-10-24T00:00:00.000Z',
    instrument: 'upi_bank',
    accountLast4: '1797',
    issuerName: 'HDFC Bank',
    merchant: 'Swiggy',
    category: 'dining',
    isComplete: true,
    confidence: 0.98,
  },
};

const AXIS_BODY =
  'Your Axis Bank Credit Card XX8891 statement generated. Total Due: Rs 14,850.00, Min Due: Rs 750.00, Due Date: 12-Nov-2026.';

const axisBillFact = {
  factType: 'bill_obligation',
  payload: {
    amountRole: 'due_total',
    amountDueInr: 14850.0,
    dueDate: '2026-11-12T00:00:00.000Z',
    instrument: 'credit_card',
    last4: '8891',
    issuerName: 'Axis Bank',
    billerName: 'Axis Bank Credit Card',
    targetKind: 'card_bill',
    isComplete: true,
    confidence: 0.99,
  },
};

const PARTIAL_BODY =
  'A/c XX1797 debited for INR 750.00 on 24-10-26. Info: POS-TXN. Avail Bal: 21,400.00.';

const partialFact = {
  factType: 'posted_movement',
  payload: {
    amountRole: 'posted',
    entryKind: 'spend',
    amountInr: 750.0,
    occurredAt: '2026-10-24T00:00:00.000Z',
    instrument: 'upi_bank',
    accountLast4: '1797',
    merchant: null,
    category: 'other',
    isComplete: false,
    confidence: 0.65,
  },
};

const BILL_BODY =
  'HDFCBK: Card XX1234 statement. Total due Rs 3000, min due Rs 600, due 05/11/26.';

const BILL_FACTS = [
  {
    factType: 'bill_obligation',
    payload: {
      amountRole: 'due_total',
      amountDueInr: 3000,
      dueDate: '2026-11-04T18:30:00.000Z',
      billerName: 'HDFC credit card',
      accountLast4: '1234',
      instrument: 'credit_card',
    },
  },
];

test('composite score follows the weighted formula', () => {
  assert.equal(AUTO_RESOLVE, 0.85);
  assert.equal(NEEDS_REVIEW, 0.45);
  assert.deepEqual(WEIGHTS, {
    model: 0.25,
    evidence: 0.35,
    completeness: 0.25,
    disambiguation: 0.15,
  });
  const result = computeFactScore(swiggyFact, SWIGGY_BODY);
  const expected =
    WEIGHTS.model * result.model +
    WEIGHTS.evidence * result.evidence +
    WEIGHTS.completeness * result.completeness +
    WEIGHTS.disambiguation * result.disambiguation;
  assert.ok(Math.abs(result.score - expected) < 1e-4);
  assert.equal(result.model, 0.98);
  assert.equal(result.evidence, 1);
  assert.equal(result.completeness, 1);
  assert.equal(result.disambiguation, 1);
});

test('model confidence falls back to 0.8 when absent or out of range', () => {
  const withoutConfidence = {
    ...swiggyFact,
    payload: { ...swiggyFact.payload, confidence: undefined },
  };
  assert.equal(computeFactScore(withoutConfidence, SWIGGY_BODY).model, 0.8);
  const outOfRange = {
    ...swiggyFact,
    payload: { ...swiggyFact.payload, confidence: 1.7 },
  };
  assert.equal(computeFactScore(outOfRange, SWIGGY_BODY).model, 0.8);
});

test('a complete high-confidence spend auto-resolves', () => {
  const assessment = assessFacts([swiggyFact], SWIGGY_BODY);
  assert.equal(assessment.actionableCount, 1);
  assert.ok(assessment.composite >= AUTO_RESOLVE);
  assert.equal(assessment.perFact[0].isComplete, true);
  assert.equal(assessment.reviewRequired, false);
});

test('a complete high-confidence bill obligation auto-resolves', () => {
  const assessment = assessFacts([axisBillFact], AXIS_BODY);
  assert.ok(assessment.composite >= AUTO_RESOLVE);
  assert.equal(assessment.reviewRequired, false);
});

test('completed bill payment without printed date can auto-resolve using receipt time', () => {
  const body = 'Your payment of Rs 3,160.80 for REF123 was completed successfully. Available balance is Rs 1.20.';
  const receivedAt = '2026-04-15T06:59:00.000Z';
  const fact = {
    factType: 'bill_payment',
    payload: {
      amountRole: 'posted', amountInr: 3160.8, occurredAt: receivedAt,
      billerName: 'Turtlemint', entryKind: 'transfer',
      isComplete: true, confidence: 0.8,
    },
  };
  const assessment = assessFacts([fact], body, receivedAt);
  assert.equal(assessment.reviewRequired, false);
  assert.ok(assessment.composite >= AUTO_RESOLVE);
  assert.equal(assessment.perFact[0].evidence, 0.75);
});

test('bill payment cannot auto-resolve when amount is only a balance or biller is missing', () => {
  const body = 'Your payment of Rs 3,160.80 for REF123 was completed successfully. Available balance is Rs 1.20.';
  const receivedAt = '2026-04-15T06:59:00.000Z';
  const fact = {
    factType: 'bill_payment',
    payload: {
      amountRole: 'posted', amountInr: 1.2, occurredAt: receivedAt,
      isComplete: true, confidence: 0.99,
    },
  };
  const assessment = assessFacts([fact], body, receivedAt);
  assert.equal(assessment.reviewRequired, true);
  assert.equal(assessment.perFact[0].evidence, 0.35);
});

test('partial or incomplete extractions stay in review even with text evidence', () => {
  const result = computeFactScore(partialFact, PARTIAL_BODY);
  assert.ok(result.evidence >= 0.9, 'the amount, suffix, date and verb are all present');
  assert.ok(result.score < AUTO_RESOLVE);
  assert.equal(result.isComplete, false);
  const assessment = assessFacts([partialFact], PARTIAL_BODY);
  assert.equal(assessment.reviewRequired, true);
});

test('a high score without isComplete=true still requires review', () => {
  const completeButUnmarked = {
    ...swiggyFact,
    payload: { ...swiggyFact.payload, isComplete: undefined },
  };
  const assessment = assessFacts([completeButUnmarked], SWIGGY_BODY);
  assert.ok(assessment.composite >= AUTO_RESOLVE);
  assert.equal(assessment.reviewRequired, true);
});

test('noise and empty results require review and ignore non-actionable facts', () => {
  const empty = assessFacts([], 'Your OTP is 123456 do not share it');
  assert.deepEqual(empty.perFact, []);
  assert.equal(empty.composite, 0);
  assert.equal(empty.actionableCount, 0);
  assert.equal(empty.reviewRequired, true);

  const noise = assessFacts([
    {
      factType: 'balance_snapshot',
      payload: {
        amountRole: 'outstanding',
        availableBalanceInr: 45120.5,
        asOfAt: '2026-10-24T00:00:00.000Z',
        instrument: 'upi_bank',
        accountLast4: '1797',
        isComplete: true,
        confidence: 0.99,
      },
    },
    {
      factType: 'promotion',
      payload: { amountRole: 'posted' },
    },
  ], SWIGGY_BODY);
  assert.equal(noise.actionableCount, 0);
  assert.equal(noise.composite, 0);
  assert.equal(noise.reviewRequired, true);
  assert.equal(noise.perFact.length, 2);
});

test('one weak actionable fact forces review even when another is perfect', () => {
  const assessment = assessFacts([
    swiggyFact,
    {
      ...partialFact,
      payload: { ...partialFact.payload, isComplete: true },
    },
  ], SWIGGY_BODY);
  // The partial fact's amount is absent from this body, so its score is low.
  assert.equal(assessment.actionableCount, 2);
  assert.ok(assessment.composite >= AUTO_RESOLVE, 'composite reports the best actionable fact');
  assert.equal(assessment.reviewRequired, true);
});

test('anchor dates match the formats Indian SMS actually print', () => {
  const anchor = '2026-10-24T00:00:00.000Z';
  for (const body of [
    'on 24-10-26',
    'on 24/10/26',
    'on 24 Oct 2026',
    'on 24-Oct-26',
    'on 2026-10-24',
  ]) {
    assert.equal(dateAppears(body, anchor), true, body);
  }
  // IST midnight is stored as 18:30Z on the previous UTC day.
  assert.equal(dateAppears('due 05/11/26', '2026-11-04T18:30:00.000Z'), true);
  assert.equal(dateAppears('no date here', anchor), false);
});

test('the existing fixture BILL_FACTS stays in review without isComplete', () => {
  const assessment = assessFacts(BILL_FACTS, BILL_BODY);
  assert.equal(assessment.actionableCount, 1);
  assert.equal(assessment.perFact[0].isComplete, false);
  assert.ok(assessment.perFact[0].evidence >= 1, 'amount, suffix, date and due evidence all match');
  assert.equal(assessment.reviewRequired, true);
});
