'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  verifyModelFacts,
  moneyInMessage,
  amountInCompletedTransaction,
  amountInPostedTransaction,
  amountInBillObligation,
  normalizeModelFacts,
  MOVEMENT_VERBS,
  coreTransactionClause,
  hasCompletionEvidence,
} = require('../src/ai_fact_evidence');
const { validateFactSet } = require('../src/sms_facts');
const { assessFacts } = require('../src/ai_fact_scoring');

function verify(facts, payload) {
  return verifyModelFacts(facts, {
    ...payload,
    occurredAt: payload.occurredAt || facts.find((fact) => fact?.payload?.occurredAt)?.payload.occurredAt,
  });
}

test('bill payment amount must be tied to the completed payment, not nearby balance', () => {
  const body = 'Your payment of Rs 3,160.80 for REF123 was completed successfully. Available balance is Rs 1.20.';
  assert.equal(amountInCompletedTransaction(body, 3160.8), true);
  assert.equal(amountInCompletedTransaction(body, 1.2), false);
  const good = verify([{
    factType: 'bill_payment',
    payload: { amountInr: 3160.8, occurredAt: '2026-10-20T10:00:00Z' },
  }], { body });
  assert.equal(good.valid, true);
  const wrongBalance = verify([{
    factType: 'bill_payment',
    payload: { amountInr: 1.2, occurredAt: '2026-10-20T10:00:00Z' },
  }], { body });
  assert.equal(wrongBalance.valid, false);
  assert.match(wrongBalance.errors.join(' '), /not tied to completed payment/);
});

test('bill amount role must match the exact total or minimum due clause', () => {
  const body = 'Axis card statement. Total due: Rs 14,850.00. Min due: Rs 750.00. Due date: 12-Nov-2026.';
  assert.equal(amountInBillObligation(body, 'due_total', 14850), true);
  assert.equal(amountInBillObligation(body, 'due_total', 750), false);
  assert.equal(amountInBillObligation(body, 'due_minimum', 750), true);
  assert.equal(amountInBillObligation(body, 'due_minimum', 14850), false);
  const invalidRole = verify([{
    factType: 'bill_obligation',
    payload: {
      amountRole: 'due_total', amountDueInr: 750,
      dueDate: '2026-11-11T18:30:00.000Z', billerName: 'Axis card',
    },
  }], { body });
  assert.equal(invalidRole.valid, false);
  assert.match(invalidRole.errors.join(' '), /not tied to the due_total bill clause/);
});

test('posted movement amount must be tied to the debit clause, not balance_after', () => {
  const body = 'Rs 1,249.00 sent to SWIGGY UPI, available balance: Rs 18,422.65';
  assert.equal(amountInPostedTransaction(body, 1249), true);
  assert.equal(amountInPostedTransaction(body, 18422.65), false);
  assert.equal(amountInPostedTransaction('Rs.420.50 debited at SWIGGY UPI', 420.5), true);
  const fact = (amountInr) => ({
    factType: 'posted_movement',
    payload: { amountRole: 'posted', amountInr, entryKind: 'spend', occurredAt: '2026-09-05T00:00:00+05:30' },
  });
  assert.equal(verify([fact(1249)], { body }).valid, true);
  const wrongBalance = verify([fact(18422.65)], { body });
  assert.equal(wrongBalance.valid, false);
  assert.match(wrongBalance.errors.join(' '), /not tied to completed movement/);
});

test('money evidence accepts printed amounts and rejects model-invented amounts', () => {
  const payload = { body: 'HDFC Bank A/c XX1234 available balance Rs 4,250.50' };
  assert.deepEqual(moneyInMessage(payload.body), [4250.5]);
  const valid = verify([{
    factType: 'balance_snapshot',
    payload: { availableBalanceInr: 4250.5, asOfAt: '2026-10-20T10:00:00Z', instrument: 'upi_bank', accountLast4: '1234' },
  }], payload);
  assert.equal(valid.valid, true);
  const invented = verify([{
    factType: 'balance_snapshot',
    payload: { availableBalanceInr: 4251, asOfAt: '2026-10-20T10:00:00Z', instrument: 'upi_bank', accountLast4: '1234' },
  }], payload);
  assert.equal(invented.valid, false);
  assert.match(invented.errors.join(' '), /amount absent/);
});

