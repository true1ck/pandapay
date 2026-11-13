'use strict';
// WP-08 pure logic: projection mapping, event / instrument merge rules, cursors,
// the flag guard and the startup contracts check. No database.
//   node --test api/test/sms_v2/facts_logic.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');

const { projectEvent, entryKindFor, movesCardState, ENTRY_KIND_BY_TYPE } = require('../../src/sms_v2/projection');
const storage = require('../../src/sms_v2/storage');
const { createRequireSmsV2, assertContractsPresent } = require('../../src/sms_v2/guard');
const h = require('./helpers');

// ---------- projection: the Contracts "Becomes a transactions row as" column ----------

const CARD = h.uuid4();
const CARD_ID = h.uuid4();
const ACCT = h.uuid4();
const instruments = new Map([
  [CARD, { kind: 'credit_card', userCardId: CARD_ID }],
  [ACCT, { kind: 'bank_account', userCardId: null }],
]);
const ev = (type, legs, o = {}) => ({
  eventId: h.sha(type), type, status: 'complete', legs: legs || [{ factId: h.sha(type), role: 'debit_leg' }],
  occurredAt: h.T0, amountMinor: 12345, ...o,
});
const led = (o = {}) => ({
  entryId: h.sha(`l${Math.random()}`), occurredAt: h.T0, unit: 'INR', fromInstrumentId: CARD, fromExternal: null,
  toInstrumentId: null, toExternal: 'SYNTHETIC SHOP', category: 'food', ...o,
});
const anchor = { sourceKey: 'sms:synthetic:1', rail: 'card' };

const EXPECT = {
  purchase: 'spend', subscription_charge: 'spend', fee: 'spend', emi: 'spend', bill_payment: 'spend', atm_withdrawal: 'spend', p2p_out: 'spend',
  refund: 'refund', cashback: 'income', income: 'income', p2p_in: 'income', dividend: 'income', investment: 'investment',
  own_transfer: 'transfer', card_bill_payment: 'transfer', wallet_topup: 'transfer', investment_withdrawal: 'investment_return',
};

test('every event type maps to the row kind in the Contracts table', () => {
  for (const [type, kind] of Object.entries(EXPECT)) {
    const row = projectEvent({ event: ev(type), ledger: [led()], instruments, anchor });
    assert.ok(row, `${type} should be a row`);
    assert.equal(row.entryKind, kind, type);
    assert.equal(row.amountMinor, 12345);
    assert.equal(row.sourceKey, 'sms:synthetic:1');
  }
  assert.deepEqual(Object.keys(ENTRY_KIND_BY_TYPE).sort(), Object.keys(EXPECT).sort());
});

test('unknown is never a row; ipo_application is a row only once converted', () => {
  assert.equal(projectEvent({ event: ev('unknown'), ledger: [], instruments, anchor }), null);
  const held = ev('ipo_application', [{ factId: h.sha('a'), role: 'hold_placed' }, { factId: h.sha('b'), role: 'hold_released' }]);
  assert.equal(entryKindFor(held), null);
  assert.equal(projectEvent({ event: held, ledger: [], instruments, anchor }), null);
  const converted = ev('ipo_application', [{ factId: h.sha('a'), role: 'hold_placed' }, { factId: h.sha('c'), role: 'hold_converted' }]);
  assert.equal(projectEvent({ event: converted, ledger: [led()], instruments, anchor }).entryKind, 'investment');
  const allotted = ev('ipo_application', [{ factId: h.sha('a'), role: 'hold_placed' }, { factId: h.sha('d'), role: 'debit_leg' }]);
  assert.equal(entryKindFor(allotted), 'investment');
});

test('a zero-amount event is not a row', () => {
  assert.equal(projectEvent({ event: ev('purchase', null, { amountMinor: 0 }), ledger: [led()], instruments, anchor }), null);
});

