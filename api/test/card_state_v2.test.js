'use strict';

// Card Rewards Phase 1, WP8 — the pure parts of server recording v2:
// what one transaction does to native-unit cap state, milestone windows,
// and the replay that rebuilds a period. The Postgres-backed tests in
// card_state_v2_postgres.test.js run the same logic through a database.
const test = require('node:test');
const assert = require('node:assert/strict');
const rewardV2 = require('../src/reward_math_v2');
const { loadDirectory } = require('../src/merchant_directory');
const cardStateV2 = require('../src/card_state_v2');
const F = require('./card_state_v2_fixture');

const directory = loadDirectory(F.DIRECTORY);
const v2card = (overrides) => cardStateV2.buildV2Card({
  userCard: F.userCardRow(overrides), rules: F.RULES, caps: F.CAPS, milestones: F.MILESTONES,
});

let seq = 0;
function txn(day, amount, extra = {}) {
  seq += 1;
  return {
    id: `00000000-0000-4000-9000-${String(seq).padStart(12, '0')}`,
    amount_inr: String(amount), occurred_at: new Date(`${day}T06:30:00Z`), category_id: null,
    merchant_name: null, merchant_vpa: null, mcc: null, rail: 'unknown', status: 'active',
    instrument: 'credit_card', entry_kind: 'spend', is_backfill: false,
    expected_points: null, expected_value_inr: null, card_state_v2: null, ...extra,
  };
}
const dining = (day, amount) => txn(day, amount, { category_id: F.CATEGORY.dining });
const swiggy = (day, amount) => txn(day, amount, { merchant_name: 'BUNDL TECHNOLOGIES BLR' });

/** Live recording, one transaction after another, against an in-memory cap table. */
function recordSequentially(v2, rows) {
  const table = new Map();
  const outcomes = [];
  for (const row of rows) {
    const ctx = cardStateV2.transactionContext(row);
    const out = cardStateV2.computeTransactionV2(v2, directory, ctx,
      (id, start) => table.get(`${id}|${start}`) || 0);
    for (const e of out.capEntries) table.set(`${e.id}|${e.start}`, (table.get(`${e.id}|${e.start}`) || 0) + e.delta);
    outcomes.push(out);
  }
  return { table, outcomes };
}

test('isV2 via buildV2Card: the synthetic card is v2-shaped; a card with only v1 fields is not', () => {
  assert.equal(rewardV2.isV2Card(v2card().card, F.RULES, F.CAPS), true);
  const v1Rules = [{ id: 'r1', category_id: null, unit: 'points_per_100', rate: '5', rule_role: 'earn', merchant_slugs: [], platform_slugs: [], mcc_include: [], mcc_exclude: [], block_inr: null, min_engine_version: 1 }];
  const v1Caps = [{ id: 'c1', reward_rule_id: 'r1', measure: 'spend_amount', period: 'calendar_month', cap_value: '1000', cap_kind: null }];
  assert.equal(rewardV2.isV2Card({ accrual_rounding: null, cashback_rounding: null }, v1Rules, v1Caps), false);
});

test('one dining spend moves its bonus cap, the parent and the card-scope cap, in points', () => {
  const v2 = v2card();
  const out = cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(dining('2026-11-03', 2000)), () => 0);
  assert.equal(out.result.engine, 'v2');
  assert.equal(out.native, 100);
  assert.equal(out.value, 25);
  assert.deepEqual(
    out.capEntries.map((e) => [e.id, e.kind, e.delta, e.start, e.end]),
    [
      [F.CAP.parent, 'total_points', 100, '2026-11-01', '2026-11-30'],
      [F.CAP.bonus, 'bonus_points', 80, '2026-11-01', '2026-11-30'],
      // Card year from opened_on (anniversary_on is null): exact, not approximate.
      [F.CAP.cardYear, 'total_points', 100, '2026-10-01', '2027-09-30'],
    ],
  );
  assert.ok(out.capEntries.every((e) => e.approximate === false));
  assert.deepEqual(out.capEntries.map((e) => e.amount), [2500, 1000, 6000]);
});

