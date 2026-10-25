'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { verifyModelFacts, moneyInMessage } = require('../src/ai_fact_evidence');

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
  assert.equal(verifyModelFacts([fact], { body: 'Rs 250 debit declined' }).valid, false);
  assert.equal(verifyModelFacts([fact], { body: 'Rs 250 will be debited' }).valid, false);
});
