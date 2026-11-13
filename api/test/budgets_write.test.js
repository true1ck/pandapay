'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createBudgetPostHandler, createBudgetDeleteHandler } = require('../src/budgets_write');

const ID1 = '11111111-1111-4111-8111-111111111111';
const ID2 = '22222222-2222-4222-8222-222222222222';
const ID3 = '33333333-3333-4333-8333-333333333333';
const TAG = '44444444-4444-4444-8444-444444444444';
const ms = (v) => new Date(v).getTime();

// Tiny stateful fake of the budgets table, keyed on the SQL the handler emits.
function fixture({ tags = [] } = {}) {
  const rows = [];
  let seq = 0;
  const client = { query: async (rawSql, p) => {
    const sql = rawSql.replace(/\s+/g, ' ').trim();
    if (/pg_advisory_xact_lock/.test(sql)) return { rows: [] };
    if (/FROM transaction_tags/.test(sql)) return { rows: tags.includes(p[0]) ? [{ id: p[0] }] : [] };
    if (/^SELECT id, scope.* WHERE id = \$1 AND profile_id/.test(sql)) return { rows: rows.filter((r) => r.id === p[0]) };
    if (/^SELECT 1 FROM budgets/.test(sql)) {
      const hit = rows.some((r) => r.scope === p[1] && r.period === p[2] && (r.scope_ref_id ?? null) === p[3] && r.client_edited_at && r.client_edited_at > ms(p[4]));
      return { rows: hit ? [{ one: 1 }] : [] };
    }
    if (/SET is_active = false, client_edited_at/.test(sql)) {
      const r = rows.find((x) => x.id === p[0] && x.is_active);
      if (!r) return { rows: [] };
      r.is_active = false; if (p[2]) r.client_edited_at = ms(p[2]);
      return { rows: [{ id: r.id }] };
    }
    if (/AS newer FROM budgets/.test(sql)) {
      const r = rows.find((x) => x.id === p[0] && x.is_active);
      return { rows: r ? [{ newer: !!r.client_edited_at && r.client_edited_at > ms(p[2]) }] : [] };
    }
    if (/^UPDATE budgets SET is_active = false WHERE profile_id/.test(sql)) {
      rows.filter((r) => r.is_active && r.scope === p[1] && r.period === p[2] && (r.scope_ref_id ?? null) === p[3]).forEach((r) => { r.is_active = false; });
      return { rows: [] };
    }
    if (/^INSERT INTO budgets/.test(sql)) {
      if (p[8] && rows.some((r) => r.is_active && r.scope === p[2] && r.period === p[4] && (r.scope_ref_id ?? null) === p[3])) throw Object.assign(new Error('x'), { code: '23505' });
      const r = { id: p[0] || `gen-${++seq}`, scope: p[2], scope_ref_id: p[3], period: p[4], amount_inr: String(p[5]), starts_on: 'd', rollover: p[7] ?? false, is_active: p[8], client_edited_at: p[9] ? ms(p[9]) : null };
      rows.push(r);
      return { rows: [{ id: r.id, scope: r.scope, scope_ref_id: r.scope_ref_id, period: r.period, amount_inr: r.amount_inr, starts_on: r.starts_on, rollover: r.rollover, is_active: r.is_active }] };
    }
    throw new Error(`unexpected sql ${sql}`);
  } };
  const withUserClient = async (_u, fn) => fn(client);
  const scopes = ['overall', 'category', 'card', 'tag']; const periods = ['weekly', 'monthly', 'quarterly', 'yearly'];
  return {
    rows,
    post: createBudgetPostHandler({ withUserClient, BUDGET_SCOPES: scopes, BUDGET_PERIODS: periods }),
    del: createBudgetDeleteHandler({ withUserClient }),
  };
}
function res() { return { code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } }; }
const post = async (f, body) => { const r = res(); await f.post({ userId: 'u', body }, r); return r; };
const del = async (f, id, header) => { const r = res(); await f.del({ userId: 'u', params: { id }, get: () => header }, r); return r; };

test('no new fields: 201 {budget}, replaces the active budget', async () => {
  const f = fixture();
  const a = await post(f, { scope: 'overall', period: 'monthly', amountInr: 100 });
  assert.equal(a.code, 201); assert.deepEqual(Object.keys(a.body), ['budget']);
  await post(f, { scope: 'overall', period: 'monthly', amountInr: 200 });
  assert.equal(f.rows.filter((r) => r.is_active).length, 1);
  assert.equal(f.rows.length, 2);
});