test('empty ledgers and rejected endpoints never project a financial row', () => {
  assert.equal(projectEvent({ event: ev('purchase'), ledger: [], instruments, anchor }), null);
  assert.equal(projectEvent({ event: ev('purchase'), ledger: [led({ unit: 'POINTS' })], instruments, anchor }), null);
  const rejected = new Map([...instruments, [ACCT, { kind: 'bank_account', status: 'rejected' }]]);
  assert.equal(projectEvent({ event: ev('own_transfer'), ledger: [led({ toInstrumentId: ACCT, toExternal: null })], instruments: rejected, anchor }), null);
  assert.equal(projectEvent({ event: ev('purchase'), ledger: [led({ fromInstrumentId: ACCT })], instruments: rejected, anchor }), null);
});

test('purchase: merchant, category slug, card and instrument come from the ledger and instrument', () => {
  const row = projectEvent({ event: ev('purchase'), ledger: [led()], instruments, anchor });
  assert.equal(row.merchantName, 'SYNTHETIC SHOP');
  assert.equal(row.categorySlug, 'food');
  assert.equal(row.userCardId, CARD_ID);
  assert.equal(row.instrument, 'credit_card');
  assert.equal(row.rail, 'unknown');
  assert.equal(movesCardState(row), true);
});

test('income-side types read the merchant from `from` and the instrument from `to`', () => {
  const l = led({ fromInstrumentId: null, fromExternal: 'SYNTHETIC EMPLOYER', toInstrumentId: ACCT, toExternal: null, category: null });
  const row = projectEvent({ event: ev('income'), ledger: [l], instruments, anchor: { sourceKey: 'k', rail: 'upi' } });
  assert.equal(row.merchantName, 'SYNTHETIC EMPLOYER');
  assert.equal(row.instrument, 'upi_bank');
  assert.equal(row.rail, 'upi_qr');
  assert.equal(row.userCardId, null);
  assert.equal(movesCardState(row), false);
});

test('only a credit-card spend moves card state', () => {
  const spendOnCard = projectEvent({ event: ev('purchase'), ledger: [led()], instruments, anchor });
  assert.equal(movesCardState(spendOnCard), true);
  const refundOnCard = projectEvent({ event: ev('refund'), ledger: [led({ fromInstrumentId: null, fromExternal: 'S', toInstrumentId: CARD, toExternal: null })], instruments, anchor });
  assert.equal(movesCardState(refundOnCard), false);
  const spendOnBank = projectEvent({ event: ev('purchase'), ledger: [led({ fromInstrumentId: ACCT })], instruments, anchor });
  assert.equal(movesCardState(spendOnBank), false);
  // A bank account that names a user card still yields a cardless row (transactions_card_matches_instrument).
  const linkedBank = new Map([[ACCT, { kind: 'bank_account', userCardId: CARD_ID }]]);
  assert.equal(projectEvent({ event: ev('purchase'), ledger: [led({ fromInstrumentId: ACCT })], instruments: linkedBank, anchor }).userCardId, null);
  const debit = new Map([[ACCT, { kind: 'debit_card', userCardId: CARD_ID }]]);
  assert.equal(projectEvent({ event: ev('purchase'), ledger: [led({ fromInstrumentId: ACCT })], instruments: debit, anchor }).userCardId, CARD_ID);
  const transfer = projectEvent({ event: ev('card_bill_payment'), ledger: [led({ fromInstrumentId: CARD })], instruments, anchor });
  assert.equal(movesCardState(transfer), false);
});

test('rails: ATM and EMI come from the event, UPI from the fact, the rest is unknown', () => {
  assert.equal(projectEvent({ event: ev('atm_withdrawal'), ledger: [led()], instruments, anchor }).rail, 'atm');
  assert.equal(projectEvent({ event: ev('emi'), ledger: [led()], instruments, anchor }).rail, 'emi');
  assert.equal(projectEvent({ event: ev('purchase'), ledger: [led()], instruments, anchor: { sourceKey: 'k', rail: 'upi' } }).rail, 'upi_qr');
  assert.equal(projectEvent({ event: ev('purchase'), ledger: [led()], instruments, anchor: { sourceKey: 'k', rail: 'imps' } }).rail, 'unknown');
});

