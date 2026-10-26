'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  verifyModelFacts,
  moneyInMessage,
  amountInCompletedTransaction,
  MOVEMENT_VERBS,
  coreTransactionClause,
  hasCompletionEvidence,
} = require('../src/ai_fact_evidence');

test('bill payment amount must be tied to the completed payment, not nearby balance', () => {
  const body = 'Your payment of Rs 3,160.80 for REF123 was completed successfully. Available balance is Rs 1.20.';
  assert.equal(amountInCompletedTransaction(body, 3160.8), true);
  assert.equal(amountInCompletedTransaction(body, 1.2), false);
  const good = verifyModelFacts([{
    factType: 'bill_payment',
    payload: { amountInr: 3160.8 },
  }], { body });
  assert.equal(good.valid, true);
  const wrongBalance = verifyModelFacts([{
    factType: 'bill_payment',
    payload: { amountInr: 1.2 },
  }], { body });
  assert.equal(wrongBalance.valid, false);
  assert.match(wrongBalance.errors.join(' '), /not tied to completed payment/);
});

test('money evidence accepts printed amounts and rejects model-invented amounts', () => {
  const payload = { body: 'HDFC Bank A/c XX1234 available balance Rs 4,250.50' };
  assert.deepEqual(moneyInMessage(payload.body), [4250.5]);
  const valid = verifyModelFacts([{
    factType: 'balance_snapshot',
    payload: { availableBalanceInr: 4250.5, asOfAt: '2026-10-20T10:00:00Z', instrument: 'upi_bank', accountLast4: '1234' },
  }], payload);
  assert.equal(valid.valid, true);
  const invented = verifyModelFacts([{
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
  const noBank = verifyModelFacts([fact], { body: 'Available balance Rs 500' });
  assert.equal(noBank.valid, false);
  assert.match(noBank.errors.join(' '), /bank-account evidence/);
  const noSuffix = verifyModelFacts([{
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
  assert.equal(verifyModelFacts([fact], { body: 'Rs 250 debited from your account' }).valid, true);
  assert.equal(verifyModelFacts([fact], { body: 'payout for Rs. 250 is processed with reference ID: 12345' }).valid, true);
  assert.equal(verifyModelFacts([fact], { body: 'Your payment of Rs 250 for REF123 was completed successfully.' }).valid, true);
  assert.equal(verifyModelFacts([fact], { body: 'Rs 250 debit declined' }).valid, false);
  assert.equal(verifyModelFacts([fact], { body: 'Rs 250 will be debited' }).valid, false);
});

test('expanded completion verbs accept disbursements, SIPs and deposits', () => {
  for (const verb of ['disbursed', 'invested', 'deposited', 'payout', 'settled']) {
    assert.match(verb, MOVEMENT_VERBS, `${verb} must be a movement verb`);
  }
  const fact = (amount) => ({
    factType: 'posted_movement',
    payload: { amountRole: 'posted', amountInr: amount, entryKind: 'spend', occurredAt: '2026-10-20T10:00:00Z' },
  });
  assert.equal(verifyModelFacts([fact(20000)], { body: 'Rs 20000 disbursed to your account' }).valid, true);
  assert.equal(verifyModelFacts([fact(500)], { body: 'SIP of Rs 500 invested in XYZ fund' }).valid, true);
  assert.equal(verifyModelFacts([fact(100)], { body: 'Rs 100 deposited' }).valid, true);
  assert.equal(
    verifyModelFacts([fact(1944.38)], {
      body: 'payout of Rs 1,944.38 has been processed towards your Bank A/c XX1797',
    }).valid,
    true,
  );
  assert.equal(
    verifyModelFacts([fact(250)], { body: 'Rs 250 settled to your account' }).valid,
    true,
  );
});

test('promotional and maintenance footers do not invalidate genuine movements', () => {
  const fact = (amount) => ({
    factType: 'posted_movement',
    payload: { amountRole: 'posted', amountInr: amount, entryKind: 'spend', occurredAt: '2026-10-20T10:00:00Z' },
  });
  const promotion = verifyModelFacts([fact(500)], {
    body: 'Rs 500.00 debited from A/c XX1234 on 24-Oct. You are eligible for a personal loan of Rs 5 Lakh',
  });
  assert.equal(promotion.valid, true, promotion.errors.join('; '));
  const maintenance = verifyModelFacts([fact(250)], {
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
    assert.equal(verifyModelFacts([fact], { body }).valid, false, body);
    assert.equal(hasCompletionEvidence(body), false, body);
  }
});