test('same id replays with 200 replayed:true and does not duplicate', async () => {
  const f = fixture();
  await post(f, { id: ID1, scope: 'overall', period: 'monthly', amountInr: 100, clientEditedAt: '2026-11-01T10:00:00Z' });
  const r = await post(f, { id: ID1, scope: 'overall', period: 'monthly', amountInr: 100, clientEditedAt: '2026-11-01T10:00:00Z' });
  assert.equal(r.code, 200); assert.equal(r.body.replayed, true); assert.equal(f.rows.length, 1);
});

test('older edit is stored as inactive history and never deactivates the newer budget', async () => {
  const f = fixture();
  await post(f, { id: ID1, scope: 'overall', period: 'monthly', amountInr: 300, clientEditedAt: '2026-11-02T10:00:00Z' });
  const r = await post(f, { id: ID2, scope: 'overall', period: 'monthly', amountInr: 100, clientEditedAt: '2026-11-01T10:00:00Z' });
  assert.equal(r.code, 200); assert.equal(r.body.superseded, true); assert.equal(r.body.budget.is_active, false);
  assert.equal(f.rows.find((x) => x.id === ID1).is_active, true);
});

test('newer edit replaces the older active budget', async () => {
  const f = fixture();
  await post(f, { id: ID1, scope: 'overall', period: 'monthly', amountInr: 100, clientEditedAt: '2026-11-01T10:00:00Z' });
  const r = await post(f, { id: ID2, scope: 'overall', period: 'monthly', amountInr: 200, clientEditedAt: '2026-11-02T10:00:00Z' });
  assert.equal(r.code, 201);
  assert.equal(f.rows.find((x) => x.id === ID1).is_active, false);
  assert.equal(f.rows.find((x) => x.id === ID2).is_active, true);
});

test('unknown tag answers 422 tag_unknown; known tag works', async () => {
  const f = fixture({ tags: [TAG] });
  const bad = await post(f, { scope: 'tag', scopeRefId: ID3, period: 'monthly', amountInr: 5 });
  assert.equal(bad.code, 422); assert.deepEqual(bad.body, { error: 'tag_unknown' });
  assert.equal((await post(f, { scope: 'tag', scopeRefId: TAG, period: 'monthly', amountInr: 5 })).code, 201);
});

test('validation: bad id and bad clock are 400', async () => {
  const f = fixture();
  assert.equal((await post(f, { id: 'v2:abc', scope: 'overall', period: 'monthly', amountInr: 1 })).code, 400);
  assert.equal((await post(f, { scope: 'overall', period: 'monthly', amountInr: 1, clientEditedAt: 'yesterday' })).code, 400);
  assert.equal((await post(f, { scope: 'bogus', period: 'monthly', amountInr: 1 })).code, 400);
});

test('delete: no header deletes as before, second delete is 404', async () => {
  const f = fixture();
  await post(f, { id: ID1, scope: 'overall', period: 'monthly', amountInr: 1 });
  assert.deepEqual((await del(f, ID1)).body, { ok: true });
  assert.equal((await del(f, ID1)).code, 404);
  assert.equal((await del(f, 'projection:x')).code, 400);
});

test('delete with an older X-Client-Edited-At does not delete a newer budget', async () => {
  const f = fixture();
  await post(f, { id: ID1, scope: 'overall', period: 'monthly', amountInr: 1, clientEditedAt: '2026-11-02T10:00:00Z' });
  const r = await del(f, ID1, '2026-11-01T10:00:00Z');
  assert.equal(r.code, 200); assert.deepEqual(r.body, { superseded: true });
  assert.equal(f.rows[0].is_active, true);
  assert.deepEqual((await del(f, ID1, '2026-11-03T10:00:00Z')).body, { ok: true });
});

test('a stale POST after a newer delete does not resurrect the budget', async () => {
  const f = fixture();
  await post(f, { id: ID1, scope: 'overall', period: 'monthly', amountInr: 1, clientEditedAt: '2026-11-01T10:00:00Z' });
  await del(f, ID1, '2026-11-03T10:00:00Z');
  const r = await post(f, { id: ID2, scope: 'overall', period: 'monthly', amountInr: 9, clientEditedAt: '2026-11-02T10:00:00Z' });
  assert.equal(r.body.superseded, true);
  assert.equal(f.rows.filter((x) => x.is_active).length, 0);
});