test('POINTS ledger entries never provide a merchant or a card', () => {
  const row = projectEvent({ event: ev('purchase'), ledger: [led({ unit: 'POINTS', toExternal: 'POINTS HOLDER' }), led({ fromInstrumentId: null, toExternal: null })], instruments, anchor });
  assert.equal(row.merchantName, null);
  assert.equal(row.userCardId, null);
});

// ---------- event merge: legs only grow, status rules ----------

const A = h.sha('a');
const B = h.sha('b');
const C = h.sha('c');
const mkEvent = (status, legs, o = {}) => ({
  eventId: A, type: 'card_bill_payment', status, legs, linkRuleId: 'LINK-CARD-BILL', confidence: 0.9, occurredAt: h.T0, amountMinor: 1000, ...o,
});
const debit = { factId: A, role: 'debit_leg' };
const credit = { factId: B, role: 'credit_leg' };

test('a new event is stored as sent', () => {
  const inc = mkEvent('awaiting_leg', [debit]);
  const m = storage.mergeEvent(undefined, inc);
  assert.deepEqual(m, { ok: true, merged: inc, changed: true });
});

test('legs only grow: stored legs stay first, new legs are appended, omitted legs are kept', () => {
  const ex = mkEvent('awaiting_leg', [debit]);
  const grown = storage.mergeEvent(ex, mkEvent('complete', [debit, credit]));
  assert.equal(grown.ok, true);
  assert.deepEqual(grown.merged.legs, [debit, credit]);
  assert.equal(grown.merged.status, 'complete');
  assert.equal(grown.changed, true);
  const stale = storage.mergeEvent(mkEvent('complete', [debit, credit]), mkEvent('complete', [debit]));
  assert.equal(stale.ok, true);
  assert.deepEqual(stale.merged.legs, [debit, credit]);
  assert.equal(stale.changed, false);
});

test('a leg cannot change role', () => {
  const r = storage.mergeEvent(mkEvent('complete', [debit, credit]), mkEvent('complete', [debit, { factId: B, role: 'reversal' }]));
  assert.deepEqual(r, { ok: false, code: 'event_leg_role_conflict' });
});

test('allowed status changes', () => {
  const ok = [
    ['awaiting_leg', 'complete'], ['awaiting_leg', 'ambiguous'], ['ambiguous', 'complete'],
    ['awaiting_leg', 'user_confirmed'], ['ambiguous', 'user_confirmed'], ['complete', 'user_confirmed'], ['user_confirmed', 'user_confirmed'],
    ['complete', 'complete'], ['ambiguous', 'ambiguous'], ['awaiting_leg', 'awaiting_leg'],
  ];
  for (const [from, to] of ok) {
    const r = storage.mergeEvent(mkEvent(from, [debit]), mkEvent(to, [debit], { confidence: 0.8 }));
    assert.equal(r.ok, true, `${from} -> ${to}`);
  }
});

test('forbidden status changes', () => {
  const bad = [['complete', 'awaiting_leg'], ['complete', 'ambiguous'], ['ambiguous', 'awaiting_leg']];
  for (const [from, to] of bad) {
    const r = storage.mergeEvent(mkEvent(from, [debit]), mkEvent(to, [debit]));
    assert.deepEqual(r, { ok: false, code: 'event_status_transition_invalid' }, `${from} -> ${to}`);
  }
});

test('explicit user-confirmed corrections replace wrong legs and roles', () => {
  const initial = mkEvent('complete', [debit, credit]);
  const corrected = mkEvent('user_confirmed', [{...debit, role:'original'}]);
  const first = storage.mergeEvent(initial, corrected);
  assert.equal(first.ok, true);
  assert.deepEqual(first.merged.legs, corrected.legs);
  assert.deepEqual(storage.mergeEvent(first.merged, corrected), {ok:true,merged:corrected,changed:false});
});

