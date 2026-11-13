'use strict';

// Real cards, real rules. The three cards come from the live catalogue
// (trimmed copy in fixtures/real_cards_2026_11.json); the spend amounts are made
// up, the behaviour is what the banks do:
//   - Axis pays 5% cashback on Flipkart, rounded down to the rupee (Rs18,347 -> Rs917).
//   - HDFC credits a 2,500-point "10X Cashpoints" bonus on partner spends (the
//     monthly bonus cap), on top of the normal points.
//   - slice pays 1% on every eligible spend, UPI included.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const rewardV2 = require('../src/reward_math_v2');
const cardStateV2 = require('../src/card_state_v2');
const { loadDirectory } = require('../src/merchant_directory');

const FX = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'real_cards_2026_11.json'), 'utf8'));
const directory = loadDirectory({ merchants: FX.merchants, platforms: FX.platforms });
const card = (slug) => FX.cards.find((c) => c.slug === slug);
const CAT = FX.categories;

function earn(slug, ctx, consumed = {}) {
  const c = card(slug);
  return rewardV2.computeTransactionRewardV2({
    card: c, rewardRules: c.reward_rules, capRules: c.cap_rules, capConsumedBefore: consumed,
    ctx: { occurred: '2026-10-20T12:00:00Z', rail: 'unknown', ...ctx }, directory,
  });
}

// ---------------------------------------------------------------------------
// slice: 1% on everything eligible, including UPI on the credit card
// ---------------------------------------------------------------------------
const SLICE = 'slice-small-finance-bank-upi-credit-card';

test('slice: 1% on an ordinary spend', () => {
  const r = earn(SLICE, { amount: 1000, merchant_name: 'Sample super store' });
  assert.equal(r.valueInr, 10);
  assert.equal(r.engine, 'v2');
});

test('slice: a UPI payment from the credit card earns the same 1% (RuPay credit card on UPI)', () => {
  const r = earn(SLICE, { amount: 25, rail: 'upi_qr', merchant_name: 'Mhalasa giroba enter' });
  assert.equal(r.valueInr, 0.25);
  const big = earn(SLICE, { amount: 4189, rail: 'upi_qr', merchant_name: 'Shop' });
  assert.equal(big.valueInr, 41.89);
});

test('slice: an unknown rail never blocks the base rate', () => {
  assert.equal(earn(SLICE, { amount: 500, rail: 'unknown' }).valueInr, 5);
});

test('slice: excluded spends earn nothing (fuel, rent, wallet, government, insurance, education, EMI)', () => {
  for (const [name, category] of [['fuel', 'fuel'], ['rent', 'rent'], ['wallet', 'wallet'], ['government', 'government'], ['insurance', 'insurance'], ['education', 'education'], ['emi', 'emi']]) {
    const r = earn(SLICE, { amount: 1000, category_id: CAT[category] });
    assert.equal(r.valueInr, 0, name);
    assert.equal(r.excluded, true, name);
  }
});

test('slice: cash withdrawal (MCC 6010) earns nothing; a zero or negative amount never earns', () => {
  assert.equal(earn(SLICE, { amount: 5000, mcc: '6010' }).valueInr, 0);
  assert.equal(earn(SLICE, { amount: 0 }).valueInr, 0);
  assert.equal(earn(SLICE, { amount: -500 }).valueInr, 0);
});

// ---------------------------------------------------------------------------
// Flipkart Axis: 5% Flipkart, 7.5% Myntra, 1% elsewhere, nothing under Rs100
// ---------------------------------------------------------------------------
const AXIS = 'flipkart-axis-bank-credit-card';

test('Flipkart Axis: Rs18,347 on Flipkart is Rs917 cashback (5%, rounded down to the rupee)', () => {
  const r = earn(AXIS, { amount: 18347, merchant_name: 'FLIPKART PA' });
  assert.equal(r.cashbackInr, 917);
  assert.equal(r.valueInr, 917);
});

