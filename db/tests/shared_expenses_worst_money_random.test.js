'use strict';
// Seeded randomized model check (M60): 900+ mixed operations over contexts of
// 2..60 people with 1..8 payers and 1..50 sharers. After EVERY step:
//  * all SQL invariants (journal vs balances vs pairs vs accepted revisions),
//  * an independent in-JS model of the balances (applied only when a call
//    reports an acceptance) equals member_balances,
//  * nothing but snake_case domain errors ever surfaces (a raw PG error such as
//    a constraint/cardinality/deadlock failure is a bug).
// Replay a failure with the printed seed.
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { SKIP, createFixture, rng, split, uuid } = require('./shared_expenses_worst_money_common.test.js');

const TOTALS = [1, 2, 3, 7, 33, 50, 99, 100, 101, 333, 1000, 9999, 10001, 123457, 99999999, 1000000000];

class Sim {
  constructor(F, g, seed, kind) {
    this.F = F; this.g = g; this.kind = kind; this.r = rng(seed); this.seed = seed;
    this.ownerP = g.p[0]; this.people = g.p.map((p, i) => ({ p, m: g.m[i], state: 'active' }));
    this.exps = []; // {id, head, revs:{rev:{paid,share,void}}, pend:[rev]}
    this.bal = new Map(); this.setts = []; this.ops = new Map(); this.unexpected = []; this.names = 0;
  }
  note(k, ok) { const key = `${k}:${ok ? 'ok' : 'rej'}`; this.ops.set(key, (this.ops.get(key) || 0) + 1); }
  active() { return this.people.filter(x => x.state === 'active'); }
  live() { return this.people.filter(x => x.state !== 'left'); }
  pos(rev) { const o = new Map(); if (!rev || rev.void) return o; for (const [m, v] of Object.entries(rev.paid)) o.set(m, (o.get(m) || 0n) + v); for (const [m, v] of Object.entries(rev.share)) o.set(m, (o.get(m) || 0n) - v); return o; }
  applyAccepted(e, revId) {
    if (e.head === revId) return;
    const next = this.pos(e.revs[revId]), prev = this.pos(e.revs[e.head]);
    for (const m of new Set([...next.keys(), ...prev.keys()])) this.bal.set(m, (this.bal.get(m) || 0n) + (next.get(m) || 0n) - (prev.get(m) || 0n));
    e.head = revId;
  }
  async attempt(kind, fn) {
    try { const out = await fn(); this.note(kind, true); return out; } catch (err) {
      const msg = String(err.message || err).split('\n')[0];
      if (!/^[a-z_]+$/.test(msg)) this.unexpected.push(`${kind}: ${msg}`);
      this.note(kind, false); return undefined;
    }
  }
  // ----- random shapes
  sharesFor(total, ids) {
    const mode = this.r.pick(['equal', 'shares', 'percentage', 'exact']);
    let w;
    if (mode === 'shares') w = ids.map(() => this.r.int(0, 9)), w[this.r.int(0, ids.length - 1)] += 1;
    else if (mode === 'percentage') { const k = ids.length; w = ids.map(() => Math.floor(10000 / k)); w[this.r.int(0, k - 1)] += 10000 - w.reduce((a, b) => a + b, 0); }
    else if (mode === 'exact') { const eq = split('equal', total, ids); w = ids.map(id => Number(eq[id])); for (let i = 0; i < 3 && ids.length > 1; i++) { const a = this.r.int(0, ids.length - 1), b = this.r.int(0, ids.length - 1); const mv = Math.min(w[a], this.r.int(0, 5)); if (a !== b) { w[a] -= mv; w[b] += mv; } } }
    return { mode, shares: split(mode, total, ids, w) };
  }
  shuffle(a) { const o = [...a]; for (let i = o.length - 1; i > 0; i--) { const j = this.r.int(0, i); [o[i], o[j]] = [o[j], o[i]]; } return o; }
  shape() {
    const pool = this.live(); if (!pool.length) return null;
    const total = this.r.pick(TOTALS);
    const cap = this.kind === 'direct' ? 2 : 50;
    const k = Math.min(pool.length, this.r.pick([1, 2, 2, 3, 5, 8, 20, 50, cap]), cap);
    const sharers = this.shuffle(pool).slice(0, k).map(x => x.m);
    const np = Math.min(this.r.int(1, 8), pool.length);
    const payers = this.shuffle(pool).slice(0, np).map(x => x.m);
    const { shares } = this.sharesFor(total, sharers);
    const pw = payers.map(() => this.r.int(1, 7));
    const paid = split('shares', total, payers, pw);
    // ~3% of the time smuggle in a departed person to prove it is refused
    const gone = this.people.filter(x => x.state === 'left');
    if (gone.length && this.r() < 0.05 && !(gone[0].m in shares)) { const v = shares[sharers[0]]; if (v > 0n) { shares[sharers[0]] = v - 1n; shares[gone[0].m] = 1n; } }
    return { total, paid, shares };
  }
  async propose(editing, doVoid) {
    const e = editing; const author = this.r.pick(this.active()); if (!author) return;
    const sh = doVoid ? null : this.shape(); if (!doVoid && !sh) return;
    const expenseId = e ? e.id : uuid(), revisionId = uuid();
    const res = await this.attempt(doVoid ? 'void' : e ? 'edit' : 'propose', () => this.F.propose(author.p, this.g.ctx, doVoid ? { expenseId, revisionId, head: e.head, void: true } : { expenseId, revisionId, head: e ? e.head : null, total: sh.total, paid: sh.paid, shares: sh.shares }));
    if (!res) return;
    let ex = e; if (!ex) { ex = { id: expenseId, head: null, revs: {}, pend: [] }; this.exps.push(ex); }
    ex.revs[revisionId] = doVoid ? { void: true, paid: {}, share: {} } : { paid: sh.paid, share: sh.shares, void: false };
    ex.pend.push(revisionId);
    if (res.status === 'accepted') this.applyAccepted(ex, revisionId);
  }
  async approve() {
    const cands = this.exps.flatMap(e => e.pend.map(rev => ({ e, rev }))).filter(x => x.e.head !== x.rev);
    if (!cands.length) return;
    const { e, rev } = this.r.pick(cands);
    const rows = await this.F.q(`SELECT DISTINCT coalesce(rm.approver_profile_id,m.profile_id) p FROM shared_expenses.revision_members rm JOIN shared_expenses.members m ON m.context_id=rm.context_id AND m.member_id=rm.member_id
      WHERE rm.context_id=$1 AND rm.revision_id=$2 AND rm.approval_required AND m.state='active' AND coalesce(rm.approver_profile_id,m.profile_id) IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM shared_expenses.revision_approvals a WHERE a.context_id=rm.context_id AND a.revision_id=rm.revision_id AND a.member_id=rm.member_id)`, [this.g.ctx, rev]);
    // sometimes a stranger/non-approver tries as well
    const who = rows.length && this.r() > 0.04 ? this.r.pick(rows).p : this.r.pick(this.people).p;
    const decision = this.r() < 0.08 ? 'reject' : 'approve';
    const res = await this.attempt(decision, () => this.F.respond(who, this.g.ctx, e.id, rev, decision));
    if (res && res.status === 'accepted') this.applyAccepted(e, rev);
  }
  async approveBurst() { // finish a freshly proposed revision most of the time so the run actually moves money
    const last = this.exps[this.exps.length - 1]; if (!last || !last.pend.length) return;
    const rev = last.pend[last.pend.length - 1]; if (last.head === rev) return;
    const rows = await this.F.q(`SELECT DISTINCT coalesce(rm.approver_profile_id,m.profile_id) p FROM shared_expenses.revision_members rm JOIN shared_expenses.members m ON m.context_id=rm.context_id AND m.member_id=rm.member_id
      WHERE rm.context_id=$1 AND rm.revision_id=$2 AND rm.approval_required AND m.state='active' AND coalesce(rm.approver_profile_id,m.profile_id) IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM shared_expenses.revision_approvals a WHERE a.context_id=rm.context_id AND a.revision_id=rm.revision_id AND a.member_id=rm.member_id)`, [this.g.ctx, rev]);
    for (const row of rows.slice(0, 6)) {
      const res = await this.attempt('approve', () => this.F.respond(row.p, this.g.ctx, last.id, rev, 'approve'));
      if (res && res.status === 'accepted') this.applyAccepted(last, rev);
      if (await this.check(`approve-burst`)) return 'bad';
    }
  }
  async report() {
    const a = this.active(); if (a.length < 2) return;
    const x = this.r.pick(a); let y = this.r.pick(a); if (y === x) return;
    const [l, h] = [x.m, y.m].sort(); const row = (await this.F.q('SELECT balance_minor::text b FROM shared_expenses.pair_balances WHERE context_id=$1 AND low_member_id=$2 AND high_member_id=$3', [this.g.ctx, l, h]))[0];
    const owedToY = row ? BigInt(row.b) * (y.m === l ? 1n : -1n) : 0n; // positive: x owes y
    let amt = owedToY > 0n ? this.r.pick([owedToY, owedToY / 2n + 1n, owedToY + 17n]) : BigInt(this.r.int(1, 5000));
    if (amt < 1n || amt > 1000000000n) amt = 1n;
    const reporter = this.r.pick([x, x, x, y, this.r.pick(a)]);
    const res = await this.attempt('report', () => this.F.report(reporter.p, this.g.ctx, x.m, y.m, amt));
    if (res) this.setts.push({ id: res.settlementId, payer: x, recv: y, amt, done: false });
  }
  async settle() {
    const open = this.setts.filter(s => !s.done); if (!open.length) return;
    const s = this.r.pick(open); const decision = this.r() < 0.8 ? 'confirm' : 'reject';
    const res = await this.attempt('settle-' + decision, () => this.F.settle(this.r() < 0.95 ? s.recv.p : s.payer.p, this.g.ctx, s.id, decision));
    if (res) { s.done = true; if (res.status === 'confirmed') { this.bal.set(s.payer.m, (this.bal.get(s.payer.m) || 0n) + s.amt); this.bal.set(s.recv.m, (this.bal.get(s.recv.m) || 0n) - s.amt); } }
  }
  async leave() {
    const c = this.active().filter(x => x.p !== this.g.p[0]); if (!c.length) return;
    const x = this.r.pick(c); const res = await this.attempt('leave', () => this.F.leave(x.p, this.g.ctx));
    if (res) x.state = 'left';
  }
  async settleUpThenLeave() {
    const c = this.active().filter(x => x.p !== this.ownerP); if (!c.length) return;
    const x = this.r.pick(c);
    const rows = await this.F.q('SELECT low_member_id l,high_member_id h,balance_minor::text b FROM shared_expenses.pair_balances WHERE context_id=$1 AND (low_member_id=$2 OR high_member_id=$2)', [this.g.ctx, x.m]);
    for (const row of rows) {
      const other = this.people.find(y => y.m === (row.l === x.m ? row.h : row.l)); if (!other || other.state !== 'active') continue;
      const xOwes = (row.l === x.m) ? BigInt(row.b) < 0n : BigInt(row.b) > 0n; const amt = BigInt(row.b) < 0n ? -BigInt(row.b) : BigInt(row.b);
      const [payer, recv] = xOwes ? [x, other] : [other, x];
      const res = await this.attempt('tidy-report', () => this.F.report(payer.p, this.g.ctx, payer.m, recv.m, amt));
      if (!res) continue;
      const done = await this.attempt('tidy-confirm', () => this.F.settle(recv.p, this.g.ctx, res.settlementId, 'confirm'));
      if (done) { this.bal.set(payer.m, (this.bal.get(payer.m) || 0n) + amt); this.bal.set(recv.m, (this.bal.get(recv.m) || 0n) - amt); }
    }
    const res = await this.attempt('tidy-leave', () => this.F.leave(x.p, this.g.ctx));
    if (res) x.state = 'left';
  }
  async join() {
    const [p] = await this.F.profiles(1, 'j');
    if (this.r() < 0.5) {
      const res = await this.attempt('join', () => this.F.join(this.ownerP || this.g.p[0], this.g.ctx, p, 'j' + (++this.names) + '-' + this.g.ctx.slice(0, 3)));
      if (res) this.people.push({ p, m: res, state: 'active' });
    } else {
      const res = await this.attempt('invite-name', () => this.F.nameOnly(this.ownerP || this.g.p[0], this.g.ctx, 'ghost' + (++this.names) + '-' + this.g.ctx.slice(0, 3)));
      if (res) this.people.push({ p: null, m: res, state: 'name' });
    }
  }
  async bind() {
    const gs = this.people.filter(x => x.state === 'name'); if (!gs.length) return;
    const x = this.r.pick(gs); const [p] = await this.F.profiles(1, 'late');
    const res = await this.attempt('bind', () => this.F.bindLate(this.ownerP || this.g.p[0], this.g.ctx, x.m, p));
    if (res && res.status === 'joined') { x.p = p; x.state = 'active'; }
  }
  async rename() {
    const x = this.r.pick(this.live()); const who = this.r() < 0.7 ? (this.ownerP || this.g.p[0]) : (x.p || this.g.p[0]);
    await this.attempt('rename', () => this.F.cmd(who, 'rename_member', { contextId: this.g.ctx, memberId: x.m, displayName: 'N' + (++this.names) + this.g.ctx.slice(0, 3) }));
  }
  async transfer() {
    const to = this.r.pick(this.active()); const from = this.ownerP || this.g.p[0];
    const res = await this.attempt('transfer', () => this.F.cmd(from, 'transfer_owner', this.g.ctx, to.m));
    if (res) this.ownerP = to.p;
  }
  async remove() {
    const gs = this.people.filter(x => x.state === 'name'); if (!gs.length) return;
    const x = this.r.pick(gs); const res = await this.attempt('remove', () => this.F.cmd(this.ownerP || this.g.p[0], 'remove_member', this.g.ctx, x.m));
    if (res) x.state = 'left';
  }
  async check(label) {
    const bad = await this.F.invariants(this.g.ctx);
    const db = await this.F.balances(this.g.ctx);
    const keys = new Set([...Object.keys(db), ...this.bal.keys()]);
    for (const k of keys) if ((db[k] || 0n) !== (this.bal.get(k) || 0n)) bad.push(`MODEL ${label}: member ${k.slice(0, 8)} db=${db[k] || 0n} model=${this.bal.get(k) || 0n}`);
    if (bad.length) { this.failure = `seed=${this.seed} kind=${this.kind} after ${label}: ${bad.join(' | ')}`; return true; }
    return false;
  }
  async run(n) {
    const weights = [['propose', 26], ['approve', 16], ['edit', 10], ['void', 3], ['report', 9], ['settle', 8], ['leave', 2], ['settleUpThenLeave', 4], ['join', 4], ['bind', 2], ['rename', 2], ['transfer', 1], ['remove', 1]];
    const total = weights.reduce((a, [, w]) => a + w, 0);
    for (let i = 0; i < n; i++) {
      let t = this.r() * total, op; for (const [name, w] of weights) { if ((t -= w) < 0) { op = name; break; } }
      switch (op) {
        case 'propose': await this.propose(null, false); if (this.r() < 0.85 && await this.approveBurst() === 'bad') return; break;
        case 'edit': { const c = this.exps.filter(e => e.head); if (c.length) { await this.propose(this.r.pick(c), false); } break; }
        case 'void': { const c = this.exps.filter(e => e.head); if (c.length) await this.propose(this.r.pick(c), true); break; }
        case 'approve': await this.approve(); break;
        default: await this[op]();
      }
      if (await this.check(`#${i} ${op}`)) return;
    }
  }
}