test('nothing leaves user_confirmed', () => {
  for (const to of ['awaiting_leg', 'ambiguous', 'complete']) {
    const r = storage.mergeEvent(mkEvent('user_confirmed', [debit, credit]), mkEvent(to, [debit, credit], { type: 'unknown' }));
    assert.deepEqual(r, { ok: false, code: 'event_status_locked' }, `user_confirmed -> ${to}`);
  }
  // The user may still re-confirm, and legs still grow.
  const r = storage.mergeEvent(mkEvent('user_confirmed', [debit]), mkEvent('user_confirmed', [debit, credit]));
  assert.equal(r.ok, true);
  assert.deepEqual(r.merged.legs, [debit, credit]);
});

test('timestamps compare as instants when deciding whether an event changed', () => {
  const ex = mkEvent('complete', [debit], { occurredAt: '2026-11-01T07:00:11Z' });
  const r = storage.mergeEvent(ex, mkEvent('complete', [debit], { occurredAt: '2026-11-01T07:00:11.000Z' }));
  assert.equal(r.changed, false);
});

// ---------- own -> own amount rule ----------

test('own entry amount is checked against the debit leg first, then the credit leg', () => {
  const posted = new Map([[A, 1000], [B, 990]]);
  assert.deepEqual(storage.ownEntryLegAmounts([debit, credit], posted), [1000]);
  assert.deepEqual(storage.ownEntryLegAmounts([credit], posted), [990]);
  assert.equal(storage.ownEntryLegAmounts([{ factId: C, role: 'hold_placed' }], posted), null);
  assert.equal(storage.ownEntryLegAmounts([debit], new Map()), null);
});

// ---------- instrument merge ----------

test('instrument merge keeps a user-entered limit, the latest balance and the widest seen window', () => {
  const ex = h.instrument({ instrumentId: h.uuid4(), creditLimitMinor: 500000, creditLimitSource: 'user', creditLimitAt: '2026-10-01T00:00:00Z', availableMinor: 100, availableAt: '2026-11-02T00:00:00Z', evidenceCount: 9, lastSeenAt: '2026-11-02T00:00:00Z' });
  const inc = { ...ex, creditLimitMinor: 300000, creditLimitSource: 'sms', creditLimitAt: '2026-11-01T00:00:00Z', availableMinor: 50, availableAt: '2026-11-01T00:00:00Z', evidenceCount: 3, lastSeenAt: '2026-11-01T00:00:00Z', displayName: 'Renamed' };
  const m = storage.mergeInstrument(ex, inc);
  assert.equal(m.creditLimitMinor, 500000);
  assert.equal(m.creditLimitSource, 'user');
  assert.equal(m.availableMinor, 100, 'older snapshot must not replace a newer one');
  assert.equal(m.evidenceCount, 9);
  assert.equal(m.lastSeenAt, '2026-11-02T00:00:00Z');
  assert.equal(m.displayName, 'Renamed');
  const userNow = storage.mergeInstrument({ ...ex, creditLimitSource: 'sms' }, { ...inc, creditLimitSource: 'user', creditLimitMinor: 700000 });
  assert.equal(userNow.creditLimitMinor, 700000);
});

test('automatic detection cannot undo an explicit instrument decision', () => {
  const detected = h.instrument({ status: 'detected' });
  for (const status of ['confirmed', 'rejected']) {
    assert.equal(storage.mergeInstrument({ ...detected, status }, detected).status, status);
  }
  assert.equal(storage.mergeInstrument({ ...detected, status: 'rejected' }, { ...detected, status: 'confirmed' }).status, 'confirmed');
});

// ---------- cursors ----------

test('cursors round-trip and reject anything else', () => {
  const c = { i: ['2026-11-01T07:00:11.123456Z', h.uuid4()], e: ['2026-11-01T07:00:12.000001Z', A], a: 'hook-state' };
  assert.deepEqual(storage.decodeCursor(storage.encodeCursor(c)), c);
  assert.deepEqual(storage.decodeCursor(undefined), {});
  assert.deepEqual(storage.decodeCursor(''), {});
  for (const bad of ['not base64 json', Buffer.from('[1]').toString('base64url'), Buffer.from('{"x":1}').toString('base64url'),
    Buffer.from('{"i":["2026-11-01",1]}').toString('base64url'), Buffer.from('{"i":["yesterday","x"]}').toString('base64url')]) {
    assert.equal(storage.decodeCursor(bad), null, bad);
  }
});