test('an eligible-spend cap consumes rupees of spend; overflow earns base; the count cap consumes 1', () => {
  const v2 = v2card();
  const out = cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(swiggy('2026-11-04', 30000)), () => 0);
  assert.equal(out.native, 2100); // 200 blocks × 10 on ₹20,000 + 100 base on the ₹10,000 overflow
  const byId = Object.fromEntries(out.capEntries.map((e) => [e.id, [e.kind, e.delta]]));
  assert.deepEqual(byId, {
    [F.CAP.parent]: ['total_points', 2100],
    [F.CAP.spend]: ['eligible_spend', 20000],
    [F.CAP.cardYear]: ['total_points', 2100],
    [F.CAP.count]: ['txn_count', 1],
  });
});

test('caps are read per their own period: a card-year cap does not reset with the month', () => {
  const v2 = v2card();
  const reads = [];
  cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(dining('2026-12-02', 100)), (id, start) => {
    reads.push([id, start]);
    return 0;
  });
  assert.deepEqual(reads.sort(), [
    [F.CAP.parent, '2026-12-01'], [F.CAP.bonus, '2026-12-01'], [F.CAP.cardYear, '2026-10-01'],
  ].sort());
});

test('sequential recording matches the engine fed the same native consumption', () => {
  const v2 = v2card();
  const rows = [dining('2026-11-03', 2000), swiggy('2026-11-04', 30000), dining('2026-11-05', 30000),
    txn('2026-11-05', 500, { category_id: F.CATEGORY.wallet }), swiggy('2026-11-06', 1000), swiggy('2026-11-07', 1000)];
  const { table, outcomes } = recordSequentially(v2, rows);
  assert.deepEqual(outcomes.map((o) => o.native), [100, 2100, 300, 0, 0, 0]);
  assert.equal(outcomes[3].result.excluded, true);
  // Dining ₹30,000: 1,500 accrued, bonus capped at the 920 left, then the parent's
  // 300 remaining cuts the total and the cut comes off the bonus first.
  assert.deepEqual(
    Object.fromEntries(outcomes[2].capEntries.map((e) => [e.id, e.delta])),
    { [F.CAP.parent]: 300, [F.CAP.cardYear]: 300 },
  );
  // Second swiggy spend: the spend cap is used up (overflow earns base) but
  // the parent total is exhausted, so nothing is paid; the count cap still
  // takes 1 (C8 D9(8)).
  assert.deepEqual(
    Object.fromEntries(outcomes[4].capEntries.map((e) => [e.id, e.delta])),
    { [F.CAP.count]: 1 },
  );
  // Third swiggy spend in the month: the count cap is exhausted → zero.
  assert.deepEqual(outcomes[5].capEntries, []);
  assert.equal(table.get(`${F.CAP.parent}|2026-11-01`), 2500);
  assert.equal(table.get(`${F.CAP.bonus}|2026-11-01`), 80);
  assert.equal(table.get(`${F.CAP.spend}|2026-11-01`), 20000);
  assert.equal(table.get(`${F.CAP.count}|2026-11-01`), 2);
  assert.equal(table.get(`${F.CAP.cardYear}|2026-10-01`), 2500);
});

test('created_at as the anchor makes card-year windows approximate', () => {
  const v2 = v2card({ opened_on: null, anniversary_on: null });
  const out = cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(dining('2026-11-03', 2000)), () => 0);
  const cardYear = out.capEntries.find((e) => e.id === F.CAP.cardYear);
  assert.deepEqual([cardYear.start, cardYear.end, cardYear.approximate], ['2026-10-20', '2027-10-19', true]);
  assert.equal(out.capEntries.find((e) => e.id === F.CAP.parent).approximate, false);
});