test('balance cannot be projected as a bank account without bank and suffix evidence', () => {
  const fact = {
    factType: 'balance_snapshot',
    payload: { availableBalanceInr: 500, asOfAt: '2026-10-20T10:00:00Z', instrument: 'upi_bank', accountLast4: '1234' },
  };
  const noBank = verify([fact], { body: 'Available balance Rs 500' });
  assert.equal(noBank.valid, false);
  assert.match(noBank.errors.join(' '), /bank-account evidence/);
  const noSuffix = verify([{
    ...fact,
    payload: { availableBalanceInr: 500, asOfAt: '2026-10-20T10:00:00Z', instrument: 'upi_bank' },
  }], { body: 'Bank available balance Rs 500' });
  assert.equal(noSuffix.valid, false);
  assert.match(noSuffix.errors.join(' '), /requires an evidenced account suffix/);
});

test('posted movements require completed-event language and reject declined or future events', () => {
  const fact = {
    factType: 'posted_movement',
    payload: { amountRole: 'posted', amountInr: 250, entryKind: 'spend', occurredAt: '2026-10-20T10:00:00Z' },
  };
  assert.equal(verify([fact], { body: 'Rs 250 debited from your account' }).valid, true);
  assert.equal(verify([fact], { body: 'payout for Rs. 250 is processed with reference ID: 12345' }).valid, true);
  assert.equal(verify([fact], { body: 'Your payment of Rs 250 for REF123 was completed successfully.' }).valid, true);
  assert.equal(verify([fact], { body: 'Rs 250 debit declined' }).valid, false);
  assert.equal(verify([fact], { body: 'Rs 250 will be debited' }).valid, false);
});

test('posted movement dates must match the SMS or phone receipt timestamp', () => {
  const fact = {
    factType: 'posted_movement',
    payload: { amountRole: 'posted', amountInr: 250, entryKind: 'spend', occurredAt: '2026-04-15T00:00:00Z' },
  };
  const body = 'Rs 250 debited from your account';
  const wrongDate = verifyModelFacts([fact], {
    body,
    occurredAt: '2026-10-26T10:00:00Z',
  });
  assert.equal(wrongDate.valid, false);
  assert.match(wrongDate.errors.join(' '), /timestamp is not supported/);
  const receiptTime = verifyModelFacts([{
    ...fact,
    payload: { ...fact.payload, occurredAt: '2026-10-26T10:02:00Z' },
  }], { body, occurredAt: '2026-10-26T10:00:00Z' });
  assert.equal(receiptTime.valid, true);
  const printedDateMismatch = verifyModelFacts([fact], {
    body: 'Rs 250 debited on 26-Oct-2026',
    occurredAt: '2026-10-26T10:00:00Z',
  });
  assert.equal(printedDateMismatch.valid, false);
});

test('normalizer fills only unambiguous bill fields and reaches auto-resolve evidence', () => {
  const occurredAt = '2026-10-26T10:00:00.000Z';
  const dueBody = 'Your electricity bill of Rs 1,240 is due on 05 Nov 2026.';
  const dueFacts = normalizeModelFacts([{
    factType: 'bill_obligation',
    payload: { amountRole: 'due_total', amountDueInr: 1240 },
  }], { body: dueBody, occurredAt });
  assert.equal(dueFacts[0].payload.billerName, 'Electricity');
  assert.equal(dueFacts[0].payload.category, 'bills');
  assert.equal(dueFacts[0].payload.isComplete, true);
  assert.equal(validateFactSet(dueFacts).valid, true);
  assert.equal(verify(dueFacts, { body: dueBody, occurredAt }).valid, true);
  assert.equal(assessFacts(dueFacts, dueBody, occurredAt).reviewRequired, false);

  const paymentBody = 'Your payment of Rs 1,240 to BESCOM was completed successfully.';
  const paymentFacts = normalizeModelFacts([{
    factType: 'bill_payment',
    payload: { billerName: 'BESCOM' },
  }], { body: paymentBody, occurredAt });
  assert.equal(paymentFacts[0].payload.amountInr, 1240);
  assert.equal(paymentFacts[0].payload.amountRole, 'posted');
  assert.equal(paymentFacts[0].payload.entryKind, 'transfer');
  assert.equal(paymentFacts[0].payload.occurredAt, occurredAt);
  assert.equal(paymentFacts[0].payload.isComplete, true);
  assert.equal(validateFactSet(paymentFacts).valid, true);
  assert.equal(verify(paymentFacts, { body: paymentBody, occurredAt }).valid, true);
  assert.equal(assessFacts(paymentFacts, paymentBody, occurredAt).reviewRequired, false);

  const movementBody = 'Rs 420 debited at Swiggy successfully.';
  const movementFacts = normalizeModelFacts([{
    factType: 'posted_movement',
    payload: {
      amountRole: 'posted', entryKind: 'spend', occurredAt: '2026-04-15T00:00:00.000Z',
      instrument: 'upi_bank', merchant: 'Swiggy', category: 'dining', isComplete: true,
    },
  }], { body: movementBody, occurredAt });
  assert.equal(movementFacts[0].payload.amountInr, 420);
  assert.equal(movementFacts[0].payload.occurredAt, occurredAt);
  assert.equal(movementFacts[0].payload.confidence, 0.9);
  assert.equal(validateFactSet(movementFacts).valid, true);
  assert.equal(verify(movementFacts, { body: movementBody, occurredAt }).valid, true);
  assert.equal(assessFacts(movementFacts, movementBody, occurredAt).reviewRequired, false);

  const contradictory = normalizeModelFacts([{
    factType: 'bill_payment',
    payload: { amountRole: 'posted', amountInr: 1241, occurredAt, billerName: 'BESCOM' },
  }], { body: paymentBody, occurredAt });
  assert.equal(contradictory[0].payload.amountInr, 1241, 'never overwrite a model value that conflicts with the SMS');
  assert.equal(verify(contradictory, { body: paymentBody, occurredAt }).valid, false);
});