// ---------- the flag guard ----------

function run(mw, req = {}) {
  return new Promise((resolve) => {
    const res = {
      status(code) { this.code = code; return this; },
      json(body) { resolve({ code: this.code, body }); return this; },
    };
    mw({ userId: null, ...req }, res, () => resolve({ code: 'next' }));
  });
}

test('requireSmsV2: off by default, 404 when disabled, passes when enabled', async () => {
  const none = createRequireSmsV2({ readFlag: async () => null, cacheMs: 0 });
  assert.deepEqual(await run(none), { code: 404, body: { error: 'not_found' } });
  const off = createRequireSmsV2({ readFlag: async () => ({ key: 'sms_pipeline_v2_enabled', is_enabled: false, rollout_percent: 100 }), cacheMs: 0 });
  assert.equal((await run(off)).code, 404);
  const on = createRequireSmsV2({ readFlag: async () => ({ key: 'sms_pipeline_v2_enabled', is_enabled: true, rollout_percent: 100 }), cacheMs: 0 });
  assert.equal((await run(on)).code, 'next');
  const zero = createRequireSmsV2({ readFlag: async () => ({ key: 'sms_pipeline_v2_enabled', is_enabled: true, rollout_percent: 0 }), cacheMs: 0 });
  assert.equal((await run(zero, { userId: h.uuid4() })).code, 404);
});

test('requireSmsV2: a percentage rollout is decided per profile, and unknown profiles are out', async () => {
  const row = { key: 'sms_pipeline_v2_enabled', is_enabled: true, rollout_percent: 50 };
  const g = createRequireSmsV2({ readFlag: async () => row, cacheMs: 0 });
  assert.equal((await run(g, { userId: null })).code, 404);
  const outcomes = new Set();
  for (let i = 0; i < 60; i += 1) outcomes.add((await run(g, { userId: h.uuid4() })).code);
  assert.deepEqual([...outcomes].sort(), [404, 'next'].sort((a, b) => String(a).localeCompare(String(b))));
});

test('requireSmsV2: a failing flag read answers 503, and reads are cached', async () => {
  const bad = createRequireSmsV2({ readFlag: async () => { throw new Error('db down'); }, cacheMs: 0 });
  const origError = console.error;
  console.error = () => {};
  try { assert.deepEqual(await run(bad), { code: 503, body: { error: 'flag_unavailable' } }); } finally { console.error = origError; }
  let reads = 0;
  let clock = 1000;
  const cached = createRequireSmsV2({ readFlag: async () => { reads += 1; return { key: 'sms_pipeline_v2_enabled', is_enabled: true, rollout_percent: 100 }; }, cacheMs: 5000, now: () => clock });
  await run(cached); await run(cached);
  assert.equal(reads, 1);
  clock += 6000;
  await run(cached);
  assert.equal(reads, 2);
});

// ---------- startup check ----------

test('startup fails clearly when the contracts are missing', () => {
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'sms-v2-no-contracts-'));
  try {
    assert.throws(() => assertContractsPresent(empty), /SMS v2 contracts missing/);
    assert.doesNotThrow(() => assertContractsPresent());
  } finally { fs.rmSync(empty, { recursive: true, force: true }); }
});

test('a plain UPI payment keeps its payment method; other rails have none', () => {
  const upi = projectEvent({ event: ev('purchase'), ledger: [led()], instruments, anchor: { ...anchor, rail: 'upi' } });
  assert.equal(upi.paymentMethod, 'upi');
  assert.equal(upi.rail, 'upi_qr');
  for (const rail of ['card', 'imps', 'neft', 'wallet', 'cash', 'unknown', null]) {
    const row = projectEvent({ event: ev('purchase'), ledger: [led()], instruments, anchor: { ...anchor, rail } });
    assert.equal(row.paymentMethod, null, String(rail));
  }
});