test('milestones: welcome window from the anchor date; per-milestone and card exclusions', () => {
  const v2 = v2card();
  const inWindow = cardStateV2.milestoneEntries(v2, cardStateV2.transactionContext(dining('2026-12-29', 1000)));
  assert.deepEqual(inWindow.map((e) => [e.id, e.start, e.end, e.delta]), [
    [F.MILESTONE.welcome, '2026-10-01', '2026-12-29', 1000],
    [F.MILESTONE.annual, '2026-01-01', '2026-12-31', 1000],
  ]);
  const afterWindow = cardStateV2.milestoneEntries(v2, cardStateV2.transactionContext(dining('2026-12-30', 1000)));
  assert.deepEqual(afterWindow.map((e) => e.id), [F.MILESTONE.annual]);
  const rent = cardStateV2.milestoneEntries(v2, cardStateV2.transactionContext(txn('2026-11-10', 9000, { category_id: F.CATEGORY.rent })));
  assert.deepEqual(rent.map((e) => e.id), [F.MILESTONE.welcome]);
  const excludedCard = v2card({ excluded_categories: [F.CATEGORY.rent] });
  assert.deepEqual(cardStateV2.milestoneEntries(excludedCard, cardStateV2.transactionContext(txn('2026-11-10', 9000, { category_id: F.CATEGORY.rent }))), []);
});

test('C8 D22a: an excluded spend makes no milestone progress (exclusion rule, minimum amount, card category)', () => {
  const v2 = v2card({ excluded_categories: [F.CATEGORY.rent] });
  const outcomeOf = (row) => cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(row), () => 0);
  const cases = {
    wallet: txn('2026-11-10', 500, { category_id: F.CATEGORY.wallet }),
    minimum: dining('2026-11-10', 99),
    cardCategory: txn('2026-11-10', 9000, { category_id: F.CATEGORY.rent }),
  };
  for (const [name, row] of Object.entries(cases)) {
    const out = outcomeOf(row);
    assert.equal(out.excluded, true, name);
    assert.deepEqual(cardStateV2.milestoneEntries(v2, cardStateV2.transactionContext(row), { excluded: out.excluded }), [], name);
  }
  // ₹100 is not below the minimum: it earns and qualifies.
  const hundred = dining('2026-11-10', 100);
  const out = outcomeOf(hundred);
  assert.equal(out.excluded, false);
  assert.equal(cardStateV2.milestoneEntries(v2, cardStateV2.transactionContext(hundred), { excluded: out.excluded }).length, 2);
  // The replay applies the same test.
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-20T12:00:00Z'), milestones: true });
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [...Object.values(cases), hundred] });
  assert.deepEqual(plan.milestoneRows.map((r) => r.qualified_spend), [100, 100]);
});

test('C8 D22b: welcome windows count from opened_on even when anniversary_on differs', () => {
  const v2 = v2card({ opened_on: '2026-10-01', anniversary_on: '2026-12-15' });
  const ctx = cardStateV2.transactionContext(dining('2026-11-03', 2000));
  const welcome = cardStateV2.milestoneEntries(v2, ctx).find((e) => e.id === F.MILESTONE.welcome);
  assert.deepEqual([welcome.start, welcome.end, welcome.approximate], ['2026-10-01', '2026-12-29', false]);
  const cardYear = cardStateV2.computeTransactionV2(v2, directory, ctx, () => 0).capEntries.find((e) => e.id === F.CAP.cardYear);
  assert.deepEqual([cardYear.start, cardYear.end], ['2025-12-15', '2026-12-14']); // card year from anniversary_on
  const fromCreated = v2card({ opened_on: null, anniversary_on: null });
  const w = cardStateV2.milestoneEntries(fromCreated, ctx).find((e) => e.id === F.MILESTONE.welcome);
  assert.deepEqual([w.start, w.approximate], ['2026-10-20', true]);
});

test('C8 D23c: a spend at 03:00 IST on 1 Dec counts in December', () => {
  const v2 = v2card();
  const late = txn('2026-11-30', 2000, { category_id: F.CATEGORY.dining, occurred_at: new Date('2026-11-30T21:30:00Z') });
  const out = cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(late), () => 0);
  assert.deepEqual(out.capEntries.find((e) => e.id === F.CAP.parent).start, '2026-12-01');
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-12-10T06:00:00Z'), caps: true });
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [late] });
  assert.equal(plan.capRows.find((r) => r.cap_rule_id === F.CAP.parent).period_start, '2026-12-01');
  assert.equal(plan.capRows.find((r) => r.cap_rule_id === F.CAP.parent).consumed, 100);
});