test('expanded completion verbs accept disbursements, SIPs and deposits', () => {
  for (const verb of ['disbursed', 'invested', 'deposited', 'payout', 'settled']) {
    assert.match(verb, MOVEMENT_VERBS, `${verb} must be a movement verb`);
  }
  const fact = (amount) => ({
    factType: 'posted_movement',
    payload: { amountRole: 'posted', amountInr: amount, entryKind: 'spend', occurredAt: '2026-10-20T10:00:00Z' },
  });
  assert.equal(verify([fact(20000)], { body: 'Rs 20000 disbursed to your account' }).valid, true);
  assert.equal(verify([fact(500)], { body: 'SIP of Rs 500 invested in XYZ fund' }).valid, true);
  assert.equal(verify([fact(100)], { body: 'Rs 100 deposited' }).valid, true);
  assert.equal(
    verify([fact(1944.38)], {
      body: 'payout of Rs 1,944.38 has been processed towards your Bank A/c XX1797',
    }).valid,
    true,
  );
  assert.equal(
    verify([fact(250)], { body: 'Rs 250 settled to your account' }).valid,
    true,
  );
});

test('promotional and maintenance footers do not invalidate genuine movements', () => {
  const fact = (amount) => ({
    factType: 'posted_movement',
    payload: { amountRole: 'posted', amountInr: amount, entryKind: 'spend', occurredAt: '2026-10-20T10:00:00Z' },
  });
  const promotion = verify([{
    ...fact(500), payload: { ...fact(500).payload, occurredAt: '2026-10-24T10:00:00Z' },
  }], {
    body: 'Rs 500.00 debited from A/c XX1234 on 24-Oct. You are eligible for a personal loan of Rs 5 Lakh',
  });
  assert.equal(promotion.valid, true, promotion.errors.join('; '));
  const maintenance = verify([fact(250)], {
    body: 'Rs 250 debited from your account. Scheduled maintenance on Sunday',
  });
  assert.equal(maintenance.valid, true, maintenance.errors.join('; '));

  assert.equal(
    coreTransactionClause('Rs 500 debited. You are eligible for a loan'),
    'Rs 500 debited.',
  );
  assert.equal(hasCompletionEvidence('Rs 500 debited. Offer valid till Sunday'), true);
  assert.equal(hasCompletionEvidence('Rs 500 debited. Terms and conditions apply'), true);
});

test('genuine failures, tentative language and scheduled-only messages still fail', () => {
  const fact = {
    factType: 'posted_movement',
    payload: { amountRole: 'posted', amountInr: 250, entryKind: 'spend', occurredAt: '2026-10-20T10:00:00Z' },
  };
  for (const body of [
    'Rs 250 debit declined',
    'Rs 250 will be debited',
    'Rs 250 transaction failed',
    'Rs 250 payment unsuccessful',
    'Rs 250 reversed by bank',
    'Rs 250 cancelled',
    'Rs 250 scheduled for 24-10-26',
    'Rs 250 is scheduled',
    'Your payment of Rs 250 will be completed tomorrow.',
  ]) {
    assert.equal(verify([fact], { body }).valid, false, body);
    assert.equal(hasCompletionEvidence(body), false, body);
  }
});
