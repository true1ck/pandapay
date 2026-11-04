'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { downgradeRefund, legacyEntryKindFilter } = require('../src/legacy_entry_kind');

test('downgradeRefund rewrites entry_kind and entryKind anywhere in the body, nothing else', () => {
  const body = {
    transactions: [{ id: 1, entry_kind: 'refund', note: 'refund' }, { id: 2, entry_kind: 'spend' }],
    transaction: { entryKind: 'refund', nested: { entry_kind: 'refund' } },
    when: new Date('2026-01-01T00:00:00Z'),
    refund: 'refund',
  };
  const out = downgradeRefund(body);
  assert.equal(out.transactions[0].entry_kind, 'transfer');
  assert.equal(out.transactions[0].note, 'refund');
  assert.equal(out.transactions[1].entry_kind, 'spend');
  assert.equal(out.transaction.entryKind, 'transfer');
  assert.equal(out.transaction.nested.entry_kind, 'transfer');
  assert.equal(out.refund, 'refund');
  assert.equal(out.when, body.when);
  assert.equal(body.transactions[0].entry_kind, 'refund', 'input is not mutated');
});

test('downgradeRefund returns the same object when there is nothing to change', () => {
  const body = { transactions: [{ entry_kind: 'spend' }], n: 1 };
  assert.equal(downgradeRefund(body), body);
  assert.equal(downgradeRefund(null), null);
  assert.equal(downgradeRefund('refund'), 'refund');
});

function run(headers) {
  const sent = [];
  const res = { json(b) { sent.push(b); return this; } };
  legacyEntryKindFilter({ headers }, res, () => {});
  res.json({ transaction: { entry_kind: 'refund' } });
  return sent[0].transaction.entry_kind;
}

test('filter downgrades without X-Sms-Pipeline: v2 and passes refund through with it', () => {
  assert.equal(run({}), 'transfer');
  assert.equal(run({ 'x-app-version': '1.0.0' }), 'transfer');
  assert.equal(run({ 'x-sms-pipeline': 'v1' }), 'transfer');
  assert.equal(run({ 'x-sms-pipeline': 'v2' }), 'refund');
  assert.equal(run({ 'x-sms-pipeline': ' V2 ' }), 'refund');
});