test('C8 D23b: statement-cycle caps on day 31 and day 1 give one row per period and a bounded rebuild', () => {
  for (const statementDay of [1, 31]) {
    const caps = F.CAPS.map((c) => (c.period === 'calendar_month' ? { ...c, period: 'statement_cycle' } : c));
    const v2 = cardStateV2.buildV2Card({ userCard: F.userCardRow({ statement_day: statementDay }), rules: F.RULES, caps, milestones: [] });
    const rows = [dining('2026-11-01', 2000), dining('2026-11-30', 2000), dining('2026-12-01', 2000)];
    const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-12-01T06:00:00Z'), caps: true });
    const plan = cardStateV2.planReplay({ v2, directory, range, transactions: rows });
    const parents = plan.capRows.filter((r) => r.cap_rule_id === F.CAP.parent);
    const starts = new Set(parents.map((r) => r.period_start));
    assert.equal(starts.size, parents.length, `day ${statementDay}: one row per period`);
    for (let i = 1; i < parents.length; i += 1) assert.ok(parents[i - 1].period_end < parents[i].period_start);
    assert.equal(parents.reduce((s, r) => s + r.consumed, 0), 300, `day ${statementDay}: every spend counted once`);
  }
});

test('C8 D23f: lifetime caps rebuild from the card floor, not 1970', () => {
  const caps = [...F.CAPS, {
    id: '00000000-0000-4000-8000-0000000000c9', reward_rule_id: null, category_id: null, label: 'lifetime',
    measure: 'reward_value', period: 'lifetime', cap_value: '1000', cap_kind: 'total_points', cap_amount: '4000',
    scope: 'card', parent_cap_id: null, post_cap_behavior: null, post_cap_rate: '0', anchor: null, targets: [],
  }];
  const v2 = cardStateV2.buildV2Card({ userCard: F.userCardRow(), rules: F.RULES, caps, milestones: F.MILESTONES });
  const asOf = new Date('2026-11-20T12:00:00Z');
  assert.ok(cardStateV2.rebuildRange(v2, { asOf, caps: true }).loadFrom < '1971-01-01', 'without a floor: all history');
  const range = cardStateV2.rebuildRange(v2, { asOf, caps: true, floor: '2026-10-01' });
  assert.deepEqual([range.caps.start, range.caps.seedFrom, range.loadFrom], ['2026-10-01', '2026-10-01', '2026-10-01']);
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [dining('2026-10-05', 2000), dining('2026-11-03', 2000)] });
  const lifetime = plan.capRows.find((r) => r.cap_rule_id === '00000000-0000-4000-8000-0000000000c9');
  assert.deepEqual([lifetime.period_start, lifetime.consumed], ['1970-01-01', 200]);
});

test('a points+cashback card: cashback goes to expected_cashback_inr only, never the points ledger', () => {
  const rules = [...F.RULES, {
    ...F.RULES[0], id: '00000000-0000-4000-8000-0000000000a9', category_id: F.CATEGORY.other,
    unit: 'cashback_percent', rate: '5.0000', display_note: '5% cashback on other',
  }];
  const v2 = cardStateV2.buildV2Card({ userCard: F.userCardRow(), rules, caps: [], milestones: [] });
  const out = cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(
    txn('2026-11-10', 1000, { category_id: F.CATEGORY.other })), () => 0);
  assert.deepEqual([out.native, out.points, out.cashback, out.value], [0, 0, 50, 50]);
  assert.deepEqual(cardStateV2.ledgerRows(out), []);
  const pointsCard = cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(dining('2026-11-10', 1000)), () => 0);
  assert.deepEqual([pointsCard.native, pointsCard.points, pointsCard.cashback], [50, 50, null]);
  assert.deepEqual(cardStateV2.ledgerRows({ native: 120, points: 120, cashback: 30 }), [
    { reason: 'points earned on transaction', delta: 120 },
  ]);
  // A cashback-only card keeps v1's behaviour: ₹ under the points reason.
  assert.deepEqual(cardStateV2.ledgerRows({ native: 49.5, points: null, cashback: 49.5 }), [
    { reason: 'points earned on transaction', delta: 49.5 },
  ]);
});

