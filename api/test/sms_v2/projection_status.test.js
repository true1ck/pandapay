'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { projectEvent } = require('../../src/sms_v2/projection');

test('ambiguous events never become transaction rows on the server', () => {
  for (const type of ['purchase', 'income', 'investment', 'refund', 'card_bill_payment']) {
    const event = { eventId: 'a'.repeat(64), type, status: 'ambiguous', amountMinor: 10000,
      occurredAt: '2026-11-03T10:00:00Z', legs: [{ factId: 'a'.repeat(64), role: 'debit_leg' }] };
    assert.equal(projectEvent({ event, ledger: [], instruments: new Map(), anchor: null }), null, type);
  }
});