test('Flipkart Axis: a Flipkart name the bank cut short still earns 5%, not 1%', () => {
  for (const name of ['PYU*Flipkar', 'Flipka', 'FLIPKART INTERNET PV']) {
    assert.equal(earn(AXIS, { amount: 1000, merchant_name: name }).valueInr, 50, name);
  }
});

test('Flipkart Axis: Myntra 7.5%, other spends 1%, under Rs100 nothing', () => {
  assert.equal(earn(AXIS, { amount: 1035, merchant_name: 'MYNTRA DESI' }).valueInr, 77);
  assert.equal(earn(AXIS, { amount: 1340, merchant_name: 'Axis Bill p' }).valueInr, 13);
  const small = earn(AXIS, { amount: 95, merchant_name: 'Axis Bill p' });
  assert.equal(small.valueInr, 0);
  assert.equal(small.excluded, true);
});

test('Flipkart Axis: the Rs4,000 quarterly cap on the 5% bonus stops it', () => {
  const capId = card(AXIS).cap_rules.find((c) => /Flipkart/.test(c.label)).id;
  const r = earn(AXIS, { amount: 10000, merchant_name: 'FLIPKART' }, { [capId]: 3900 });
  assert.ok(r.valueInr < 500, `only ~Rs100 of the Rs500 fits under the cap, got ${r.valueInr}`);
  assert.ok(r.valueInr >= 100);
});

test('Flipkart Axis: fuel earns nothing', () => {
  assert.equal(earn(AXIS, { amount: 1000, category_id: CAT.fuel }).valueInr, 0);
});

// ---------------------------------------------------------------------------
// HDFC MoneyBack+: 2 CashPoints per Rs200, 10X on partners up to 2,500 bonus a month
// ---------------------------------------------------------------------------
const MONEYBACK = 'hdfc-moneyback-plus';

test('MoneyBack+: a Rs85,150 Flipkart spend earns base plus the 2,500-point 10X bonus', () => {
  const r = earn(MONEYBACK, { amount: 85150, merchant_name: 'Flipkart' });
  assert.equal(r.points, 850 + 2500, '425 blocks of 2 points, plus the monthly bonus cap');
  assert.equal(r.valueInr, 670);
  assert.ok(r.reasons.includes('bonus_cap_reached'));
});

test('MoneyBack+: once the month\'s 2,500 bonus is used, a partner spend earns only the base', () => {
  const capId = card(MONEYBACK).cap_rules.find((c) => /10x/i.test(c.label)).id;
  const r = earn(MONEYBACK, { amount: 2000, merchant_name: 'Swiggy' }, { [capId]: 2500 });
  assert.equal(r.points, 20, '10 blocks x 2 points');
});

test('MoneyBack+: an ordinary spend earns 2 points per Rs200 (Rs0.20 each)', () => {
  const r = earn(MONEYBACK, { amount: 1000, merchant_name: 'APOLLO PHARMACIES' });
  assert.equal(r.points, 10);
  assert.equal(r.valueInr, 2);
});

test('MoneyBack+: fuel, rent, wallet loads, EMI and anything under Rs200 earn nothing', () => {
  assert.equal(earn(MONEYBACK, { amount: 1000, category_id: CAT.fuel }).valueInr, 0);
  assert.equal(earn(MONEYBACK, { amount: 1000, category_id: CAT.rent }).valueInr, 0);
  assert.equal(earn(MONEYBACK, { amount: 1000, rail: 'emi' }).valueInr, 0);
  assert.equal(earn(MONEYBACK, { amount: 102.53, merchant_name: 'ORACLE SINGAPORE' }).valueInr, 0);
});

test('MoneyBack+: a fuel purchase whose name the bank cut short is now categorised as fuel upstream', () => {
  // The SMS category rules now know PETROLEU; with the category set the card excludes it.
  assert.equal(earn(MONEYBACK, { amount: 500, merchant_name: 'ACME PETROLEU', category_id: CAT.fuel }).valueInr, 0);
});

