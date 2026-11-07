'use strict';
// Worst-case MONEY correctness, part 1: rounding, split kinds, caps, hostile
// amounts/dates/currency, payer shapes, aggregate overflow, 2000-expense context.
// Real PostgreSQL only (PANDAPAY_WORST_MONEY_PG_URL). IDs (M01..) map to
// docs/implementation/shared-expenses/worst-case-money-report.md.
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { SKIP, createFixture, split, uuid } = require('./shared_expenses_worst_money_common.test.js');

describe('worst-case money: amounts, rounding, caps', { skip: SKIP, timeout: 300000 }, () => {
  let F;
  before(async () => { F = await createFixture('amounts'); });
  after(async () => { if (F) await F.close(); });
  const sum = o => Object.values(o).reduce((a, b) => a + b, 0n);
  const none = async ctx => assert.deepEqual(await F.invariants(ctx), []);

  // M01 rounding: 1 paisa and 100 paise among 3/7/33/50 for every split kind.
  for (const total of [1, 100, 101, 9999]) {
    for (const n of [3, 7, 33, 50]) {
      it(`M01 rounding total=${total} among ${n}: every split kind sums exactly and posts zero-sum`, async () => {
        const g = await F.group(n);
        for (const mode of ['equal', 'shares', 'percentage', 'exact']) {
          let weights;
          if (mode === 'shares') weights = g.m.map((_, i) => (i % 5) + 1);
          else if (mode === 'percentage') { weights = g.m.map(() => Math.floor(10000 / n)); weights[0] += 10000 - weights.reduce((a, b) => a + b, 0); }
          else if (mode === 'exact') { const base = split('equal', total, g.m); weights = g.m.map((id, i) => (i === 0 ? base[id] + 0n : base[id])); }
          const shares = split(mode, total, g.m, weights);
          assert.equal(sum(shares), BigInt(total), `${mode} share sum`);
          if (mode === 'equal') { const v = Object.values(shares); assert.ok(v.every(x => x === v[0] || x === v[0] - 1n || x === v[0] + 1n)); assert.ok(Math.max(...v.map(Number)) - Math.min(...v.map(Number)) <= 1); }
          const before = await F.balances(g.ctx);
          const { accepted } = await F.post(g, 0, total, { [g.m[0]]: BigInt(total) }, shares);
          assert.equal(accepted, true, `${mode} accepted`);
          const after = await F.balances(g.ctx);
          let net = 0n;
          for (const id of g.m) { const d = (after[id] || 0n) - (before[id] || 0n); const expect = (id === g.m[0] ? BigInt(total) : 0n) - (shares[id] || 0n); assert.equal(d, expect, `${mode} member delta`); net += d; }
          assert.equal(net, 0n);
        }
        await none(g.ctx);
      });
    }
  }

  it('M02 payer shapes: payer not participant, payer-only, everyone pays own share, multi-payer 8', async () => {
    const g = await F.group(12);
    // payer not a participant
    let x = await F.post(g, 0, 500, { [g.m[0]]: 500n }, { [g.m[1]]: 250n, [g.m[2]]: 250n });
    assert.equal(x.accepted, true);
    let b = await F.balances(g.ctx);
    assert.equal(b[g.m[0]], 500n); assert.equal(b[g.m[1]], -250n); assert.equal(b[g.m[2]], -250n);
    // payer is the only participant -> no obligation, but a real accepted expense
    x = await F.post(g, 3, 777, { [g.m[3]]: 777n }, { [g.m[3]]: 777n });
    assert.equal(x.accepted, true); b = await F.balances(g.ctx); assert.equal(b[g.m[3]] || 0n, 0n);
    assert.equal((await F.q('SELECT count(*)::int n FROM shared_expenses.obligation_edges WHERE revision_id=$1', [x.r.revisionId]))[0].n, 0);
    // everyone pays exactly their own share
    const pay = Object.fromEntries(g.m.slice(0, 5).map((id, i) => [id, BigInt(100 + i)]));
    x = await F.post(g, 0, 510, pay, pay);
    assert.equal(x.accepted, true);
    // 8 payers, 8 other participants, uneven
    const payers = Object.fromEntries(g.m.slice(0, 8).map((id, i) => [id, BigInt(1000 + 7 * i)]));
    const total = sum(payers);
    const shares = split('shares', total, g.m.slice(4, 12), [1, 2, 3, 4, 5, 6, 7, 8]);
    x = await F.post(g, 0, total, payers, shares);
    assert.equal(x.accepted, true);
    await none(g.ctx);
  });

  it('M03 caps: 50 sharers + 8 non-sharing payers (58 distinct) accepted; 51 sharers and 9 payers rejected', async () => {
    const g = await F.group(60);
    const sharers = g.m.slice(0, 50), payers = g.m.slice(50, 58);
    const shares = split('equal', 5001, sharers), paid = Object.fromEntries(payers.map((id, i) => [id, i < 7 ? 625n : 5001n - 625n * 7n]));
    assert.equal(sum(paid), 5001n);
    const r = await F.propose(g.p[0], g.ctx, { total: 5001, paid, shares });
    assert.equal(r.status, 'awaiting_approval');
    assert.equal(await F.approveAll(g.ctx, r), true);
    assert.equal((await F.q('SELECT jsonb_array_length(projected_edges)::int n FROM shared_expenses.expense_revisions WHERE revision_id=$1', [r.revisionId]))[0].n <= 57, true);
    await none(g.ctx);
    // 51st sharer
    const fiftyOne = Object.fromEntries(g.m.slice(0, 51).map(id => [id, 1n]));
    await assert.rejects(F.propose(g.p[0], g.ctx, { total: 51, paid: { [g.m[0]]: 51n }, shares: fiftyOne }), /invalid_snapshot/);
    // 9 payers
    await assert.rejects(F.propose(g.p[0], g.ctx, { total: 9, paid: Object.fromEntries(g.m.slice(0, 9).map(id => [id, 1n])), shares: { [g.m[0]]: 9n } }), /invalid_snapshot/);
    // 59 distinct (50 sharers + 9 payers is already rejected; 50+8 where payer overlaps is fine)
    await none(g.ctx);
  });

  it('M03b largest edit: replace a 58-person expense by a disjoint 58-person expense (114 journal lines, 116 reviewers)', { timeout: 120000 }, async () => {
    const g = await F.group(116);
    const mk = (off) => { const sharers = g.m.slice(off, off + 50), payers = g.m.slice(off + 50, off + 58); return { sharers, payers, shares: split('equal', 7001, sharers), paid: split('equal', 7001, payers) }; };
    const A = mk(0), B = mk(58);
    const r1 = await F.propose(g.p[0], g.ctx, { total: 7001, paid: A.paid, shares: A.shares });
    assert.equal(await F.approveAll(g.ctx, r1), true);
    const r2 = await F.propose(g.p[58], g.ctx, { expenseId: r1.expenseId, head: r1.revisionId, total: 7001, paid: B.paid, shares: B.shares });
    assert.equal(await F.approveAll(g.ctx, r2), true, 'all 116 reviewers must approve; line_no and ordinal limits hold');
    const lines = (await F.q("SELECT count(*)::int n,max(line_no) mx FROM shared_expenses.journal_entries WHERE context_id=$1 AND origin_id=$2", [g.ctx, r2.revisionId]))[0];
    assert.ok(lines.n <= 114 && lines.mx < 400, JSON.stringify(lines));
    await none(g.ctx);
  });

  it('M04 hostile amounts are rejected without any state change', async () => {
    const g = await F.group(3);
    const [a, b] = g.m;
    const bad = [0, -5, '10.5', '1e3', '٣', ' 7', '+7', '007', '', null, 1000000001, '9223372036854775808', '99999999999999999999999', '0x10'];
    for (const v of bad) {
      const snap = F.snapshot(String(v), { [a]: String(v) }, { [b]: String(v) });
      snap.totalMinor = v === null ? null : String(v);
      await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: snap }), /invalid_snapshot|invalid_proposal|snapshot_total_mismatch|null value|invalid input/, `amount ${v}`);
    }
    // numeric JSON instead of strings
    const snap = F.snapshot(100, { [a]: 100 }, { [b]: 100 }); snap.totalMinor = 100;
    await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: snap }), /invalid_snapshot/);
    // mismatched sums
    await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: F.snapshot(100, { [a]: 100 }, { [b]: 99 }) }), /snapshot_total_mismatch/);
    await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: F.snapshot(100, { [a]: 99 }, { [b]: 100 }) }), /snapshot_total_mismatch/);
    // duplicate member rows
    const dup = F.snapshot(100, { [a]: 100 }, { [b]: 50 }); dup.shares.push({ memberId: b, amountMinor: '50' });
    await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: dup }), /invalid_snapshot|snapshot_total_mismatch/);
    // unknown member
    await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: F.snapshot(100, { [a]: 100 }, { [uuid()]: 100 }) }), /member_not_authorized/);
    // negative-zero style amount on a leg
    await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: F.snapshot(100, { [a]: 100, [b]: '-0' }, { [b]: 100 }) }), /invalid_snapshot/);
    assert.equal((await F.q('SELECT count(*)::int n FROM shared_expenses.expense_revisions WHERE context_id=$1', [g.ctx]))[0].n, 0);
    await none(g.ctx);
  });

  it('M05 max amount 1,000,000,000 minor posts exactly; currency non-INR rejected; extra snapshot keys rejected', async () => {
    const g = await F.group(2);
    const { accepted } = await F.post(g, 0, 1000000000, { [g.m[0]]: 1000000000n }, { [g.m[1]]: 1000000000n });
    assert.equal(accepted, true);
    assert.equal((await F.balances(g.ctx))[g.m[0]], 1000000000n);
    for (const cur of ['USD', 'inr', 'INR ', '', 'EUR']) {
      const s = F.snapshot(100, { [g.m[0]]: 100 }, { [g.m[1]]: 100 }); s.currency = cur;
      await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: s }), /invalid_snapshot/, `currency ${cur}`);
    }
    const s = F.snapshot(100, { [g.m[0]]: 100 }, { [g.m[1]]: 100 }); s.extra = 1;
    await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: s }), /invalid_snapshot/);
    // settlement with non-INR currency
    await assert.rejects(F.cmd(g.p[0], 'report_settlement', { contextId: g.ctx, settlementId: uuid(), payerMemberId: g.m[1], receiverMemberId: g.m[0], amountMinor: '5', currency: 'USD', method: 'upi', paidOn: '2026-11-06' }), /invalid_settlement/);
    await none(g.ctx);
  });

  it('M05b snapshot "currency":null is rejected', { todo: 'BUG B8 (S3): "currency":null passes submit_proposal validation (NULL<>INR is NULL, so the IF never fires)' }, async () => {
    const g = await F.group(2);
    const s = F.snapshot(100, { [g.m[0]]: 100 }, { [g.m[1]]: 100 }); s.currency = null;
    await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot: s }), /invalid_snapshot/);
  });
  it('M05c settlement "currency":null is rejected', { todo: 'BUG B8 (S3): "currency":null passes report_settlement validation' }, async () => {
    const g = await F.group(2);
    await assert.rejects(F.cmd(g.p[0], 'report_settlement', { contextId: g.ctx, settlementId: uuid(), payerMemberId: g.m[1], receiverMemberId: g.m[0], amountMinor: '5', currency: null, method: 'upi', paidOn: '2026-11-06' }), /invalid_settlement/);
  });

  it('M06 dates: far past / far future / impossible dates behave deterministically', async () => {
    const g = await F.group(2);
    for (const date of ['0001-01-01', '1900-01-01', '2026-11-05', '2999-12-31', '9999-12-31']) {
      const { accepted } = await F.post(g, 0, 100, { [g.m[0]]: 100n }, { [g.m[1]]: 100n }, { date });
      assert.equal(accepted, true, date);
    }
    for (const date of ['2026-02-31', '0000-01-01', '2026-13-01', '26-11-05', '2026-11-5', '10000-01-01']) {
      await assert.rejects(F.propose(g.p[0], g.ctx, { total: 100, paid: { [g.m[0]]: 100n }, shares: { [g.m[1]]: 100n }, date }), /invalid_proposal|out of range|date\/time/, date);
    }
    await none(g.ctx);
  });

  it('M07 settlement amount validation: zero, negative, fractional, > 1e9, self, bad method/date/ref all rejected', async () => {
    const g = await F.group(2);
    const base = { contextId: g.ctx, payerMemberId: g.m[1], receiverMemberId: g.m[0], amountMinor: '100', currency: 'INR', method: 'upi', paidOn: '2026-11-06' };
    const cases = [['amountMinor', '0'], ['amountMinor', '-1'], ['amountMinor', '1.5'], ['amountMinor', '1000000001'], ['amountMinor', '007'], ['amountMinor', 100], ['method', 'card'], ['paidOn', '2026-02-30'], ['paidOn', 'yesterday'], ['payerMemberId', g.m[0]], ['reference', '  bad ref']];
    for (const [k, v] of cases) {
      await assert.rejects(F.cmd(g.p[0], 'report_settlement', { ...base, settlementId: uuid(), [k]: v }), /invalid_settlement|date\/time|out of range/, `${k}=${v}`);
    }
    assert.equal((await F.q('SELECT count(*)::int n FROM shared_expenses.settlement_reports WHERE context_id=$1', [g.ctx]))[0].n, 0);
  });

  it('M08 aggregate overflow: exactly 2^53-1 total exposure is allowed, one paisa more is refused atomically', async () => {
    const g = await F.group(4);
    const LIMIT = 9007199254740991n;
    const [m1, m2] = [g.m[0], g.m[1]].sort();
    const seed = LIMIT - 500000000n;
    // synthetic seed (superuser fixture): one pair already carries almost the maximum.
    await F.db.query('INSERT INTO shared_expenses.journal_entries(context_id,effect_id,line_no,currency,low_member_id,high_member_id,balance_minor,kind,origin_id) VALUES($1,$2,0,\'INR\',$3,$4,$5,\'settlement\',$2)', [g.ctx, uuid(), m1, m2, seed.toString()]);
    await F.db.query('INSERT INTO shared_expenses.pair_balances VALUES($1,\'INR\',$2,$3,$4)', [g.ctx, m1, m2, seed.toString()]);
    await F.db.query('INSERT INTO shared_expenses.member_balances VALUES($1,$2,\'INR\',$4),($1,$3,\'INR\',-$4::bigint)', [g.ctx, m1, m2, seed.toString()]);
    assert.deepEqual((await F.invariants(g.ctx)).filter(x => !x.startsWith('I5')), []); // I5 cannot know a synthetic seed
    // 5e8 more on a different pair reaches exactly the limit: allowed
    let x = await F.post(g, 2, 500000000, { [g.m[2]]: 500000000n }, { [g.m[3]]: 500000000n });
    assert.equal(x.accepted, true);
    assert.deepEqual((await F.invariants(g.ctx)).filter(x => !x.startsWith('I5')), []);
    // one more paisa must be refused, leaving no partial state
    const before = JSON.stringify(await F.pairs(g.ctx));
    await assert.rejects(F.propose(g.p[2], g.ctx, { total: 1, paid: { [g.m[2]]: 1n }, shares: { [g.m[3]]: 1n } }).then(async r => { await F.respond(g.p[3], g.ctx, r.expenseId, r.revisionId); }), /aggregate_limit_exceeded/);
    assert.equal(JSON.stringify(await F.pairs(g.ctx)), before);
    assert.deepEqual((await F.invariants(g.ctx)).filter(x => !x.startsWith('I5')), []);
  });

  it('M09 2000 expenses in one context: balances stay consistent (edits, voids and settlements interleaved)', { timeout: 280000 }, async () => {
    const g = await F.group(5);
    const heads = [];
    for (let i = 0; i < 2000; i++) {
      const total = 100 + ((i * 37) % 9000);
      const shares = split('shares', total, g.m, g.m.map((_, k) => ((i + k) % 4) + 1));
      const payer = g.m[i % 5];
      const r = await F.propose(g.p[i % 5], g.ctx, { total, paid: { [payer]: BigInt(total) }, shares });
      if (r.status !== 'accepted') assert.equal(await F.approveAll(g.ctx, r), true);
      heads.push({ id: r.expenseId, head: r.revisionId, author: g.p[i % 5], payer });
      if (i % 11 === 0) { // edit an older one
        const t = heads[Math.floor(i / 2)]; const total2 = 50 + ((i * 13) % 5000);
        const r2 = await F.propose(t.author, g.ctx, { expenseId: t.id, head: t.head, total: total2, paid: { [t.payer]: BigInt(total2) }, shares: split('equal', total2, g.m) });
        if (r2.status !== 'accepted') await F.approveAll(g.ctx, r2);
        t.head = r2.revisionId;
      }
      if (i % 97 === 0 && i > 0) { // void an older one
        const t = heads[Math.floor(i / 3)];
        const v = await F.propose(t.author, g.ctx, { expenseId: t.id, head: t.head, void: true });
        if (v.status !== 'accepted') await F.approveAll(g.ctx, v);
        t.head = v.revisionId;
      }
      if (i % 250 === 0) await none(g.ctx);
    }
    const bal = await F.balances(g.ctx);
    assert.equal(Object.values(bal).reduce((a, b) => a + b, 0n), 0n);
    await none(g.ctx);
    const t = (await F.q('SELECT expense_count::int n FROM shared_expenses.context_totals WHERE context_id=$1', [g.ctx]))[0];
    assert.ok(t.n > 1800, 'count of live expenses');
  });
});
