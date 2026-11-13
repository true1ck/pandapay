'use strict';
// Instant expenses switch. Real PostgreSQL only (see the money-harness header):
// set PANDAPAY_WORST_MONEY_PG_URL to a loopback superuser URL.
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { SKIP, createFixture } = require('./shared_expenses_worst_money_common.test.js');

describe('instant expenses: off by default; on, an expense counts at once and stays editable', { skip: SKIP, timeout: 240000 }, () => {
  let F;
  before(async () => { F = await createFixture('instant'); });
  after(async () => { if (F) await F.close(); });
  const setFlag = value => F.q('UPDATE shared_expenses.settings SET instant_expenses=$1 WHERE singleton', [value]);
  const dinner = g => ({ total: 3000, paid: { [g.m[0]]: 3000 }, shares: { [g.m[0]]: 1000, [g.m[1]]: 1000, [g.m[2]]: 1000 } });

  it('off (the shipped default): a three-way expense still waits for everyone', async () => {
    const g = await F.group(3);
    const r = await F.propose(g.p[0], g.ctx, dinner(g));
    assert.equal(r.status, 'awaiting_approval');
    assert.deepEqual(await F.balances(g.ctx), {});
  });

  it('on: the same expense is accepted at once, balances move and every invariant holds', async () => {
    await setFlag(true);
    try {
      const g = await F.group(3);
      const r = await F.propose(g.p[0], g.ctx, dinner(g));
      assert.equal(r.status, 'accepted');
      assert.deepEqual(await F.balances(g.ctx), { [g.m[0]]: 2000n, [g.m[1]]: -1000n, [g.m[2]]: -1000n });
      assert.deepEqual(await F.invariants(g.ctx), []);
    } finally { await setFlag(false); }
  });

  it('on: any member can remove it, and balances return to zero with the history kept', async () => {
    await setFlag(true);
    try {
      const g = await F.group(3);
      const r = await F.propose(g.p[0], g.ctx, dinner(g));
      assert.equal(r.status, 'accepted');
      const removed = await F.propose(g.p[1], g.ctx, { expenseId: r.expenseId, head: r.revisionId, void: true });
      assert.equal(removed.status, 'accepted');
      assert.ok(Object.values(await F.balances(g.ctx)).every(v => v === 0n));
      const history = await F.q('SELECT count(*)::int n FROM shared_expenses.expense_revisions WHERE context_id=$1 AND expense_id=$2', [g.ctx, r.expenseId]);
      assert.equal(history[0].n, 2, 'both revisions are kept');
      assert.deepEqual(await F.invariants(g.ctx), []);
    } finally { await setFlag(false); }
  });

  it('switching on does not rewrite an expense that was already waiting', async () => {
    const g = await F.group(3);
    const waiting = await F.propose(g.p[0], g.ctx, dinner(g));
    assert.equal(waiting.status, 'awaiting_approval');
    await setFlag(true);
    try {
      assert.deepEqual(await F.balances(g.ctx), {}, 'still unaccepted');
    } finally { await setFlag(false); }
  });
});