const RUNS = [
  { kind: 'direct', n: 2, ops: 200, seed: 20261107 },
  { kind: 'group', n: 4, ops: 260, seed: 4242 },
  { kind: 'group', n: 12, ops: 300, seed: 99 },
  { kind: 'group', n: 60, ops: 300, seed: 7 },
];

for (const sd of (process.env.PANDAPAY_WORST_MONEY_EXTRA_SEEDS || '').split(',').filter(Boolean)) RUNS.push({ kind: 'group', n: 3 + (Number(sd) % 14), ops: 250, seed: Number(sd) });

describe('M61 invariant checker has teeth', { skip: SKIP, timeout: 60000 }, () => {
  let F;
  before(async () => { F = await createFixture('teeth'); });
  after(async () => { if (F) await F.close(); });
  it('M61 each class of corruption is detected by the invariants used in M60', async () => {
    const g = await F.group(3);
    const x = await F.post(g, 0, 300, { [g.m[0]]: 300n }, { [g.m[1]]: 150n, [g.m[2]]: 150n });
    assert.equal(x.accepted, true);
    assert.deepEqual(await F.invariants(g.ctx), []);
    const corrupt = async (sql, params, pattern) => {
      await F.db.query('BEGIN'); await F.db.query('SET LOCAL session_replication_role=replica'); await F.db.query(sql, params);
      const bad = await F.invariants(g.ctx); await F.db.query('ROLLBACK');
      assert.ok(bad.some(b => pattern.test(b)), `${sql} -> ${JSON.stringify(bad)}`);
    };
    await corrupt('UPDATE shared_expenses.member_balances SET balance_minor=balance_minor+1 WHERE context_id=$1 AND member_id=$2', [g.ctx, g.m[0]], /I1|I2|I3b|I5/);
    await corrupt('UPDATE shared_expenses.pair_balances SET balance_minor=balance_minor+1 WHERE context_id=$1', [g.ctx], /I3/);
    await corrupt('DELETE FROM shared_expenses.revision_approvals WHERE context_id=$1 AND revision_id=$2', [g.ctx, x.r.revisionId], /I6|I7/);
    await corrupt('UPDATE shared_expenses.journal_entries SET balance_minor=balance_minor+1 WHERE context_id=$1 AND line_no=0', [g.ctx], /I2|I3|I4/);
    await corrupt('UPDATE shared_expenses.context_totals SET total_minor=total_minor+1 WHERE context_id=$1', [g.ctx], /I10/);
  });
});

