'use strict';
// CCR-003: an optional category on refund ledger entries.
//   node --test api/test/sms_v2/refund_category.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const c = require('../../src/sms_v2/contracts');
const { projectEvent } = require('../../src/sms_v2/projection');
const { ledgerForClient } = require('../../src/sms_v2/sync_route');
const h = require('./helpers');

const ACCT = h.uuid4();
const entry = (o = {}) => ({
  entryId: h.sha('refund-entry'), eventId: h.sha('refund-event'), from: { external: 'AMAZON' }, to: { instrumentId: ACCT },
  amountMinor: 49900, unit: 'INR', occurredAt: '2026-11-03T07:00:11Z', category: 'shopping', categorySource: 'catalogue',
  countsAsTransaction: true, isSpend: false, isIncome: false, isInvestment: false, ...o,
});
const codes = (r) => r.errors.map((e) => e.code);

test('a refund entry may carry the category of its purchase; old payloads still validate', () => {
  assert.equal(c.validateLedgerEntry(entry()).ok, true);
  assert.equal(c.validateLedgerEntry(entry({ category: null, categorySource: null })).ok, true);
  assert.equal(c.validateLedgerEntry(entry({ to: { ownUnresolved: 'credit_card' } })).ok, true);
});

test('only a refund-shaped entry may carry a category without an external destination', () => {
  for (const o of [{ isIncome: true }, { isInvestment: true }, { isSpend: true }, { countsAsTransaction: false }, { from: { instrumentId: h.uuid4() } }]) {
    const r = c.validateLedgerEntry(entry(o));
    assert.equal(r.ok, false, JSON.stringify(o));
    assert.deepEqual(codes(r), ['ledger.category_requires_external_to'], JSON.stringify(o));
  }
  assert.deepEqual(codes(c.validateLedgerEntry(entry({ categorySource: null }))), ['ledger.category_source_mismatch']);
});

test('the server projection carries a refund category to its transaction row', () => {
  const event = { eventId: h.sha('refund-event'), type: 'refund', status: 'complete', legs: [{ factId: h.sha('refund-event'), role: 'reversal' }], occurredAt: h.T0, amountMinor: 49900 };
  const instruments = new Map([[ACCT, { kind: 'credit_card', userCardId: h.uuid4() }]]);
  const ledger = (category) => [{ entryId: h.sha('l'), occurredAt: h.T0, unit: 'INR', fromInstrumentId: null, fromExternal: 'AMAZON', toInstrumentId: ACCT, toExternal: null, category }];
  const withCategory = projectEvent({ event, ledger: ledger('shopping'), instruments, anchor: { sourceKey: 's', rail: 'card' } });
  assert.equal(withCategory.entryKind, 'refund');
  assert.equal(withCategory.categorySlug, 'shopping');
  assert.equal(projectEvent({ event, ledger: ledger(null), instruments, anchor: { sourceKey: 's', rail: 'card' } }).categorySlug, null);
});

test('sync withholds a refund category from a client that does not declare support', () => {
  const refund = entry();
  const spend = entry({ entryId: h.sha('spend'), from: { instrumentId: ACCT }, to: { external: 'SWIGGY' }, category: 'food', isSpend: true });
  const req = (features) => ({ get: (name) => (name.toLowerCase() === 'x-sms-contract-features' ? features : undefined) });
  const old = ledgerForClient([refund, spend], req(undefined));
  assert.equal(old[0].category, null);
  assert.equal(old[0].categorySource, null);
  assert.equal(c.validateLedgerEntry(old[0]).ok, true);
  assert.deepEqual(old[1], spend, 'spend rows are untouched');
  assert.deepEqual(ledgerForClient([refund, spend], req('other, Refund-Category')), [refund, spend]);
  assert.equal(refund.category, 'shopping', 'the stored row is not mutated');
});