test('replay rebuilds rows equal to sequential recording, and writes each transaction its record', () => {
  const v2 = v2card();
  const rows = [dining('2026-11-03', 2000), swiggy('2026-11-04', 30000), dining('2026-11-05', 30000), swiggy('2026-11-06', 1000)];
  const { table } = recordSequentially(v2, rows);
  const asOf = new Date('2026-11-20T12:00:00Z');
  const range = cardStateV2.rebuildRange(v2, { asOf, caps: true, milestones: true, expected: true });
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: rows, expected: true });
  const rowsByKey = Object.fromEntries(plan.capRows.map((r) => [`${r.cap_rule_id}|${r.period_start}`, r.consumed]));
  for (const [key, consumed] of table) assert.equal(rowsByKey[key], consumed, key);
  assert.equal(plan.capRows.length, table.size);
  const parent = plan.capRows.find((r) => r.cap_rule_id === F.CAP.parent);
  assert.deepEqual([parent.cap_kind, parent.cap_amount, parent.period_end, parent.approximate_window], ['total_points', 2500, '2026-11-30', false]);
  assert.equal(plan.txnRecordUpdates.length, 4);
  assert.deepEqual(plan.txnExpectedUpdates.map((u) => u.native), [100, 2100, 300, 0]);
  const welcome = plan.milestoneRows.find((r) => r.milestone_rule_id === F.MILESTONE.welcome);
  assert.deepEqual([welcome.period_start, welcome.period_end, welcome.qualified_spend], ['2026-10-01', '2026-12-29', 63000]);
});

test('replay is idempotent: once records and expected values match, it plans no transaction writes', () => {
  const v2 = v2card();
  const rows = [dining('2026-11-03', 2000), swiggy('2026-11-04', 30000)];
  const asOf = new Date('2026-11-20T12:00:00Z');
  const range = cardStateV2.rebuildRange(v2, { asOf, caps: true, milestones: true, expected: true });
  const first = cardStateV2.planReplay({ v2, directory, range, transactions: rows, expected: true });
  const recorded = rows.map((r) => {
    const rec = first.txnRecordUpdates.find((u) => u.id === r.id);
    const exp = first.txnExpectedUpdates.find((u) => u.id === r.id);
    return { ...r, card_state_v2: rec.record, expected_points: String(exp.native), expected_value_inr: String(exp.value) };
  });
  const existingCapRows = first.capRows.map((r) => ({ ...r, consumed: String(r.consumed), cap_amount: String(r.cap_amount) }));
  const existingMilestoneRows = first.milestoneRows.map((r) => ({ ...r, qualified_spend: String(r.qualified_spend) }));
  const second = cardStateV2.planReplay({
    v2, directory, range, transactions: recorded, expected: true, existingCapRows, existingMilestoneRows,
  });
  assert.deepEqual(second.txnRecordUpdates, []);
  assert.deepEqual(second.txnExpectedUpdates, []);
  assert.deepEqual(second.diff, { caps: [], milestones: [], transactions: [] });
});

test('the replay window reaches back to the start of every current period', () => {
  // Card year from 2026-10-01; monthly caps in November → the replay starts
  // at the card year, so October spends are replayed, not guessed.
  const v2 = v2card();
  const oct = dining('2026-10-15', 4000);
  const nov = dining('2026-11-03', 2000);
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-20T12:00:00Z'), caps: true });
  assert.deepEqual([range.caps.start, range.caps.end], ['2026-10-01', '2027-09-30']);
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [oct, nov] });
  assert.equal(plan.capRows.find((r) => r.cap_rule_id === F.CAP.cardYear).consumed, 300); // 200 + 100
  assert.equal(plan.capRows.find((r) => r.cap_rule_id === F.CAP.parent && r.period_start === '2026-10-01').consumed, 200);
});