describe('M60 randomized model check', { skip: SKIP, timeout: process.env.PANDAPAY_WORST_MONEY_EXTRA_SEEDS ? 1800000 : 290000 }, () => {
  let F;
  before(async () => { F = await createFixture('random'); });
  after(async () => { if (F) await F.close(); });
  for (const run of RUNS) {
    it(`M60 ${run.kind} of ${run.n}: ${run.ops} mixed operations, invariants + model after every step (seed ${run.seed})`, async () => {
      const g = await F.group(run.n, 'rnd');
      let ctxInfo = g;
      if (run.kind === 'direct') {
        const [a, b] = await F.profiles(2, 'd');
        const { ctx, owner } = await F.createContext(a, 'direct', 'dr' + uuid().slice(0, 6));
        const mb = await F.join(a, ctx, b, 'drb' + uuid().slice(0, 4));
        ctxInfo = { ctx, p: [a, b], m: [owner, mb] };
      }
      const sim = new Sim(F, ctxInfo, run.seed, run.kind);
      await sim.run(run.ops);
      if (sim.failure) assert.fail(sim.failure);
      assert.deepEqual(sim.unexpected, [], 'raw (non-domain) database errors surfaced');
      const stats = Object.fromEntries([...sim.ops.entries()].sort());
      console.log(`# M60 ${run.kind}/${run.n} seed=${run.seed}`, JSON.stringify(stats));
      const ok = k => [...sim.ops.entries()].filter(([key]) => key.startsWith(k) && key.endsWith(':ok')).reduce((a, [, v]) => a + v, 0);
      assert.ok(ok('propose') + ok('edit') >= 10, 'run produced enough expense activity to be meaningful');
      assert.ok([...sim.bal.values()].some(v => v !== 0n) || ok('settle-confirm') > 0, 'run produced money movement');
      assert.deepEqual(await F.invariants(ctxInfo.ctx), []);
    });
  }
});
