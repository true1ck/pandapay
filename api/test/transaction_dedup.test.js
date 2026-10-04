const test = require('node:test');
const assert = require('node:assert/strict');
const {
  REVIEW_THRESHOLD,
  sourceFamily,
  evaluateDuplicate,
  bestDuplicate,
} = require('../src/transaction_dedup');

const base = {
  amount: 499,
  occurred: '2026-09-09T10:00:00.000Z',
  merchantName: 'AMAZON PAY INDIA',
  userCardId: 'card-1',
  instrument: 'credit_card',
  entryKind: 'spend',
  source: 'sms',
};

test('SMS and SMS bulk are one source family, so backup re-imports rely on exact identity', () => {
  assert.equal(sourceFamily('sms_bulk'), 'sms');
  assert.equal(evaluateDuplicate(base, { ...base, source: 'sms_bulk' }), null);
});

test('same purchase from SMS and email clears the review threshold', () => {
  const match = evaluateDuplicate(base, {
    ...base,
    id: 'existing',
    source: 'email',
    merchantName: 'AmazonPayIndia',
    occurred: '2026-09-09T10:03:00.000Z',
  });
  assert.ok(match);
  assert.ok(match.score >= REVIEW_THRESHOLD);
  assert.equal(match.merchantMatch, 'exact');
});

test('manual merchant decoration can match a bank channel without fuzzy guessing', () => {
  const match = evaluateDuplicate(base, {
    ...base,
    source: 'manual',
    merchantName: 'Amazon',
    occurred: '2026-09-09T22:00:00.000Z',
  });
  assert.ok(match);
  assert.equal(match.merchantMatch, 'contained');
});

test('contradictory card, merchant, amount, or instrument evidence rejects a duplicate', () => {
  assert.equal(evaluateDuplicate(base, { ...base, source: 'email', userCardId: 'card-2' }), null);
  assert.equal(evaluateDuplicate(base, { ...base, source: 'email', merchantName: 'SWIGGY' }), null);
  assert.equal(evaluateDuplicate(base, { ...base, source: 'email', amount: 501 }), null);
  assert.equal(evaluateDuplicate(base, { ...base, source: 'email', instrument: 'debit_card' }), null);
});

test('two genuinely separate purchases outside the 36-hour window are retained', () => {
  assert.equal(
    evaluateDuplicate(base, { ...base, source: 'statement', occurred: '2026-09-11T00:01:00.000Z' }),
    null,
  );
});

test('missing merchant needs strong same-card and close-time evidence', () => {
  const close = evaluateDuplicate(
    { ...base, merchantName: null },
    { ...base, source: 'email', merchantName: null, occurred: '2026-09-09T10:20:00.000Z' },
  );
  const distant = evaluateDuplicate(
    { ...base, merchantName: null },
    { ...base, source: 'email', merchantName: null, occurred: '2026-09-10T09:00:00.000Z' },
  );
  assert.ok(close);
  assert.equal(distant, null);
});

test('bestDuplicate chooses the strongest candidate deterministically', () => {
  const selected = bestDuplicate(base, [
    { ...base, id: 'later', source: 'email', occurred: '2026-09-09T16:00:00.000Z' },
    { ...base, id: 'closest', source: 'manual', occurred: '2026-09-09T10:01:00.000Z' },
  ]);
  assert.equal(selected.candidate.id, 'closest');
});