test('replay seeds a period that starts before the window from the stored records', () => {
  // Card year from 2026-10-15, so the replay starts there; October's monthly
  // caps began on 2026-10-01. A spend on 2026-10-05 is not replayed: its
  // stored record seeds October's rows, and the 2026-10-20 spend is priced
  // against that seed (the bonus cap is already used up).
  const v2 = v2card({ opened_on: '2026-10-15' });
  const early = dining('2026-10-05', 30000);
  const earlyOut = cardStateV2.computeTransactionV2(v2, directory, cardStateV2.transactionContext(early), () => 0);
  early.card_state_v2 = cardStateV2.toRecord(v2.userCardId, { caps: earlyOut.capEntries });
  const later = dining('2026-10-20', 2000);
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-20T12:00:00Z'), caps: true, expected: true });
  assert.deepEqual([range.caps.start, range.caps.seedFrom], ['2026-10-15', '2026-10-01']);
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [early, later], expected: true });
  const row = (id, start) => plan.capRows.find((r) => r.cap_rule_id === id && r.period_start === start);
  assert.equal(row(F.CAP.bonus, '2026-10-01').consumed, 1000); // the seed alone
  assert.equal(row(F.CAP.parent, '2026-10-01').consumed, 1300 + 20);
  assert.equal(row(F.CAP.cardYear, '2026-10-15').consumed, 20);
  // The previous card year's row is outside the rebuild; early's record keeps it.
  assert.equal(row(F.CAP.cardYear, '2025-10-15'), undefined);
  assert.deepEqual(plan.txnRecordUpdates.map((u) => u.id), [later.id]);
  assert.deepEqual(plan.txnExpectedUpdates.map((u) => [u.id, u.native]), [[later.id, 20]]);
});

test('a transaction excluded from the replay contributes nothing and keeps its record untouched', () => {
  const v2 = v2card();
  const a = dining('2026-11-03', 2000);
  const b = dining('2026-11-04', 2000);
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-20T12:00:00Z'), caps: true });
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [a, b], excludeTxnIds: [b.id] });
  assert.equal(plan.capRows.find((r) => r.cap_rule_id === F.CAP.bonus).consumed, 80);
  assert.deepEqual(plan.txnRecordUpdates.map((u) => u.id), [a.id]);
});

test('an inactive transaction that still carries a record loses the rebuilt entries', () => {
  const v2 = v2card();
  const stale = dining('2026-11-03', 2000);
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-20T12:00:00Z'), caps: true });
  const applied = cardStateV2.planReplay({ v2, directory, range, transactions: [stale] });
  const ignored = { ...stale, status: 'ignored', card_state_v2: applied.txnRecordUpdates[0].record };
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [ignored] });
  assert.deepEqual(plan.capRows, []);
  assert.deepEqual(plan.txnRecordUpdates, [{ id: stale.id, record: null }]);
});

test('records keep entries for periods the replay did not rebuild', () => {
  const v2 = v2card();
  const t = dining('2026-11-03', 2000);
  const range = cardStateV2.rebuildRange(v2, { asOf: new Date('2026-11-20T12:00:00Z'), caps: true });
  const foreign = { id: '00000000-0000-4000-8000-00000000ffff', kind: 'total_points', start: '2025-01-01', end: '2025-12-31', delta: 7 };
  const withForeign = { ...t, card_state_v2: { v: 1, user_card_id: v2.userCardId, caps: [foreign], fee_waivers: [{ id: 'fw', start: '2026-01-01', end: '2026-12-31', delta: 2000 }] } };
  const plan = cardStateV2.planReplay({ v2, directory, range, transactions: [withForeign] });
  const record = plan.txnRecordUpdates[0].record;
  assert.ok(record.caps.some((e) => e.id === foreign.id));
  assert.deepEqual(record.fee_waivers, withForeign.card_state_v2.fee_waivers);
});