// ---------------------------------------------------------------------------
// The whole-card replay: history is priced, refunds undo it, caps stay per period
// ---------------------------------------------------------------------------
const userCardRow = (slug) => ({
  id: 'uc-' + slug, card_product_id: card(slug).id, profile_id: 'p1', statement_day: null,
  opened_on: '2025-01-01', anniversary_on: null, created_at: '2025-01-01T00:00:00Z',
});
const v2Of = (slug) => cardStateV2.buildV2Card({
  userCard: { ...userCardRow(slug), point_value_inr: card(slug).point_value_inr, base_reward_unit: card(slug).base_reward_unit, base_reward_rate: card(slug).base_reward_rate, excluded_categories: card(slug).excluded_categories, accrual_block_inr: card(slug).accrual_block_inr, accrual_rounding: card(slug).accrual_rounding, cashback_rounding: card(slug).cashback_rounding },
  rules: card(slug).reward_rules, caps: card(slug).cap_rules, milestones: [],
});

let seq = 0;
const row = (day, amount, extra = {}) => {
  seq += 1;
  return {
    id: `00000000-0000-4000-8000-${String(seq).padStart(12, '0')}`, amount_inr: String(amount),
    occurred_at: new Date(`${day}T10:00:00Z`), category_id: null, merchant_name: null, merchant_vpa: null,
    mcc: null, rail: 'unknown', status: 'active', instrument: 'credit_card', entry_kind: 'spend',
    is_backfill: true, expected_points: null, expected_value_inr: null, card_state_v2: null, ...extra,
  };
};

test('replay: a Rs78,000 Axis spend that was refunded earns nothing; without the refund it would have earned Rs3,900', () => {
  const v2 = v2Of(AXIS);
  const spend = row('2026-10-12', 78000, { merchant_name: 'FLIPKART' });
  const refund = row('2026-10-26', 78000, { merchant_name: 'FLIPKART', entry_kind: 'refund' });
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-12T06:00:00Z'), caps: true, expected: true, since: '2026-10-01' });
  const without = cardStateV2.planReplay({ v2, directory, range, transactions: [spend], expected: true });
  const withRefund = cardStateV2.planReplay({ v2, directory, range, transactions: [spend, refund], expected: true });
  assert.equal(without.txnExpectedUpdates[0].value, 3900, '5% of 78,000, under the Rs4,000 cap');
  assert.equal(withRefund.txnExpectedUpdates[0].value, 0);
  assert.equal(withRefund.capRows.length, 0);
});

test('replay: history across months is priced per month and the caps never leak between months', () => {
  const v2 = v2Of(MONEYBACK);
  const sep = row('2026-09-10', 85150, { merchant_name: 'Flipkart' });
  const oct = row('2026-10-20', 85150, { merchant_name: 'Flipkart' });
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-12T06:00:00Z'), caps: true, expected: true, since: '2026-09-01' });
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [sep, oct], expected: true });
  const byId = Object.fromEntries(plan.txnExpectedUpdates.map((u) => [u.id, u]));
  assert.equal(byId[sep.id].native, 3350);
  assert.equal(byId[oct.id].native, 3350, 'October gets its own 2,500 bonus; September used up only its own');
});

test('replay: a card spend with no card rules matching still earns the base rate, and nothing throws on odd rows', () => {
  const v2 = v2Of(SLICE);
  const rows = [
    row('2026-10-01', 100),
    row('2026-10-02', 0),
    row('2026-10-03', 100, { status: 'ignored' }),
    row('2026-10-04', 100, { instrument: 'debit_card' }),
    row('2026-10-05', 100, { entry_kind: 'income' }),
    row('2026-10-06', 100, { merchant_name: null, category_id: null, rail: 'upi_qr' }),
  ];
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-12T06:00:00Z'), caps: true, expected: true, since: '2026-10-01' });
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: rows, expected: true });
  const priced = plan.txnExpectedUpdates.map((u) => [u.id, u.value]);
  assert.deepEqual(priced.map(([, v]) => v).sort(), [0, 1, 1], 'the two ordinary Rs100 spends earn Rs1; the Rs0 spend earns 0; ignored, debit and income rows are not priced');
});