test('C8 D23d: every route that changes a transaction takes the ingest lock before its row locks and state writes', () => {
  const source = require('node:fs').readFileSync(require('node:path').join(__dirname, '../src/index.js'), 'utf8');
  // [where the code starts, markers that must all come after the ingest lock]
  const sites = [
    ["app.patch('/transactions/:id', ", ['FOR UPDATE', 'reverseTransactionState(']],
    ["app.post('/transactions/:id/ignore'", ['FOR UPDATE', 'reverseTransactionState(']],
    ["app.post('/transactions/:id/restore'", ['FOR UPDATE', 'applyTransactionState(']],
    ["app.post('/sync/push'", ['applyTransactionSync(client']],
    ["app.post('/duplicate-candidates/:id/resolve'", ["'duplicate-review:'", 'FOR UPDATE', 'reverseTransactionState(']],
    ["app.post('/transactions/category-bulk-apply'", ['transaction-category-bulk:', 'FOR UPDATE', 'reverseTransactionState(']],
    ['async function reconcileArchivedCardReferences(client, userId)', ['UPDATE transactions', 'DELETE FROM ${table}', 'reconcileCurrentCapStates(']],
    ['async function repairSmsHistory(client, userId', ['reconcileArchivedCardReferences(client', 'FOR UPDATE', 'reverseTransactionState(']],
  ];
  for (const [site, laterMarkers] of sites) {
    const start = source.indexOf(site);
    assert.ok(start >= 0, site);
    const lock = Math.min(...['`transaction-ingest:${req.userId}`', '`transaction-ingest:${userId}`']
      .map((m) => source.indexOf(m, start)).filter((i) => i > start));
    for (const marker of laterMarkers) {
      const at = source.indexOf(marker, start);
      assert.ok(at > start, `${site}: ${marker} present`);
      assert.ok(lock < at, `${site}: ingest lock before ${marker}`);
    }
  }
});

test('recompute_card_state: dry run by default; options are validated', () => {
  const { parseArgs } = require('../scripts/recompute_card_state');
  assert.equal(parseArgs([]).apply, false);
  assert.equal(parseArgs(['--dry-run']).apply, false);
  assert.deepEqual(
    parseArgs(['--apply', '--as-of', '2026-11-20', '--since', '2026-10-01', '--card-slug', 'x', '--verbose']),
    { apply: true, asOf: '2026-11-20', since: '2026-10-01', cardSlug: 'x', userCardId: null, verbose: true },
  );
  assert.throws(() => parseArgs(['--as-of', '20-11-2026']), /YYYY-MM-DD/);
  assert.throws(() => parseArgs(['--user-card', 'nope']), /uuid/);
  assert.throws(() => parseArgs(['--card-slug']), /needs a value/);
  assert.throws(() => parseArgs(['--write']), /unknown argument/);
});

test('nativeAmount: points on a points card, rupees of cashback on a cashback card', () => {
  assert.equal(cardStateV2.nativeAmount({ points: 120, cashbackInr: null }), 120);
  assert.equal(cardStateV2.nativeAmount({ points: null, cashbackInr: 49.5 }), 49.5);
  assert.equal(cardStateV2.nativeAmount({ points: null, cashbackInr: null }), 0);
});

test('capNativeAmount: legacy caps convert like the engine (reward value on points → value / point value)', () => {
  const card = { point_value_inr: '0.25' };
  assert.equal(cardStateV2.capNativeAmount({ cap_kind: 'bonus_points', cap_amount: '1500' }, 'bonus_points', card), 1500);
  assert.equal(cardStateV2.capNativeAmount({ cap_kind: null, measure: 'reward_value', cap_value: '500' }, 'total_points', card), 2000);
  assert.equal(cardStateV2.capNativeAmount({ cap_kind: null, measure: 'reward_value', cap_value: '500' }, 'total_cashback', card), 500);
  assert.equal(cardStateV2.capNativeAmount({ cap_kind: null, measure: 'spend_amount', cap_value: '20000' }, 'eligible_spend', card), 20000);
});
