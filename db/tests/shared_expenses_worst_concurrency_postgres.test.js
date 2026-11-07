'use strict';
// Worst-case concurrency / idempotency / flag-transition suite for split (shared expenses).
// Real independent PostgreSQL sessions, every command executed as app_user exactly like the API
// (BEGIN; SET ROLE app_user; app.user_id; SELECT shared_expenses.fn(...); COMMIT).
// Opt-in: PANDAPAY_SHARED_EXPENSES_WORST_URL=postgres://user:pw@127.0.0.1:PORT/shared_expenses_worst_concurrency_test
// The database must be ABSENT; the test creates and drops it. Never reads dotenv or DATABASE_URL.
// Tests marked { todo: 'BUG Bnn: ...' } assert the CORRECT behaviour and currently FAIL (a real defect);
// they turn green by themselves once the defect is fixed.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createRequire } = require('node:module');
const { transactionalSql } = require('../scripts/product_migrate');
const requireApi = createRequire(path.resolve(__dirname, '../../api/package.json'));
const raw = process.env.PANDAPAY_SHARED_EXPENSES_WORST_URL;
const DB = 'shared_expenses_worst_concurrency_test';
const id = () => crypto.randomUUID();
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const hashOf = (o) => sha(JSON.stringify(o));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function target(value) {
  if (!value) throw new Error('explicit worst-concurrency fixture URL required');
  const url = new URL(value);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.pathname !== `/${DB}` || url.search || url.hash) throw new Error('loopback ' + DB + ' required');
  return url;
}
test('worst-concurrency fixture refuses ambient targets', () => {
  assert.throws(() => target());
  assert.throws(() => target('postgres://localhost/pandapay'));
  assert.throws(() => target('postgres://remote/' + DB));
});

// Mirror of api/src/shared_expenses/routes.js sendError status mapping (used to prove nothing leaks as a 500).
process.env.API_DATABASE_URL ||= 'postgres://unused:unused@localhost:5432/unused'; // api config import only; never connected
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const { sendError } = requireApi('./src/shared_expenses/routes');
function httpStatus(r) {
  let status = 0;
  const res = { status(s) { status = s; return res; }, json() { return res; } };
  sendError(res, Object.assign(new Error(r.message), { code: r.code, detail: r.detail }));
  return status;
}

test('worst-case concurrency, idempotency and flag transitions', { skip: !raw && 'PANDAPAY_SHARED_EXPENSES_WORST_URL not supplied', timeout: 900000 }, async (t) => {
  const { Client, Pool } = requireApi('pg');
  const url = target(raw), adminUrl = new URL(url);
  adminUrl.pathname = '/postgres';
  const marker = 'worst-' + id();
  const bootstrap = new Client({ connectionString: adminUrl.toString(), connectionTimeoutMillis: 5000, application_name: marker });
  await bootstrap.connect();
  let owns = false, pool, admin;
  const sessions = new Set();
  t.after(async () => {
    for (const s of sessions) { await s.c.query('ROLLBACK').catch(() => {}); await s.c.end().catch(() => {}); }
    if (pool) await pool.end().catch(() => {});
    if (admin) await admin.end().catch(() => {});
    if (owns) await bootstrap.query(`DROP DATABASE ${DB} WITH (FORCE)`).catch(() => {});
    await bootstrap.end();
  });
  assert.equal((await bootstrap.query('SELECT 1 FROM pg_database WHERE datname=$1', [DB])).rowCount, 0, 'refuse an existing database');
  await bootstrap.query(`CREATE DATABASE ${DB}`);
  owns = true;
  admin = new Client({ connectionString: url.toString(), connectionTimeoutMillis: 5000, application_name: marker });
  admin.on('error', () => {});
  await admin.connect();
  await admin.query(`
    DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='app_user') THEN CREATE ROLE app_user NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF; END $$;
    CREATE SCHEMA pandapay;
    CREATE FUNCTION pandapay.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id',true),'')::uuid $$;
    CREATE TABLE public.profiles(id uuid PRIMARY KEY,display_name text);
    ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY; ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
    CREATE POLICY profiles_owner ON public.profiles FOR ALL USING(id=pandapay.uid()) WITH CHECK(id=pandapay.uid());
    CREATE TABLE public.transactions(id uuid PRIMARY KEY,profile_id uuid,amount_inr numeric(12,2),occurred_at timestamptz,status text,entry_kind text,source text,instrument text,updated_at timestamptz,pipeline_version smallint,event_id text,source_key text);
    CREATE TABLE public.sms_v2_events(event_id text PRIMARY KEY,profile_id uuid,type text,status text,amount_minor bigint,updated_at timestamptz);
    CREATE TABLE public.sms_v2_instruments(instrument_id uuid PRIMARY KEY,profile_id uuid,status text,updated_at timestamptz);
    CREATE TABLE public.sms_v2_ledger_entries(entry_id text PRIMARY KEY,profile_id uuid,event_id text,from_instrument_id uuid,from_external text,from_own_unresolved text,to_instrument_id uuid,to_external text,to_own_unresolved text,amount_minor bigint,unit text,is_spend boolean,counts_as_transaction boolean,updated_at timestamptz);
    CREATE TABLE public.foreign_payments(id uuid PRIMARY KEY,profile_id uuid,transaction_id uuid,valuation_status text,billed_inr numeric(12,2),original_currency text,original_amount numeric(26,4),direction text,confirmation_source text,revision int,updated_at timestamptz);
  `);
  const dir = path.resolve(__dirname, '../supabase/migrations');
  await admin.query('BEGIN');
  await admin.query(transactionalSql(fs.readFileSync(path.join(dir, '20261112210000_shared_expenses_foundation.sql'), 'utf8')));
  await admin.query('COMMIT');
  for (const f of fs.readdirSync(dir).filter((n) => n.includes('_shared_expense_') && n > '20261112210000').sort()) await admin.query(fs.readFileSync(path.join(dir, f), 'utf8'));
  await admin.query('GRANT USAGE ON SCHEMA public,pandapay TO app_user; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO app_user; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pandapay TO app_user');
  const setFlags = (f) => admin.query('UPDATE shared_expenses.settings SET reads_enabled=$1,proposals_enabled=$2,accepted_writes_enabled=$3,settlements_enabled=$4', [f.reads ?? true, f.proposals ?? true, f.writes ?? true, f.settle ?? true]);
  await setFlags({});
  pool = new Pool({ connectionString: url.toString(), max: 40, connectionTimeoutMillis: 20000, application_name: marker });
  pool.on('error', () => {});

  // ------------------------------------------------------------------ harness
  const q = (sql, args) => admin.query(sql, args);
  const one = async (sql, args) => (await q(sql, args)).rows[0];
  const num = async (sql, args) => Number((await q(sql, args)).rows[0].n);
  const sigParts = (sig) => { const n = sig.slice(0, sig.indexOf('(')); const types = sig.slice(sig.indexOf('(') + 1, -1).split(',').filter(Boolean); return { n, types }; };
  const sqlFor = (sig) => { const { n, types } = sigParts(sig); return `SELECT shared_expenses.${n}(${types.map((ty, i) => `$${i + 1}::${ty}`).join(',')}) AS v`; };
  const norm = (a) => a.map((x) => (x !== null && typeof x === 'object' && !Array.isArray(x) && !(x instanceof Buffer) ? JSON.stringify(x) : x));
  const fail = (e) => ({ ok: false, message: e.message, code: e.code, detail: e.detail });
  /** One API-style request: its own transaction as app_user. */
  async function call(user, sig, args) {
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await c.query("SET LOCAL statement_timeout='60s'; SET LOCAL lock_timeout='50s'; SET LOCAL ROLE app_user");
      await c.query("SELECT set_config('app.user_id',$1,true)", [user]);
      const r = await c.query(sqlFor(sig), norm(args));
      await c.query('COMMIT');
      return { ok: true, v: r.rows[0].v };
    } catch (e) { await c.query('ROLLBACK').catch(() => {}); return fail(e); } finally { c.release(); }
  }
  /** Client-style retry on the statuses the API tells clients to retry (409 retryable_conflict). */
  const stats = { deadlocks: 0, serialization: 0 };
  async function callRetry(user, sig, args, tries = 4) {
    let r;
    for (let i = 0; i < tries; i++) {
      r = await call(user, sig, args);
      if (r.ok || !['40P01', '40001'].includes(r.code) || ['revision_head_conflict', 'source_version_mismatch'].includes(r.message)) return r;
      if (r.code === '40P01') stats.deadlocks++; else stats.serialization++;
      await sleep(10 + Math.random() * 30);
    }
    return r;
  }
  /** A manual transaction that can be left open to hold locks (as app_user). */
  async function open(user, { role = true } = {}) {
    const c = new Client({ connectionString: url.toString(), connectionTimeoutMillis: 5000, application_name: marker });
    c.on('error', () => {});
    await c.connect();
    const pid = (await c.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
    await c.query('BEGIN');
    await c.query("SET LOCAL statement_timeout='60s'; SET LOCAL lock_timeout='50s'");
    if (role) await c.query('SET LOCAL ROLE app_user');
    if (user) await c.query("SELECT set_config('app.user_id',$1,true)", [user]);
    const s = { c, pid, call: (sig, args) => c.query(sqlFor(sig), norm(args)).then((r) => r.rows[0].v) };
    s.commit = async () => { await c.query('COMMIT'); await c.end().catch(() => {}); sessions.delete(s); };
    s.rollback = async () => { await c.query('ROLLBACK').catch(() => {}); await c.end().catch(() => {}); sessions.delete(s); };
    sessions.add(s);
    return s;
  }
  async function waitBlocked(s, ms = 10000) {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const st = await q('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1', [s.pid]);
      if (st.rows[0]?.wait_event_type === 'Lock') return;
      await sleep(15);
    }
    assert.fail('expected the session to be waiting on a lock');
  }
  const settled = (p) => { const o = { done: false }; o.p = p.then((v) => { o.done = true; o.v = v; return v; }, (e) => { o.done = true; o.e = e; throw e; }); o.p.catch(() => {}); return o; };
  const must = (r, label = '') => { assert.equal(r.ok, true, `${label} expected success, got ${r.message}`); return r.v; };
  const failsWith = (r, message) => { assert.equal(r.ok, false, `expected ${message}, got success ${JSON.stringify(r.v)}`); assert.equal(r.message, message); };
  const strip = (v) => { if (!v || typeof v !== 'object') return v; const { fresh, ...rest } = v; return rest; };
  const tally = (rs) => { const o = {}; for (const r of rs) { const k = r.ok ? 'ok' : r.message; o[k] = (o[k] || 0) + 1; } return o; };
  const noInternal = (rs) => { for (const r of rs) if (!r.ok) assert.notEqual(httpStatus(r), 500, `leaked as HTTP 500: ${r.message} ${r.code}`); };

  // ------------------------------------------------------------------ builders
  let userSeq = 0;
  async function user(name) {
    const u = id();
    await q('INSERT INTO public.profiles(id,display_name) VALUES($1,$2)', [u, name ?? `Person${++userSeq}x${u.slice(0, 4)}`]);
    return u;
  }
  const users = async (n) => Promise.all(Array.from({ length: n }, () => user()));
  const createCtx = (u, { ctx = id(), kind = 'group', name = 'Split ' + ctx.slice(0, 6), op = id() } = {}) =>
    call(u, 'create_context(uuid,text,text,uuid,text)', [ctx, kind, name, op, hashOf({ k: 'create', ctx, kind, name })]).then((r) => ({ ...r, ctx, op, name, kind }));
  const invitePayload = (ctx, memberId, displayName, profileId) => ({ contextId: ctx, memberId, displayName, ...(profileId ? { profileId } : {}) });
  const inviteP = (u, p, op = id()) => call(u, 'invite_member(jsonb,uuid,text)', [p, op, hashOf(p)]);
  const respondMembership = (u, ctx, member, accept, op = id()) => call(u, 'respond_membership(uuid,uuid,boolean,uuid,text)', [ctx, member, accept, op, hashOf({ ctx, member, accept })]);
  const renameP = (u, p, op = id()) => call(u, 'rename_member(jsonb,uuid,text)', [p, op, hashOf(p)]);
  const proposeP = (u, p, op = id()) => call(u, 'submit_proposal(jsonb,uuid,text)', [p, op, hashOf(p)]);
  const respondExpP = (u, p, op = id()) => call(u, 'respond_expense(jsonb,uuid,text)', [p, op, hashOf(p)]);
  const reportP = (u, p, op = id()) => call(u, 'report_settlement(jsonb,uuid,text)', [p, op, hashOf(p)]);
  const respondSetP = (u, p, op = id()) => call(u, 'respond_settlement(jsonb,uuid,text)', [p, op, hashOf(p)]);
  const simple = (name, extraTypes) => (u, args, op = id()) => call(u, `${name}(${extraTypes})`, [...args, op, hashOf({ name, args })]);
  const leave = simple('leave_context', 'uuid,uuid,text'), remove = simple('remove_member', 'uuid,uuid,uuid,text');
  const transfer = simple('transfer_owner', 'uuid,uuid,uuid,text'), takeOver = simple('take_over_ownership', 'uuid,uuid,text');
  const linkCreate = (u, ctx, tokenHash, op = id()) => call(u, 'create_group_link(uuid,text,uuid,text)', [ctx, tokenHash, op, hashOf({ ctx, tokenHash, a: 'create' })]);
  const linkRevoke = (u, ctx, op = id()) => call(u, 'revoke_group_link(uuid,uuid,text)', [ctx, op, hashOf({ ctx, a: 'revoke' })]);
  const claim = (u, tokenHash, { phone = null, suffix = null, op = id(), share = null } = {}) => call(u, 'claim_invitation(text,text,text,uuid,text,text)', [tokenHash, phone, suffix, op, hashOf({ tokenHash, accept: true, share }), share]);
  const respondInv = (u, inv, approve, op = id()) => call(u, 'respond_invitation(uuid,boolean,uuid,text)', [inv, approve, op, hashOf({ inv, approve })]);
  const snap = (total, payer, shares) => ({ currency: 'INR', totalMinor: String(total), contributions: [{ memberId: payer, amountMinor: String(total) }], shares: shares.map(([m, a]) => ({ memberId: m, amountMinor: String(a) })), memberOrder: [...new Set([payer, ...shares.map((s) => s[0])])] });
  const proposal = (ctx, payer, shares, { expense = id(), revision = id(), head = null, total } = {}) => ({
    contextId: ctx, expenseId: expense, revisionId: revision, expectedHeadRevisionId: head, snapshot: snap(total ?? shares.reduce((a, s) => a + s[1], 0), payer, shares),
    title: 'Dinner', occurredOn: '2026-11-01', sources: [], void: false,
  });
  /** A group: owner + active members (invite with profile id, then they accept). */
  async function group(owner, others = [], { name } = {}) {
    const c = await createCtx(owner, { name });
    must(c, 'create group');
    const g = { ctx: c.ctx, owner, members: { [owner]: c.v.memberId } };
    for (const u of others) {
      const mid = id();
      must(await inviteP(owner, invitePayload(g.ctx, mid, `M${mid.slice(0, 6)}`, u)), 'invite');
      must(await respondMembership(u, g.ctx, mid, true), 'accept');
      g.members[u] = mid;
    }
    return g;
  }
  const events = async (ctx) => (await q('SELECT sequence::int s,kind FROM shared_expenses.context_events WHERE context_id=$1 ORDER BY sequence', [ctx])).rows;
  const evCount = (ctx) => num('SELECT count(*) n FROM shared_expenses.context_events WHERE context_id=$1', [ctx]);
  const receiptCount = (op) => num('SELECT count(*) n FROM shared_expenses.operation_receipts WHERE operation_id=$1', [op]);
  const tokenOf = () => sha('token-' + id());

  /** Whole-database structural invariants (cheap enough to run after every racing test). */
  async function invariants(label = '') {
    const bad = [];
    const add = async (what, sql) => { const n = await num(`SELECT count(*) n FROM (${sql}) x`); if (n) bad.push(`${what}: ${n}`); };
    await add('context balances do not sum to zero', 'SELECT context_id FROM shared_expenses.member_balances GROUP BY 1 HAVING sum(balance_minor)<>0');
    await add('pair_balances differ from journal', `WITH j AS(SELECT context_id,low_member_id,high_member_id,sum(balance_minor) s FROM shared_expenses.journal_entries GROUP BY 1,2,3 HAVING sum(balance_minor)<>0)
      SELECT 1 FROM j FULL JOIN shared_expenses.pair_balances p USING(context_id,low_member_id,high_member_id) WHERE coalesce(j.s,0)<>coalesce(p.balance_minor,0)`);
    await add('member_balances differ from pair_balances', `WITH d AS(SELECT context_id,low_member_id m,balance_minor b FROM shared_expenses.pair_balances UNION ALL SELECT context_id,high_member_id,-balance_minor FROM shared_expenses.pair_balances),
      s AS(SELECT context_id,m,sum(b) b FROM d GROUP BY 1,2)
      SELECT 1 FROM s FULL JOIN shared_expenses.member_balances mb ON mb.context_id=s.context_id AND mb.member_id=s.m WHERE coalesce(s.b,0)<>coalesce(mb.balance_minor,0)`);
    await add('context event sequence gap or duplicate', `SELECT c.context_id FROM shared_expenses.contexts c LEFT JOIN (SELECT context_id,count(*) n,max(sequence) m FROM shared_expenses.context_events GROUP BY 1) e USING(context_id) WHERE coalesce(e.n,0)<>c.committed_sequence OR coalesce(e.m,0)<>c.committed_sequence`);
    await add('profile stream gap or duplicate', `SELECT h.profile_id FROM shared_expenses.profile_stream_heads h LEFT JOIN (SELECT profile_id,count(*) n,max(sequence) m FROM shared_expenses.profile_events GROUP BY 1) e USING(profile_id) WHERE coalesce(e.n,0)<>h.committed_sequence OR coalesce(e.m,0)<>h.committed_sequence`);
    await add('receipt without result', 'SELECT 1 FROM shared_expenses.operation_receipts WHERE result IS NULL');
    await add('two terminal settlement events', "SELECT 1 FROM shared_expenses.settlement_events WHERE kind IN ('confirmed','rejected') GROUP BY context_id,settlement_id HAVING count(*)>1");
    await add('accepted revision without edges applied once', `SELECT 1 FROM shared_expenses.expenses e WHERE e.accepted_revision_id IS NOT NULL AND (SELECT count(*) FROM shared_expenses.obligation_edges o WHERE o.context_id=e.context_id AND o.revision_id=e.accepted_revision_id)<>(SELECT jsonb_array_length(projected_edges) FROM shared_expenses.expense_revisions r WHERE r.context_id=e.context_id AND r.revision_id=e.accepted_revision_id)`);
    await add('active/invited member label duplicates in one split', `SELECT m.context_id FROM shared_expenses.members m WHERE m.state IN ('active','invited') AND shared_expenses._label_key(coalesce(NULLIF(btrim(m.display_name),''),(SELECT p.display_name FROM public.profiles p WHERE p.id=m.profile_id)))<>'' GROUP BY m.context_id,shared_expenses._label_key(coalesce(NULLIF(btrim(m.display_name),''),(SELECT p.display_name FROM public.profiles p WHERE p.id=m.profile_id))) HAVING count(*)>1`);
    await add('two members with one profile in one split', 'SELECT 1 FROM shared_expenses.members WHERE profile_id IS NOT NULL GROUP BY context_id,profile_id HAVING count(*)>1');
    await add('active owner-less group/direct split', "SELECT c.context_id FROM shared_expenses.contexts c WHERE c.state='active' AND NOT EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=c.context_id AND m.role='owner')");
    assert.deepEqual(bad, [], `invariants ${label}`);
  }
  /** Same, but only returns the violation list (for todo tests that look for a specific one). */

  // ================================================================== A. same-operation replays
  // Every command kind: N parallel sessions with one operation id (+ sequential "reply lost" retries).
  const PAR = 10;
  async function replayCase(label, { setup, run, effects, events: expectedEvents }) {
    await t.test(label, async () => {
      const d = await setup();
      const before = await evCount(d.ctx);
      const results = await Promise.all(Array.from({ length: PAR }, () => run(d)));
      noInternal(results);
      for (const r of results) assert.equal(r.ok, true, `${label}: ${r.message}`);
      const first = JSON.stringify(strip(results[0].v));
      for (const r of results) assert.equal(JSON.stringify(strip(r.v)), first, 'identical stored result for every replay');
      assert.equal(await evCount(d.ctx) - before, expectedEvents, 'exactly the expected events');
      assert.equal(await receiptCount(d.op), 1, 'one receipt');
      await effects(d);
      // reply lost: commit happened, response dropped, client retries later with the same operation id
      const afterFirst = await evCount(d.ctx);
      const retry = await run(d);
      assert.equal(retry.ok, true, 'late retry ok');
      assert.equal(JSON.stringify(strip(retry.v)), first, 'late retry returns the stored result');
      assert.equal(await evCount(d.ctx), afterFirst, 'late retry adds no event');
      await effects(d);
      await invariants(label);
    });
  }
  // Flat registration (node:test nests via t.test already; keep the list readable).
  await replayCase('C01 context.create x10 parallel + retry', {
    setup: async () => { const [a] = await users(1); return { a, ctx: id(), op: id() }; },
    run: (d) => createCtx(d.a, { ctx: d.ctx, op: d.op, name: 'Replay create' }),
    events: 1,
    effects: async (d) => { assert.equal(await num('SELECT count(*) n FROM shared_expenses.contexts WHERE context_id=$1', [d.ctx]), 1); assert.equal(await num('SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1', [d.ctx]), 1); },
  });
  await replayCase('C01b direct context.create x10 parallel (friend lock path)', {
    setup: async () => { const [a] = await users(1); return { a, ctx: id(), op: id() }; },
    run: (d) => createCtx(d.a, { ctx: d.ctx, op: d.op, kind: 'direct', name: 'Zed Replay' }),
    events: 1,
    effects: async (d) => { assert.equal(await num("SELECT count(*) n FROM shared_expenses.contexts WHERE created_by=$1 AND kind='direct'", [d.a]), 1); },
  });
  await replayCase('C02 member.invite x10', {
    setup: async () => { const [a] = await users(1); const g = await group(a); return { ...g, mid: id(), op: id() }; },
    run: (d) => inviteP(d.owner, invitePayload(d.ctx, d.mid, 'Newcomer'), d.op),
    events: 1,
    effects: async (d) => assert.equal(await num('SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2', [d.ctx, d.mid]), 1),
  });
  await replayCase('C03 member.rename x10', {
    setup: async () => { const [a, b] = await users(2); const g = await group(a, [b]); return { ...g, b, op: id() }; },
    run: (d) => renameP(d.b, { contextId: d.ctx, memberId: d.members[d.b], displayName: 'Brand New' }, d.op),
    events: 1,
    effects: async (d) => assert.equal((await one('SELECT display_name FROM shared_expenses.members WHERE member_id=$1', [d.members[d.b]])).display_name, 'Brand New'),
  });
  await replayCase('C04 membership.respond x10', {
    setup: async () => { const [a, b] = await users(2); const g = await group(a); const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Invitee', b))); return { ...g, b, mid, op: id() }; },
    run: (d) => respondMembership(d.b, d.ctx, d.mid, true, d.op),
    events: 1,
    effects: async (d) => assert.equal((await one('SELECT state FROM shared_expenses.members WHERE member_id=$1', [d.mid])).state, 'active'),
  });
  await replayCase('C05 expense.propose x10', {
    setup: async () => { const [a, b] = await users(2); const g = await group(a, [b]); const p = proposal(g.ctx, g.members[a], [[g.members[a], 500], [g.members[b], 500]]); return { ...g, p, op: id() }; },
    run: (d) => proposeP(d.owner, d.p, d.op),
    events: 1,
    effects: async (d) => { assert.equal(await num('SELECT count(*) n FROM shared_expenses.expense_revisions WHERE context_id=$1', [d.ctx]), 1); assert.equal(await num('SELECT count(*) n FROM shared_expenses.revision_approvals WHERE context_id=$1', [d.ctx]), 1); },
  });
  await replayCase('C06 expense.respond (approve) x10 posts the journal once', {
    setup: async () => {
      const [a, b] = await users(2); const g = await group(a, [b]); const p = proposal(g.ctx, g.members[a], [[g.members[a], 500], [g.members[b], 500]]);
      must(await proposeP(a, p)); return { ...g, b, p, op: id() };
    },
    run: (d) => respondExpP(d.b, { contextId: d.ctx, expenseId: d.p.expenseId, revisionId: d.p.revisionId, decision: 'approve' }, d.op),
    events: 1,
    effects: async (d) => {
      assert.equal(await num('SELECT count(*) n FROM shared_expenses.journal_entries WHERE context_id=$1', [d.ctx]), 1, 'one journal line');
      assert.equal(await num('SELECT abs(balance_minor) n FROM shared_expenses.pair_balances WHERE context_id=$1', [d.ctx]), 500, 'balance posted exactly once');
      assert.equal(await num('SELECT count(*) n FROM shared_expenses.private_cost_facts WHERE context_id=$1', [d.ctx]), 2);
    },
  });
  await replayCase('C07 settlement.report x10', {
    setup: async () => { const [a, b] = await users(2); const g = await group(a, [b]); const p = { contextId: g.ctx, settlementId: id(), payerMemberId: g.members[b], receiverMemberId: g.members[a], amountMinor: '100', currency: 'INR', method: 'cash', paidOn: '2026-11-01' }; return { ...g, b, p, op: id() }; },
    run: (d) => reportP(d.b, d.p, d.op),
    events: 1,
    effects: async (d) => assert.equal(await num('SELECT count(*) n FROM shared_expenses.settlement_reports WHERE context_id=$1', [d.ctx]), 1),
  });
  await replayCase('C08 settlement.respond (confirm) x10 posts once', {
    setup: async () => {
      const [a, b] = await users(2); const g = await group(a, [b]);
      const p = { contextId: g.ctx, settlementId: id(), payerMemberId: g.members[b], receiverMemberId: g.members[a], amountMinor: '100', currency: 'INR', method: 'cash', paidOn: '2026-11-01' };
      must(await reportP(b, p)); return { ...g, b, p, op: id() };
    },
    run: (d) => respondSetP(d.owner, { contextId: d.ctx, settlementId: d.p.settlementId, decision: 'confirm' }, d.op),
    events: 1,
    effects: async (d) => { assert.equal(await num("SELECT count(*) n FROM shared_expenses.settlement_events WHERE context_id=$1 AND kind='confirmed'", [d.ctx]), 1); assert.equal(await num('SELECT count(*) n FROM shared_expenses.journal_entries WHERE context_id=$1', [d.ctx]), 1); },
  });
  await replayCase('C09 invitation.create x10 (operation id = invitation id)', {
    setup: async () => { const [a] = await users(1); const g = await group(a); const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Linkee'))); const inv = id(); return { ...g, mid, inv, op: inv }; },
    run: (d) => { const p = { invitationId: d.inv, contextId: d.ctx, memberId: d.mid, targetPhoneHash: null, tokenHash: sha('tok' + d.inv) }; return call(d.owner, 'create_invitation(jsonb,text)', [p, hashOf(p)]); },
    events: 0,
    effects: async (d) => assert.equal(await num('SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1', [d.ctx]), 1),
  });
  await replayCase('C10 invitation.claim (link) x10', {
    setup: async () => {
      const [a, c] = await users(2); const g = await group(a); const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Linkee')));
      const inv = id(), tokenHash = sha('tok' + inv); const p = { invitationId: inv, contextId: g.ctx, memberId: mid, targetPhoneHash: null, tokenHash }; must(await call(a, 'create_invitation(jsonb,text)', [p, hashOf(p)]));
      return { ...g, c, tokenHash, mid, inv, op: id() };
    },
    run: (d) => claim(d.c, d.tokenHash, { op: d.op }),
    events: 1,
    effects: async (d) => { const r = await one('SELECT state,claimed_profile_id FROM shared_expenses.invitations WHERE invitation_id=$1', [d.inv]); assert.equal(r.state, 'awaiting_owner'); assert.equal(r.claimed_profile_id, d.c); },
  });
  await replayCase('C11 invitation.respond (approve) x10', {
    setup: async () => {
      const [a, c] = await users(2); const g = await group(a); const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Linkee')));
      const inv = id(), tokenHash = sha('tok' + inv); const p = { invitationId: inv, contextId: g.ctx, memberId: mid, targetPhoneHash: null, tokenHash }; must(await call(a, 'create_invitation(jsonb,text)', [p, hashOf(p)]));
      must(await claim(c, tokenHash)); return { ...g, c, mid, inv, op: id() };
    },
    run: (d) => respondInv(d.owner, d.inv, true, d.op),
    events: 1,
    effects: async (d) => { assert.equal(await num('SELECT count(*) n FROM shared_expenses.member_identity_bindings WHERE context_id=$1', [d.ctx]), 1); assert.equal((await one('SELECT state,profile_id FROM shared_expenses.members WHERE member_id=$1', [d.mid])).state, 'active'); },
  });
  await replayCase('C12 group-link create x10 and revoke x10', {
    setup: async () => { const [a] = await users(1); const g = await group(a); return { ...g, op: id(), tok: tokenOf() }; },
    run: (d) => linkCreate(d.owner, d.ctx, d.tok, d.op),
    events: 0,
    effects: async (d) => assert.equal(await num('SELECT count(*) n FROM shared_expenses.group_links WHERE context_id=$1', [d.ctx]), 1),
  });
  await replayCase('C13 group-link claim x10 (one request, one placeholder member)', {
    setup: async () => { const [a, c] = await users(2); const g = await group(a); const tok = tokenOf(); must(await linkCreate(a, g.ctx, tok)); return { ...g, c, tok, op: id() }; },
    run: (d) => claim(d.c, d.tok, { op: d.op }),
    events: 1,
    effects: async (d) => { assert.equal(await num('SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1 AND claimed_profile_id=$2', [d.ctx, d.c]), 1); assert.equal(await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND state='invited'", [d.ctx]), 1); },
  });
  await replayCase('C14 invitation by id: accept x10', {
    setup: async () => {
      const [a, c] = await users(2); const g = await group(a); const phone = sha('phone' + c); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [c, phone]);
      const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Phoned')));
      const inv = id(); const p = { invitationId: inv, contextId: g.ctx, memberId: mid, targetPhoneHash: phone, tokenHash: sha('t' + inv) }; must(await call(a, 'create_invitation(jsonb,text)', [p, hashOf(p)]));
      return { ...g, c, inv, phone, mid, op: id() };
    },
    run: (d) => call(d.c, 'claim_invitation_by_id(uuid,text,text,uuid,text)', [d.inv, d.phone, '1234', d.op, hashOf({ i: d.inv })]),
    events: 1,
    effects: async (d) => assert.equal((await one('SELECT state FROM shared_expenses.members WHERE member_id=$1', [d.mid])).state, 'active'),
  });
  await t.test('C15 leave x10 / transfer_owner x10 in parallel: one effect, every loser sees the stored result or a clean 403', async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const opL = id(), opT = id();
    const ls = await Promise.all(Array.from({ length: PAR }, () => leave(b, [g.ctx], opL)));
    noInternal(ls);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.context_events WHERE context_id=$1 AND kind='membership.left'", [g.ctx]), 1);
    for (const r of ls) assert.ok(r.ok || r.message === 'membership_not_authorized', r.message);
    assert.equal(await receiptCount(opL), 1);
    const ts = await Promise.all(Array.from({ length: PAR }, () => transfer(a, [g.ctx, g.members[c]], opT)));
    noInternal(ts);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.context_events WHERE context_id=$1 AND kind='member.owner_changed'", [g.ctx]), 1);
    for (const r of ts) assert.ok(r.ok || r.message === 'context_not_authorized', r.message);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND role='owner'", [g.ctx]), 1);
    await invariants('C15');
  });
  await t.test('B09 reply-lost retry of a COMMITTED leave / owner transfer is answered 403 instead of the stored result', { todo: 'BUG B09: leave_context and transfer_owner authorize (member active / caller owner) BEFORE the idempotency lookup, so the legitimate retry of an operation that already committed fails with membership_not_authorized / context_not_authorized' }, async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const opL = id(), opT = id();
    const l1 = must(await leave(b, [g.ctx], opL)); const t1 = must(await transfer(a, [g.ctx, g.members[c]], opT));
    const l2 = await leave(b, [g.ctx], opL), t2 = await transfer(a, [g.ctx, g.members[c]], opT);
    assert.equal(l2.ok, true, 'leave retry: ' + l2.message); assert.deepEqual(l2.v, l1);
    assert.equal(t2.ok, true, 'transfer retry: ' + t2.message); assert.deepEqual(t2.v, t1);
  });
  await replayCase('C15c remove_member x10 (invited, no expense)', {
    setup: async () => { const [a] = await users(1); const g = await group(a); const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Removable'))); return { ...g, mid, op: id() }; },
    run: (d) => remove(d.owner, [d.ctx, d.mid], d.op),
    events: 1,
    effects: async (d) => assert.equal((await one('SELECT state FROM shared_expenses.members WHERE member_id=$1', [d.mid])).state, 'declined'),
  });
  await replayCase('C15d take_over_ownership x10 (owner account gone)', {
    setup: async () => { const [a, b] = await users(2); const g = await group(a, [b]); await q('UPDATE shared_expenses.members SET profile_id=NULL WHERE member_id=$1', [g.members[a]]); return { ...g, b, op: id() }; },
    run: (d) => takeOver(d.b, [d.ctx], d.op),
    events: 1,
    effects: async (d) => assert.equal((await one('SELECT role FROM shared_expenses.members WHERE member_id=$1', [d.members[d.b]])).role, 'owner'),
  });

  // ================================================================== B. operation id misuse
  await t.test('C20 same operation id + different body (or other context) => operation_conflict, nothing applied', async () => {
    const [a, b] = await users(2); const g = await group(a, [b]);
    const op = id(); const p1 = invitePayload(g.ctx, id(), 'First One');
    must(await inviteP(a, p1, op));
    const before = await evCount(g.ctx);
    const rs = await Promise.all([inviteP(a, invitePayload(g.ctx, id(), 'Second One'), op), inviteP(a, { ...p1, displayName: 'Changed' }, op), renameP(a, { contextId: g.ctx, memberId: g.members[a], displayName: 'Other kind' }, op), inviteP(a, invitePayload(g.ctx, p1.memberId, 'First One'), op)]);
    failsWith(rs[0], 'operation_conflict'); failsWith(rs[1], 'operation_conflict'); failsWith(rs[2], 'operation_conflict');
    assert.equal(rs[3].ok, true, 'identical body still replays');
    // same op id, same body but another context => conflict
    const g2 = await group(a, []);
    failsWith(await inviteP(a, invitePayload(g2.ctx, p1.memberId, 'First One'), op), 'operation_conflict');
    assert.equal(await evCount(g.ctx), before);
    // A different actor may reuse the same operation id (receipts are per actor).
    const other = await user(); const g3 = await group(other, []);
    must(await inviteP(other, invitePayload(g3.ctx, id(), 'Zed'), op));
    // parallel race of two DIFFERENT bodies on one new op id: exactly one wins, the other conflicts
    const op2 = id();
    const race = await Promise.all([inviteP(a, invitePayload(g.ctx, id(), 'Racer A'), op2), inviteP(a, invitePayload(g.ctx, id(), 'Racer B'), op2)]);
    assert.deepEqual(Object.keys(tally(race)).sort(), ['ok', 'operation_conflict']);
    await invariants('C20');
  });

  // ================================================================== C. replay after the world changed
  await t.test('C21 replay after member left / link revoked / approved by someone else / flag toggled', async () => {
    const [a, b, c, d] = await users(4); const g = await group(a, [b, c]);
    // propose by b, then b leaves (zero balance, but b is not part of an unaccepted expense: use another expense)
    const opP = id(), p = proposal(g.ctx, g.members[a], [[g.members[a], 300], [g.members[c], 300]]);
    must(await proposeP(a, p, opP));
    const opB = id(), pb = { contextId: g.ctx, memberId: g.members[b], displayName: 'Bee Renamed' };
    must(await renameP(b, pb, opB));
    must(await leave(b, [g.ctx]));
    const ev = await evCount(g.ctx);
    // member left -> replay of its earlier op must not re-apply, must not resurrect membership
    failsWith(await renameP(b, pb, opB), 'context_not_authorized');
    assert.equal((await one('SELECT state FROM shared_expenses.members WHERE member_id=$1', [g.members[b]])).state, 'left');
    // revoked link -> a replayed claim is refused, it never resurrects the request
    const tok = tokenOf(); must(await linkCreate(a, g.ctx, tok));
    const opClaim = id(); const first = must(await claim(d, tok, { op: opClaim }));
    assert.equal(first.status, 'awaiting_owner');
    must(await linkRevoke(a, g.ctx));
    const reinv = await num('SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1', [g.ctx]);
    const rep = await claim(d, tok, { op: opClaim });
    failsWith(rep, 'invitation_unavailable'); // documented: the stored result is NOT returned once the link is gone
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1', [g.ctx]), reinv);
    // request approved by someone else, then the claimant replays: stored result, no second member
    const invId = (await one('SELECT invitation_id FROM shared_expenses.invitations WHERE context_id=$1 AND claimed_profile_id=$2', [g.ctx, d])).invitation_id;
    must(await respondInv(a, invId, true));
    assert.equal((await one('SELECT state FROM shared_expenses.invitations WHERE invitation_id=$1', [invId])).state, 'joined');
    const evAfter = await evCount(g.ctx);
    // flag toggled: proposals off -> replay refused feature_disabled, on again -> original stored result
    await setFlags({ proposals: false });
    failsWith(await proposeP(a, p, opP), 'feature_disabled');
    await setFlags({});
    const again = await proposeP(a, p, opP);
    assert.equal(again.ok, true); assert.equal(await evCount(g.ctx), evAfter);
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.expense_revisions WHERE context_id=$1', [g.ctx]), 1);
    assert.ok(ev <= evAfter);
    await invariants('C21');
  });

  await t.test('C22 number purged then the claim is replayed / re-attached: nothing is resurrected', async () => {
    const [a, c] = await users(2); const g = await group(a); const tok = tokenOf(); must(await linkCreate(a, g.ctx, tok));
    const op = id(); const r = must(await claim(c, tok, { op, suffix: '4321' }));
    const inv = r.invitationId;
    const attach = (o) => call(c, 'attach_claimant_phone(uuid,uuid,text,text,text,bytea,text,text)', [inv, o, sha('ph'), '+91', '+91 ••••• 4321', Buffer.alloc(40, 7), 'k1', '4321']);
    // parallel attaches carrying the same operation: exactly one lands
    const rs = await Promise.all(Array.from({ length: 8 }, () => attach(op)));
    assert.equal(rs.filter((x) => x.ok && x.v.attached === true).length, 1, 'exactly one attach');
    assert.equal((await one('SELECT phone_share FROM shared_expenses.invitations WHERE invitation_id=$1', [inv])).phone_share, 'shared');
    // owner rejects: trigger purges ciphertext
    must(await respondInv(a, inv, false));
    assert.equal((await one('SELECT claimant_phone_enc IS NULL AS gone FROM shared_expenses.invitations WHERE invitation_id=$1', [inv])).gone, true);
    const re = await attach(op); // replay of attach after purge
    assert.equal(re.v.attached, false);
    assert.equal((await one('SELECT claimant_phone_enc IS NULL AS gone FROM shared_expenses.invitations WHERE invitation_id=$1', [inv])).gone, true);
    // replaying the claim itself returns the stored result and does not revive anything
    const rep = await claim(c, tok, { op, suffix: '4321' });
    assert.equal(rep.ok, true); assert.equal(rep.v.fresh, undefined, 'a replay is recognisable (no fresh flag)');
    assert.equal((await one('SELECT state FROM shared_expenses.invitations WHERE invitation_id=$1', [inv])).state, 'rejected');
    // a re-claim with a NEW operation supersedes the old op: the old op can never attach again
    await q("UPDATE shared_expenses.invitations SET state='awaiting_owner' WHERE invitation_id=$1", [inv]); // synthetic: owner undoes the reject
    const op2 = id(); must(await claim(c, tok, { op: op2, suffix: '4321' }));
    assert.equal((await attach(op)).v.attached, false, 'superseded operation cannot attach');
    assert.equal((await attach(op2)).v.attached, true);
  });

  // ================================================================== D. racing different operations
  await t.test('C30 two approvals of the same revision (2 approvers) and approve-vs-reject', async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const p = proposal(g.ctx, g.members[a], [[g.members[a], 300], [g.members[b], 300], [g.members[c], 300]]);
    must(await proposeP(a, p));
    const r = { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId };
    const rs = await Promise.all([respondExpP(b, { ...r, decision: 'approve' }), respondExpP(c, { ...r, decision: 'approve' }), respondExpP(b, { ...r, decision: 'approve' })]);
    noInternal(rs);
    assert.equal(rs.every((x) => x.ok), true, JSON.stringify(tally(rs)));
    assert.equal((await one('SELECT accepted_revision_id r,head_version h FROM shared_expenses.expenses WHERE expense_id=$1', [p.expenseId])).r, p.revisionId);
    assert.equal(Number((await one('SELECT head_version h FROM shared_expenses.expenses WHERE expense_id=$1', [p.expenseId])).h), 1, 'applied exactly once');
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.journal_entries WHERE context_id=$1', [g.ctx]), 2);
    // approve vs reject by DIFFERENT people on a fresh proposal
    const p2 = proposal(g.ctx, g.members[a], [[g.members[a], 200], [g.members[b], 200], [g.members[c], 200]]);
    must(await proposeP(a, p2));
    const r2 = { contextId: g.ctx, expenseId: p2.expenseId, revisionId: p2.revisionId };
    const rs2 = await Promise.all([respondExpP(b, { ...r2, decision: 'approve' }), respondExpP(c, { ...r2, decision: 'reject' })]);
    noInternal(rs2);
    const acc = (await one('SELECT accepted_revision_id r FROM shared_expenses.expenses WHERE expense_id=$1', [p2.expenseId])).r;
    assert.equal(acc, null, 'a revision with a rejection must never be accepted');
    // same person approve vs reject in parallel: the second is approval_conflict
    const p3 = proposal(g.ctx, g.members[a], [[g.members[a], 100], [g.members[b], 100]]);
    must(await proposeP(a, p3));
    const r3 = { contextId: g.ctx, expenseId: p3.expenseId, revisionId: p3.revisionId };
    const rs3 = await Promise.all([respondExpP(b, { ...r3, decision: 'approve' }), respondExpP(b, { ...r3, decision: 'reject' })]);
    assert.equal(rs3.filter((x) => x.ok).length, 1, JSON.stringify(tally(rs3)));
    assert.equal(rs3.find((x) => !x.ok).message, 'approval_conflict');
    await invariants('C30');
  });

  await t.test('C31 approve vs leave, propose vs leave, void vs approve', async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    // approve vs leave: b has a pending NEW expense -> leaving is refused (settle_first) in either order
    const p = proposal(g.ctx, g.members[a], [[g.members[a], 300], [g.members[b], 300]]);
    must(await proposeP(a, p));
    const rs = await Promise.all([respondExpP(b, { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId, decision: 'approve' }), leave(b, [g.ctx])]);
    noInternal(rs);
    const b1 = await one('SELECT state FROM shared_expenses.members WHERE member_id=$1', [g.members[b]]);
    const accepted = (await one('SELECT accepted_revision_id r FROM shared_expenses.expenses WHERE expense_id=$1', [p.expenseId])).r;
    // legal outcomes: (approve then leave refused: owes 150) or (leave refused first, approve ok). Never "left AND approved".
    assert.ok(!(b1.state === 'left' && accepted === p.revisionId), 'left after approving an unsettled debt');
    // void vs approve: author proposes void of the accepted head while c approves another revision
    const p2 = proposal(g.ctx, g.members[a], [[g.members[a], 100], [g.members[c], 100]]);
    must(await proposeP(a, p2)); must(await respondExpP(c, { contextId: g.ctx, expenseId: p2.expenseId, revisionId: p2.revisionId, decision: 'approve' }));
    const edit = proposal(g.ctx, g.members[a], [[g.members[a], 200], [g.members[c], 200]], { expense: p2.expenseId, head: p2.revisionId });
    const voidRev = { contextId: g.ctx, expenseId: p2.expenseId, revisionId: id(), expectedHeadRevisionId: p2.revisionId, snapshot: null, title: 'Void', occurredOn: '2026-11-01', sources: [], void: true };
    must(await proposeP(a, edit));
    must(await proposeP(a, voidRev));
    const rs2 = await Promise.all([respondExpP(c, { contextId: g.ctx, expenseId: p2.expenseId, revisionId: edit.revisionId, decision: 'approve' }), respondExpP(c, { contextId: g.ctx, expenseId: p2.expenseId, revisionId: voidRev.revisionId, decision: 'approve' })]);
    noInternal(rs2);
    // two revisions share one expected head: at most one may become head; the other must be a clean 40001 conflict
    const ok2 = rs2.filter((x) => x.ok && x.v.status === 'accepted').length;
    assert.equal(ok2, 1, JSON.stringify(rs2.map((x) => x.ok ? x.v.status : x.message)));
    assert.equal(rs2.find((x) => !x.ok)?.message, 'revision_head_conflict');
    assert.equal(Number((await one('SELECT head_version h FROM shared_expenses.expenses WHERE expense_id=$1', [p2.expenseId])).h), 2);
    await invariants('C31');
  });

  await t.test('C32 two settlement reports + parallel confirms: terminal event exactly once; settle vs expense edit', async () => {
    const [a, b] = await users(2); const g = await group(a, [b]);
    const p = proposal(g.ctx, g.members[a], [[g.members[a], 500], [g.members[b], 500]]); must(await proposeP(a, p));
    must(await respondExpP(b, { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId, decision: 'approve' })); // b owes a 500
    const rep = (amt) => ({ contextId: g.ctx, settlementId: id(), payerMemberId: g.members[b], receiverMemberId: g.members[a], amountMinor: String(amt), currency: 'INR', method: 'upi', paidOn: '2026-11-02' });
    const s1 = rep(400), s2 = rep(400), s3 = rep(400);
    const reps = await Promise.all([reportP(b, s1), reportP(b, s2), reportP(b, s3)]);
    for (const r of reps) must(r);
    const confirms = await Promise.all([
      respondSetP(a, { contextId: g.ctx, settlementId: s1.settlementId, decision: 'confirm' }), respondSetP(a, { contextId: g.ctx, settlementId: s1.settlementId, decision: 'confirm' }),
      respondSetP(a, { contextId: g.ctx, settlementId: s1.settlementId, decision: 'reject' }), respondSetP(a, { contextId: g.ctx, settlementId: s2.settlementId, decision: 'confirm' }),
      respondSetP(a, { contextId: g.ctx, settlementId: s3.settlementId, decision: 'confirm' }),
    ]);
    noInternal(confirms);
    for (const sid of [s1, s2, s3]) assert.ok(await num("SELECT count(*) n FROM shared_expenses.settlement_events WHERE settlement_id=$1 AND kind IN ('confirmed','rejected')", [sid.settlementId]) <= 1);
    const s1ev = await num("SELECT count(*) n FROM shared_expenses.settlement_events WHERE settlement_id=$1 AND kind IN ('confirmed','rejected')", [s1.settlementId]);
    assert.equal(s1ev, 1);
    assert.equal(confirms.filter((x) => !x.ok && x.message !== 'settlement_terminal_conflict').length, 0, JSON.stringify(tally(confirms)));
    // three 400 payments against a 500 debt: pair balance becomes credit for b; money conserved
    await invariants('C32');
    // settle vs expense edit (edit changes obligations while a settlement is being confirmed)
    const g2 = await group(a, [b]);
    const q1 = proposal(g2.ctx, g2.members[a], [[g2.members[a], 400], [g2.members[b], 400]]); must(await proposeP(a, q1)); must(await respondExpP(b, { contextId: g2.ctx, expenseId: q1.expenseId, revisionId: q1.revisionId, decision: 'approve' }));
    const sr = { contextId: g2.ctx, settlementId: id(), payerMemberId: g2.members[b], receiverMemberId: g2.members[a], amountMinor: '400', currency: 'INR', method: 'cash', paidOn: '2026-11-02' }; must(await reportP(b, sr));
    const e2 = proposal(g2.ctx, g2.members[a], [[g2.members[a], 100], [g2.members[b], 100]], { expense: q1.expenseId, head: q1.revisionId, total: 200 });
    e2.snapshot = snap(200, g2.members[a], [[g2.members[a], 100], [g2.members[b], 100]]); must(await proposeP(a, e2));
    const rs = await Promise.all([respondSetP(a, { contextId: g2.ctx, settlementId: sr.settlementId, decision: 'confirm' }), respondExpP(b, { contextId: g2.ctx, expenseId: q1.expenseId, revisionId: e2.revisionId, decision: 'approve' })]);
    noInternal(rs); for (const r of rs) must(r);
    await invariants('C32b');
  });

  await t.test('C33 owner transfer vs remove vs leave vs take-over: exactly one owner, never ownerless', async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Pending Pat')));
    const rs = await Promise.all([transfer(a, [g.ctx, g.members[b]]), transfer(a, [g.ctx, g.members[c]]), remove(a, [g.ctx, mid]), leave(c, [g.ctx]), leave(a, [g.ctx]), takeOver(b, [g.ctx])]);
    noInternal(rs);
    const owners = await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND role='owner' AND state='active'", [g.ctx]);
    assert.equal(owners, 1, `exactly one active owner after racing transfers: ${JSON.stringify(tally(rs))}`);
  });
  await t.test('B01 stale authorization: a second transfer by the ex-owner (queued behind the first) must fail', { todo: 'BUG B01: owner check runs before the context lock, so an ex-owner command queued behind transfer_owner still executes (two transfers => two owners)' }, async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const first = await open(a);
    must({ ok: true, v: await first.call('transfer_owner(uuid,uuid,uuid,text)', [g.ctx, g.members[b], id(), hashOf('x1')]) });
    const second = settled(transfer(a, [g.ctx, g.members[c]])); // passes the pre-lock owner check, then waits for the context lock
    await sleep(300); assert.equal(second.done, false, 'second transfer should be blocked on the context lock');
    await first.commit();
    const r = await second.p;
    const owners = await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND role='owner' AND state='active'", [g.ctx]);
    assert.equal(r.ok, false, `a transfer by someone who is no longer owner must be refused (active owners afterwards: ${owners})`);
    assert.equal(owners, 1);
  });
  await t.test('B02 stale authorization: ex-owner invite / member who left proposes, queued behind the lock', { todo: 'BUG B02: _can_read_context / owner checks happen before the context FOR UPDATE; a command that was already queued runs with revoked authority' }, async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const hold = await open(a); // transfer ownership a -> b and keep it open (holds the context lock)
    await hold.call('transfer_owner(uuid,uuid,uuid,text)', [g.ctx, g.members[b], id(), hashOf('t')]);
    const inviteAsExOwner = settled(inviteP(a, invitePayload(g.ctx, id(), 'Sneaky')));
    await sleep(300);
    await hold.commit();
    const r = await inviteAsExOwner.p;
    assert.equal(r.ok, false, 'ex-owner invite succeeded after ownership moved');
  });
  await t.test('B03 stale role: a member promoted to owner while their leave is queued can leave and orphan the split', { todo: 'BUG B03: leave_context reads the member row before locking the context; role/state are stale after the wait' }, async () => {
    const [a, b] = await users(2); const g = await group(a, [b]);
    const hold = await open(a);
    await hold.call('transfer_owner(uuid,uuid,uuid,text)', [g.ctx, g.members[b], id(), hashOf('t')]);
    const lv = settled(leave(b, [g.ctx])); // b is still a plain member when it reads its row
    await sleep(300); await hold.commit();
    const r = await lv.p;
    const owners = await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND role='owner' AND state='active'", [g.ctx]);
    assert.ok(!(r.ok && owners === 0), `owner b left right after being made owner; active owners=${owners}`);
  });
  await t.test('B04 double leave with two operation ids emits membership.left twice', { todo: 'BUG B04: leave_context does not re-check m.state after the context lock (read-before-lock), so two leaves both pass' }, async () => {
    const [a, b] = await users(2); const g = await group(a, [b]);
    const rs = await Promise.all([leave(b, [g.ctx]), leave(b, [g.ctx]), leave(b, [g.ctx])]);
    noInternal(rs);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.context_events WHERE context_id=$1 AND kind='membership.left'", [g.ctx]), 1, JSON.stringify(tally(rs)));
  });
  await t.test('B05 a member who has left can still propose an expense queued behind the lock', { todo: 'BUG B05: submit_proposal authorizes with _can_read_context before the context lock' }, async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const hold = await open(b); // b leaves, uncommitted
    await hold.call('leave_context(uuid,uuid,text)', [g.ctx, id(), hashOf('l')]);
    const p = proposal(g.ctx, g.members[a], [[g.members[a], 100], [g.members[c], 100]]);
    const late = settled(proposeP(b, p)); await sleep(300);
    await hold.commit();
    const r = await late.p;
    assert.equal(r.ok, false, 'a departed member added an expense to the split');
  });

  await t.test('C34 rename vs rename vs delete(remove); same name from two members; invite same name twice', async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Pending Pete')));
    const rs = await Promise.all([
      renameP(b, { contextId: g.ctx, memberId: g.members[b], displayName: 'Sunny' }), renameP(c, { contextId: g.ctx, memberId: g.members[c], displayName: 'sunny' }),
      renameP(a, { contextId: g.ctx, memberId: mid, displayName: 'SUNNY' }), remove(a, [g.ctx, mid]),
      inviteP(a, invitePayload(g.ctx, id(), 'Sunny')), inviteP(a, invitePayload(g.ctx, id(), 'Sunny')),
    ]);
    noInternal(rs);
    assert.ok(rs.filter((x) => x.ok).length <= 3, JSON.stringify(tally(rs)));
    await invariants('C34'); // label-duplicate invariant is part of invariants()
    // rename racing with remove of the same invited member
    const m2 = id(); must(await inviteP(a, invitePayload(g.ctx, m2, 'Gone Soon')));
    const rs2 = await Promise.all([renameP(a, { contextId: g.ctx, memberId: m2, displayName: 'Now Renamed' }), remove(a, [g.ctx, m2])]);
    noInternal(rs2);
    await invariants('C34b');
  });

  await t.test('C35 two owners approve one join request; join approve vs link revoke vs expiry', async () => {
    const [a, a2, c] = await users(3); const g = await group(a, [a2]);
    await q("UPDATE shared_expenses.members SET role='owner' WHERE member_id=$1", [g.members[a2]]); // synthetic second owner
    const tok = tokenOf(); must(await linkCreate(a, g.ctx, tok));
    const inv = must(await claim(c, tok)).invitationId;
    const rs = await Promise.all([respondInv(a, inv, true), respondInv(a2, inv, true), respondInv(a2, inv, false), respondInv(a, inv, true)]);
    noInternal(rs);
    assert.equal(rs.filter((x) => x.ok).length, 1, JSON.stringify(tally(rs)));
    assert.equal(rs.filter((x) => !x.ok).every((x) => x.message === 'invitation_conflict'), true, JSON.stringify(tally(rs)));
    t.diagnostic('C35 outcomes ' + JSON.stringify(tally(rs)));
    const winner = rs.find((x) => x.ok).v.status; // approve and reject race: whichever wins is final, the loser is invitation_conflict
    assert.ok(['joined', 'rejected'].includes(winner));
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.context_events WHERE context_id=$1 AND kind='membership.claimed'", [g.ctx]), winner === 'joined' ? 1 : 0);
    // approve vs expiry of the request vs revoke
    const d = await user(); const inv2 = must(await claim(d, tok)).invitationId;
    const race = await Promise.all([respondInv(a, inv2, true), linkRevoke(a, g.ctx), q("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp() WHERE invitation_id=$1", [inv2]).then(() => ({ ok: true }))]);
    noInternal(race.filter((x) => x.message !== undefined));
    const st = await one('SELECT i.state,m.state ms,m.profile_id FROM shared_expenses.invitations i JOIN shared_expenses.members m USING(context_id,member_id) WHERE i.invitation_id=$1', [inv2]);
    assert.ok((st.state === 'joined' && st.ms === 'active' && st.profile_id === d) || (st.state === 'awaiting_owner' && st.ms === 'invited'), JSON.stringify(st));
    await invariants('C35');
  });

  await t.test('C36 claimant cap of 10 group-link requests per hour holds when 16 claims into different groups are released at the same instant', { todo: 'BUG B06: the 10-per-hour group-link claim cap is counted without a per-claimant lock; claims into DIFFERENT groups race past it' }, async () => {
    const [c] = await users(1);
    const owners = await users(16); const toks = [], holds = [];
    for (const o of owners) { const g = await group(o); const tok = tokenOf(); must(await linkCreate(o, g.ctx, tok)); toks.push(tok); const h = await open(null, { role: false }); await h.c.query('SELECT 1 FROM shared_expenses.contexts WHERE context_id=$1 FOR UPDATE', [g.ctx]); holds.push(h); }
    const running = toks.map((tok) => settled(claim(c, tok)));
    await sleep(900); // all claimants are parked on their context lock, after `_operation`, before counting
    await Promise.all(holds.map((h) => h.commit()));
    const rs = await Promise.all(running.map((r) => r.p));
    noInternal(rs);
    const made = await num('SELECT count(*) n FROM shared_expenses.invitations WHERE claimed_profile_id=$1 AND via_group_link', [c]);
    assert.ok(made <= 10, `claimant created ${made} requests in one hour (cap 10): ${JSON.stringify(tally(rs))}`);
  });
  await t.test('C36b claim vs claim by the same user into ONE group: one request', async () => {
    const [a, c] = await users(2); const g = await group(a); const tok = tokenOf(); must(await linkCreate(a, g.ctx, tok));
    const rs = await Promise.all(Array.from({ length: 12 }, () => claim(c, tok)));
    noInternal(rs);
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1 AND claimed_profile_id=$2', [g.ctx, c]), 1);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND state='invited'", [g.ctx]), 1);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.context_events WHERE context_id=$1 AND kind='membership.requested'", [g.ctx]), 1);
    await invariants('C36b');
  });

  await t.test('C37 invite the same phone twice / same member twice', async () => {
    const [a] = await users(1); const g = await group(a); const phone = sha('same-phone');
    const mk = async () => { const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Ph ' + mid.slice(0, 4)))); return mid; };
    const m1 = await mk(), m2 = await mk();
    const mkInv = (mid) => { const inv = id(); const p = { invitationId: inv, contextId: g.ctx, memberId: mid, targetPhoneHash: phone, tokenHash: sha('t' + inv) }; return call(a, 'create_invitation(jsonb,text)', [p, hashOf(p)]); };
    const rs = await Promise.all([mkInv(m1), mkInv(m2)]);
    noInternal(rs);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1 AND target_phone_hash=$2 AND state='open'", [g.ctx, phone]), 1, 'one open invitation per number per split: ' + JSON.stringify(tally(rs)));
  });

  await t.test('C38 create friend with the same number/name from two devices', async () => {
    const [a] = await users(1);
    const rs = await Promise.all(Array.from({ length: 8 }, (_, i) => createCtx(a, { kind: 'direct', name: i % 2 ? 'Ravi' : ' ravi ' })));
    noInternal(rs);
    assert.equal(rs.filter((x) => x.ok).length, 1, JSON.stringify(tally(rs)));
    for (const r of rs.filter((x) => !x.ok)) assert.equal(r.message, 'friend_name_taken');
    // different creators may use the same friend name (the list is per creator)
    const [b] = await users(1);
    must(await createCtx(b, { kind: 'direct', name: 'Ravi' }));
    // two devices, SAME context id, different operation ids: PK collision, not a duplicate
    const ctx = id(); const dev = await Promise.all([createCtx(a, { ctx, kind: 'group', name: 'Dev 1' }), createCtx(a, { ctx, kind: 'group', name: 'Dev 2' })]);
    noInternal(dev);
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.contexts WHERE context_id=$1', [ctx]), 1);
    await invariants('C38');
  });

  // ================================================================== E. caps under parallel load
  async function pendingRequests(owner, ctx, n, { shared = true, startMask = 1000 } = {}) {
    const out = [];
    for (let i = 0; i < n; i++) {
      const claimant = await user(); const mid = id(), inv = id();
      await q("INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) VALUES($1,$2,NULL,'member','invited',$3)", [ctx, mid, 'Req ' + i + ' ' + mid.slice(0, 4)]);
      await q(`INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,claimed_profile_id,verified_phone_suffix,state,via_group_link,phone_share,claimant_phone_enc,claimant_phone_key_id,claimant_phone_hash,claimant_phone_cc,claimant_phone_mask,phone_captured_at)
        VALUES($1,$2,$3,$4,$5,$6,$7,'awaiting_owner',true,$8,$9,$10,$11,'+91',$12,clock_timestamp())`,
      [inv, ctx, mid, owner, sha('x' + inv), claimant, String(startMask + i), shared ? 'shared' : 'declined', shared ? Buffer.alloc(40, i + 1) : null, shared ? 'k1' : null, shared ? sha('p' + inv) : null, '+91 ••••• ' + (startMask + i)]);
      out.push({ inv, claimant, mid });
    }
    return out;
  }
  await t.test('C50 group-link 20-pending cap: 50 parallel claimants => exactly 20 pass', async () => {
    const [a] = await users(1); const g = await group(a); const tok = tokenOf(); must(await linkCreate(a, g.ctx, tok));
    const cs = await users(50);
    const rs = await Promise.all(cs.map((u) => claim(u, tok)));
    noInternal(rs);
    assert.deepEqual(tally(rs), { ok: 20, join_requests_full: 30 });
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1 AND state='awaiting_owner'", [g.ctx]), 20);
    await invariants('C50');
  });
  await t.test('C51 member limit 200 under parallel invites and parallel link claims', async () => {
    const [a] = await users(1); const g = await group(a);
    await q("INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) SELECT $1,gen_random_uuid(),NULL,'member','left','old '||g FROM generate_series(1,195) g", [g.ctx]);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND state<>'declined'", [g.ctx]), 196);
    const rs = await Promise.all(Array.from({ length: 20 }, (_, i) => inviteP(a, invitePayload(g.ctx, id(), 'Cap ' + i))));
    noInternal(rs);
    assert.deepEqual(tally(rs), { ok: 4, context_member_limit: 16 });
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND state<>'declined'", [g.ctx]), 200);
    const g2 = await group(a); const tok = tokenOf(); must(await linkCreate(a, g2.ctx, tok));
    await q("INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) SELECT $1,gen_random_uuid(),NULL,'member','left','old '||g FROM generate_series(1,196) g", [g2.ctx]);
    const cs = await users(15);
    const rs2 = await Promise.all(cs.map((u) => claim(u, tok)));
    noInternal(rs2);
    assert.deepEqual(tally(rs2), { ok: 3, context_member_limit: 12 });
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.members WHERE context_id=$1 AND state<>'declined'", [g2.ctx]), 200);
  });
  await t.test('C52 reveal cap 5/h: 20 parallel reveals disclose at most 5 ciphertexts', async () => {
    const [a] = await users(1); const g = await group(a); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [a, sha('owner-phone' + a)]);
    const reqs = await pendingRequests(a, g.ctx, 20);
    const rs = await Promise.all(reqs.map((r) => call(a, 'reveal_claimant_phone(uuid)', [r.inv])));
    noInternal(rs);
    const disclosed = rs.filter((x) => x.ok && x.v.enc).length;
    assert.equal(disclosed, 5, JSON.stringify(rs.filter((x) => x.ok && !x.v.enc).map((x) => x.v.error).slice(0, 3)));
    assert.equal(rs.filter((x) => x.ok && x.v.error === 'reveal_rate_limited').length, 15);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.phone_reveals WHERE owner_profile_id=$1 AND via='tap'", [a]), 5, 'one audit row per disclosure, none more');
    // same request revealed 12 times in parallel still counts every disclosure
    const [b] = await users(1); const g2 = await group(b); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [b, sha('owner-phone' + b)]);
    const [one1] = await pendingRequests(b, g2.ctx, 1);
    const rs2 = await Promise.all(Array.from({ length: 12 }, () => call(b, 'reveal_claimant_phone(uuid)', [one1.inv])));
    assert.equal(rs2.filter((x) => x.ok && x.v.enc).length, 5);
    // 30/day cap: age 29 rows by an hour and one more, then parallel
    const [c] = await users(1); const g3 = await group(c); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [c, sha('owner-phone' + c)]);
    await q("INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via,at) SELECT gen_random_uuid(),$1,'tap',clock_timestamp()-interval '3 hours' FROM generate_series(1,28)", [c]);
    const reqs3 = await pendingRequests(c, g3.ctx, 8);
    const rs3 = await Promise.all(reqs3.map((r) => call(c, 'reveal_claimant_phone(uuid)', [r.inv])));
    assert.equal(rs3.filter((x) => x.ok && x.v.enc).length, 2, 'daily cap 30 leaves 2 of 8');
  });
  await t.test('C53 check-phone 3-attempt cap per request and 20/day per owner under parallel load', async () => {
    const [a] = await users(1); const g = await group(a); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [a, sha('owner-phone' + a)]);
    const [r1] = await pendingRequests(a, g.ctx, 1);
    const rs = await Promise.all(Array.from({ length: 12 }, (_, i) => call(a, 'check_claimant_phone(uuid,text)', [r1.inv, sha('guess' + i)])));
    noInternal(rs);
    assert.equal(rs.filter((x) => x.ok && x.v.matches === false).length, 3, JSON.stringify(rs.map((x) => x.ok ? x.v : x.message)));
    assert.equal(rs.filter((x) => x.ok && x.v.error === 'check_attempts_exhausted').length, 9);
    assert.equal((await one('SELECT phone_check_attempts a FROM shared_expenses.invitations WHERE invitation_id=$1', [r1.inv])).a, 3);
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.phone_reveals WHERE invitation_id=$1 AND via='check'", [r1.inv]), 3);
    const [b] = await users(1); const g2 = await group(b); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [b, sha('owner-phone' + b)]);
    const many = await pendingRequests(b, g2.ctx, 12);
    const rs2 = await Promise.all(many.flatMap((r, i) => [0, 1].map((k) => call(b, 'check_claimant_phone(uuid,text)', [r.inv, sha('g' + i + k)]))));
    noInternal(rs2);
    assert.equal(rs2.filter((x) => x.ok && typeof x.v.matches === 'boolean').length, 20, 'daily cap of 20 audited checks: ' + JSON.stringify(tally(rs2.map((x) => (x.ok ? { ok: true } : x)))));
  });
  await t.test('C54 directory lookup cap 25/day under 40 parallel lookups', async () => {
    const [a, b] = await users(2); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [b, sha('b-phone')]);
    const rs = await Promise.all(Array.from({ length: 40 }, (_, i) => call(a, 'lookup_phone(text)', [i % 2 ? sha('b-phone') : sha('other' + i)])));
    assert.equal(rs.filter((x) => x.ok).length, 25, JSON.stringify(tally(rs)));
    assert.equal(rs.filter((x) => !x.ok).every((x) => x.message === 'lookup_rate_limited'), true);
  });
  await t.test('C55 invitation-creation cap 50/hour per issuer holds across different splits in parallel', { todo: 'BUG B07: the 50/hour invitation cap is counted per issuer without an issuer-level lock; creations in different splits race past it' }, async () => {
    const [a] = await users(1); const gs = [];
    for (let i = 0; i < 6; i++) gs.push(await group(a));
    const jobs = [];
    for (const g of gs) for (let k = 0; k < 12; k++) jobs.push([g, id()]);
    // pre-create invited members, then issue 72 invitations in parallel across 6 splits
    const prepared = [];
    for (const [g, mid] of jobs) { must(await inviteP(a, invitePayload(g.ctx, mid, 'P' + mid.slice(0, 6)))); prepared.push([g, mid]); }
    const rs = await Promise.all(prepared.map(([g, mid]) => { const inv = id(); const p = { invitationId: inv, contextId: g.ctx, memberId: mid, targetPhoneHash: null, tokenHash: sha('t' + inv) }; return call(a, 'create_invitation(jsonb,text)', [p, hashOf(p)]); }));
    noInternal(rs);
    assert.ok(await num("SELECT count(*) n FROM shared_expenses.invitations WHERE issuer_profile_id=$1 AND created_at>clock_timestamp()-interval '1 hour'", [a]) <= 50, JSON.stringify(tally(rs)));
  });
  await t.test('C56 sequential 10 claims is the cap (control for C36)', async () => {
    const [c] = await users(1); const made = [];
    for (let i = 0; i < 12; i++) { const o = await user(); const g = await group(o); const tok = tokenOf(); must(await linkCreate(o, g.ctx, tok)); made.push(await claim(c, tok)); }
    assert.deepEqual(tally(made), { ok: 10, invitation_rate_limited: 2 });
  });

  await t.test('B11 a group-link claim that read the link before it was revoked still creates a request after the revoke committed', { todo: 'BUG B11: revoke_group_link takes no context lock and _claim_group_link reads the link before its context lock, so a claim queued behind any context-lock holder survives the revoke (and its number is not purged by it)' }, async () => {
    const [a, c] = await users(2); const g = await group(a); const tok = tokenOf(); must(await linkCreate(a, g.ctx, tok));
    const hold = await open(null, { role: false });
    await hold.c.query('SELECT 1 FROM shared_expenses.contexts WHERE context_id=$1 FOR UPDATE', [g.ctx]);
    const cl = settled(claim(c, tok)); await sleep(400); assert.equal(cl.done, false, 'claim parked on the context lock');
    must(await linkRevoke(a, g.ctx)); // does not need the context lock
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.group_links WHERE context_id=$1', [g.ctx]), 0);
    await hold.commit();
    const r = await cl.p;
    assert.equal(r.ok, false, 'a claim must not succeed after the link was revoked');
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1 AND via_group_link", [g.ctx]), 0);
  });
  await t.test('B12 a member can leave while a pending edit still needs their approval, stranding that edit forever', { todo: 'BUG B12: leave_context only checks balances and never-accepted expenses; a pending EDIT of an accepted expense that requires the leaver can never be approved or withdrawn afterwards' }, async () => {
    const [a, b] = await users(2); const g = await group(a, [b]);
    const p = proposal(g.ctx, g.members[a], [[g.members[a], 500], [g.members[b], 500]]); must(await proposeP(a, p));
    must(await respondExpP(b, { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId, decision: 'approve' }));
    const sr = { contextId: g.ctx, settlementId: id(), payerMemberId: g.members[b], receiverMemberId: g.members[a], amountMinor: '500', currency: 'INR', method: 'cash', paidOn: '2026-11-03' };
    must(await reportP(b, sr)); must(await respondSetP(a, { contextId: g.ctx, settlementId: sr.settlementId, decision: 'confirm' }));
    const edit = proposal(g.ctx, g.members[a], [[g.members[a], 300], [g.members[b], 300]], { expense: p.expenseId, head: p.revisionId }); must(await proposeP(a, edit));
    const l = await leave(b, [g.ctx]);
    assert.equal(l.ok, false, 'leaving with a pending edit that needs your approval should be refused (settle_first)');
  });

  // ================================================================== F. lock ordering / deadlocks
  await t.test('L01 reveal vs resolve: a stale read taken before the per-owner lock discloses a ciphertext that was already purged', { todo: 'BUG B08: reveal_claimant_phone reads the invitation BEFORE pg_advisory_xact_lock(reveal:owner) and never re-reads it, so it can return (and audit) a number for a request that was resolved + purged while it waited' }, async () => {
    const [a] = await users(1); const g = await group(a); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [a, sha('owner-phone' + a)]);
    const [i1, i2] = await pendingRequests(a, g.ctx, 2);
    const holder = await open(a);
    const first = await holder.call('reveal_claimant_phone(uuid)', [i1.inv]); // holds the per-owner reveal lock
    assert.ok(first.enc);
    const stale = settled(call(a, 'reveal_claimant_phone(uuid)', [i2.inv])); // reads i2, then waits on the advisory lock
    await sleep(400); assert.equal(stale.done, false);
    must(await respondInv(a, i2.inv, false)); // resolved + purged meanwhile (separate session, no advisory lock involved)
    assert.equal((await one('SELECT claimant_phone_enc IS NULL AS gone FROM shared_expenses.invitations WHERE invitation_id=$1', [i2.inv])).gone, true);
    await holder.commit();
    const r = await stale.p;
    assert.ok(!(r.ok && r.v.enc), 'ciphertext of a resolved+purged request was handed out');
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.phone_reveals WHERE invitation_id=$1", [i2.inv]), r.ok && r.v.enc ? 0 : 0, 'no audit row for a disclosure that did not happen');
  });
  await t.test('L02 check-phone vs resolve: row lock first, so a resolved request is never answered', async () => {
    const [a] = await users(1); const g = await group(a); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [a, sha('owner-phone' + a)]);
    const [i1] = await pendingRequests(a, g.ctx, 1);
    const resolver = await open(a);
    await resolver.call('respond_invitation(uuid,boolean,uuid,text)', [i1.inv, false, id(), hashOf('rj')]);
    const chk = settled(call(a, 'check_claimant_phone(uuid,text)', [i1.inv, sha('x')]));
    await sleep(300); assert.equal(chk.done, false);
    await resolver.commit();
    const r = await chk.p; assert.equal(r.ok, true); assert.equal(r.v.error, 'phone_not_available');
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.phone_reveals WHERE invitation_id=$1", [i1.inv]), 0);
  });
  await t.test('L03 lock inversion claim_invitation (lazy purge row lock -> context lock) vs respond_invitation (context lock -> row lock) deadlocks cleanly', async () => {
    const [a, c] = await users(2); const g = await group(a);
    const mid = id(); must(await inviteP(a, invitePayload(g.ctx, mid, 'Linkee')));
    const inv = id(), tokenHash = sha('tok' + inv); const p = { invitationId: inv, contextId: g.ctx, memberId: mid, targetPhoneHash: null, tokenHash }; must(await call(a, 'create_invitation(jsonb,text)', [p, hashOf(p)]));
    const op = id(); must(await claim(c, tokenHash, { op: id() }));
    // give it a stored number, then expire it so the claimant's re-claim triggers the lazy purge
    await q("UPDATE shared_expenses.invitations SET phone_share='shared',claimant_phone_enc=$2,claimant_phone_key_id='k1',claimant_phone_hash=$3,claimant_phone_mask='+91 •••••',expires_at=clock_timestamp()-interval '1 minute' WHERE invitation_id=$1", [inv, Buffer.alloc(40, 5), sha('z')]);
    // a raw session pins the claimant's receipt slot so the claim stalls AFTER its purge (row lock held) and BEFORE the context lock
    const pin = await open(null, { role: false });
    await pin.c.query("INSERT INTO shared_expenses.operation_receipts(actor_profile_id,operation_id,command_kind,request_hash,input_hash,context_id) VALUES($1,$2,'invitation.claim',$3,$3,$4)", [c, op, sha('pin'), g.ctx]);
    const cl = settled(claim(c, tokenHash, { op })); await sleep(500); assert.equal(cl.done, false);
    const rs = settled(respondInv(a, inv, true)); await sleep(500); // owner takes the context lock, then wants the invitation row
    await pin.rollback(); // claimant proceeds to the context lock
    const out = await Promise.all([cl.p, rs.p]);
    noInternal(out);
    const dead = out.filter((x) => !x.ok && x.code === '40P01');
    assert.equal(dead.length, 1, 'documented lock inversion: exactly one victim, surfaced as 40P01 (API 409 retryable_conflict): ' + JSON.stringify(out.map((x) => x.ok ? 'ok' : x.message)));
    assert.equal(httpStatus(dead[0]), 409);
    await invariants('L03');
  });
  await t.test('L04 concurrent number swap in the phone directory deadlocks cleanly (40P01 -> 409), no 500', async () => {
    const [a, b] = await users(2); const ha = sha('ha' + a), hb = sha('hb' + b);
    must(await call(a, 'register_phone(text,boolean)', [ha, true])); must(await call(b, 'register_phone(text,boolean)', [hb, true]));
    let dead = 0, ok = 0;
    for (let i = 0; i < 6; i++) {
      const [x, y] = i % 2 ? [ha, hb] : [hb, ha];
      const rs = await Promise.all([callRetry(a, 'register_phone(text,boolean)', [x, true], 1), callRetry(b, 'register_phone(text,boolean)', [y, true], 1)]);
      noInternal(rs); for (const r of rs) { if (!r.ok && r.code === '40P01') dead++; if (r.ok) ok++; }
      await q('DELETE FROM shared_expenses.phone_directory WHERE profile_id IN ($1,$2)', [a, b]);
      must(await call(a, 'register_phone(text,boolean)', [ha, true])); must(await call(b, 'register_phone(text,boolean)', [hb, true]));
    }
    assert.ok(ok > 0);
    t.diagnostic(`directory swap: ${dead} deadlock victims in 6 rounds`);
  });

  // random mixed workload ------------------------------------------------------------------
  function prng(seed) { let s = seed >>> 0; return () => { s = (s + 0x6D2B79F5) >>> 0; let x = Math.imul(s ^ (s >>> 15), 1 | s); x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x; return ((x ^ (x >>> 14)) >>> 0) / 4294967296; }; }
  async function workload({ seed, workers, ops, label }) {
    const rnd = prng(seed); const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
    const us = await users(14);
    const groups = []; for (let i = 0; i < 4; i++) groups.push(await group(us[i], us.slice(4, 4 + 5 + i)));
    const links = new Map();
    for (const g of groups) { const tok = tokenOf(); must(await linkCreate(g.owner, g.ctx, tok)); links.set(g.ctx, tok); }
    const names = ['Asha', 'Bhanu', 'Chitra', 'Dev', 'Esha', 'Farhan'];
    const log = []; const errors = [];
    let issued = 0;
    const record = (kind, r) => { log.push({ kind, ok: r.ok, message: r.message }); if (!r.ok) errors.push(r); return r; };
    const flip = { v: 0 };
    async function oneOp(w) {
      const g = pick(groups), mems = Object.keys(g.members), who = pick(mems), other = pick(mems);
      const x = rnd();
      const R = (kind, r) => record(kind, r);
      if (x < 0.20) { // propose
        const parts = [who, other, pick(mems)].filter((v, i, a) => a.indexOf(v) === i);
        const amt = 100 * (1 + Math.floor(rnd() * 9)); const per = Math.floor(amt / parts.length);
        const shares = parts.map((pu, i) => [g.members[pu], i === 0 ? amt - per * (parts.length - 1) : per]);
        const p = proposal(g.ctx, g.members[who], shares, { total: amt }); const op = id();
        const r = R('propose', await callRetry(who, 'submit_proposal(jsonb,uuid,text)', [p, op, hashOf(p)]));
        if (rnd() < 0.2) R('propose-replay', await callRetry(who, 'submit_proposal(jsonb,uuid,text)', [p, op, hashOf(p)]));
        return r;
      }
      if (x < 0.40) { // respond to some pending revision of mine
        const row = await one(`SELECT rm.context_id,rm.expense_id,rm.revision_id FROM shared_expenses.revision_members rm JOIN shared_expenses.expenses e ON e.context_id=rm.context_id AND e.expense_id=rm.expense_id
          WHERE rm.approver_profile_id=$1 AND rm.approval_required AND e.accepted_revision_id IS DISTINCT FROM rm.revision_id AND NOT EXISTS(SELECT FROM shared_expenses.revision_approvals a WHERE a.context_id=rm.context_id AND a.revision_id=rm.revision_id AND a.actor_profile_id=$1)
          ORDER BY random() LIMIT 1`, [who]);
        if (!row) return null;
        const p = { contextId: row.context_id, expenseId: row.expense_id, revisionId: row.revision_id, decision: rnd() < 0.85 ? 'approve' : 'reject' }; const op = id();
        const r = R('respond', await callRetry(who, 'respond_expense(jsonb,uuid,text)', [p, op, hashOf(p)]));
        if (rnd() < 0.2) R('respond-replay', await callRetry(who, 'respond_expense(jsonb,uuid,text)', [p, op, hashOf(p)]));
        return r;
      }
      if (x < 0.50 && who !== other) { // settlement report
        const p = { contextId: g.ctx, settlementId: id(), payerMemberId: g.members[who], receiverMemberId: g.members[other], amountMinor: String(50 * (1 + Math.floor(rnd() * 5))), currency: 'INR', method: 'cash', paidOn: '2026-11-03' };
        return R('report', await callRetry(who, 'report_settlement(jsonb,uuid,text)', [p, id(), hashOf(p)]));
      }
      if (x < 0.60) { // confirm / reject a pending settlement
        const row = await one(`SELECT sr.context_id,sr.settlement_id,m.profile_id FROM shared_expenses.settlement_reports sr JOIN shared_expenses.members m ON m.context_id=sr.context_id AND m.member_id=sr.receiver_member_id
          WHERE NOT EXISTS(SELECT FROM shared_expenses.settlement_events e WHERE e.context_id=sr.context_id AND e.settlement_id=sr.settlement_id) ORDER BY random() LIMIT 1`);
        if (!row || !row.profile_id) return null;
        const p = { contextId: row.context_id, settlementId: row.settlement_id, decision: rnd() < 0.8 ? 'confirm' : 'reject' };
        return R('settle', await callRetry(row.profile_id, 'respond_settlement(jsonb,uuid,text)', [p, id(), hashOf(p)]));
      }
      if (x < 0.68) { // rename (names collide on purpose)
        const p = { contextId: g.ctx, memberId: g.members[other], displayName: pick(names) };
        return R('rename', await callRetry(who, 'rename_member(jsonb,uuid,text)', [p, id(), hashOf(p)]));
      }
      if (x < 0.74) { const p = invitePayload(g.ctx, id(), pick(names)); return R('invite', await callRetry(g.owner, 'invite_member(jsonb,uuid,text)', [p, id(), hashOf(p)])); }
      if (x < 0.80) { // create direct friend (name collisions)
        return R('friend', await callRetry(pick(us), 'create_context(uuid,text,text,uuid,text)', [id(), 'direct', pick(names), id(), sha('h' + rnd())]));
      }
      if (x < 0.85) { // join through the link then approve the oldest pending request
        const claimant = pick(us.slice(10)); R('claim', await callRetry(claimant, 'claim_invitation(text,text,text,uuid,text,text)', [links.get(g.ctx), null, null, id(), sha('c' + rnd()), null]));
        const row = await one("SELECT invitation_id FROM shared_expenses.invitations WHERE context_id=$1 AND state='awaiting_owner' ORDER BY created_at LIMIT 1", [g.ctx]);
        if (row && rnd() < 0.7) R('approve-join', await callRetry(g.owner, 'respond_invitation(uuid,boolean,uuid,text)', [row.invitation_id, rnd() < 0.8, id(), sha('r' + rnd())]));
        return null;
      }
      if (x < 0.88) return R('leave', await callRetry(who, 'leave_context(uuid,uuid,text)', [g.ctx, id(), sha('l' + rnd())]));
      if (x < 0.91) { const t2 = pick(mems); return R('transfer', await callRetry(g.owner, 'transfer_owner(uuid,uuid,uuid,text)', [g.ctx, g.members[t2], id(), sha('o' + rnd())])); }
      if (x < 0.94) { const lk = tokenOf(); links.set(g.ctx, lk); return R('relink', await callRetry(g.owner, 'create_group_link(uuid,text,uuid,text)', [g.ctx, lk, id(), sha('k' + rnd())])); }
      if (x < 0.96) return R('remove', await callRetry(g.owner, 'remove_member(uuid,uuid,uuid,text)', [g.ctx, pick(Object.values(g.members)), id(), sha('m' + rnd())]));
      if (x < 0.98) { flip.v++; await setFlags({ writes: flip.v % 2 === 0 }); return null; }
      return R('register', await callRetry(pick(us), 'register_phone(text,boolean)', [sha('ph' + Math.floor(rnd() * 5)), true], 2));
    }
    const started = Date.now();
    await Promise.all(Array.from({ length: workers }, async (_, w) => { while (issued < ops) { issued++; await oneOp(w).catch((e) => errors.push({ ok: false, message: 'EXC ' + e.message, code: e.code })); } }));
    await setFlags({});
    const kinds = {}; for (const l of log) { const k = l.ok ? 'ok' : l.message; kinds[k] = (kinds[k] || 0) + 1; }
    t.diagnostic(`${label}: seed=${seed} workers=${workers} ops=${log.length} in ${Date.now() - started}ms, deadlocks=${stats.deadlocks} serial=${stats.serialization} outcomes=${JSON.stringify(kinds)}`);
    const leaked = errors.filter((e) => e.message?.startsWith('EXC ') || httpStatus(e) === 500);
    assert.deepEqual(leaked.map((e) => e.message + ':' + e.code), [], 'no internal error may leak as a 500');
    const unretried = errors.filter((e) => ['40P01'].includes(e.code));
    assert.equal(unretried.length, 0, 'deadlock victims must be absorbed by client retry');
    await invariants(label);
    return { kinds, groups };
  }
  await t.test('L10 mixed random workload: 16 workers x 700 ops incl. replays, flag flips, friend-name locks', async () => {
    await workload({ seed: 20261107, workers: 16, ops: 700, label: 'L10' });
  });
  await t.test('L11 mixed random workload: 20 workers x 900 ops, different seed', async () => {
    await workload({ seed: 7, workers: 20, ops: 900, label: 'L11' });
  });

  await t.test('L12 friend-name locks: 14 workers hammering direct splits (create / invite / rename with colliding names) never deadlock into a 500 and keep one split per friend name', async () => {
    const creators = await users(3), others = await users(6); const names = ['Ravi', 'Sita', 'Tara', 'Umesh', 'Vik'];
    const rnd = prng(99); const pick = (a) => a[Math.floor(rnd() * a.length)];
    const mine = new Map(); // creator -> [{ctx,member}]
    for (const c of creators) mine.set(c, []);
    let todo = 420; const errs = [];
    await Promise.all(Array.from({ length: 14 }, async () => {
      while (todo-- > 0) {
        const c = pick(creators), x = rnd();
        let r;
        if (x < 0.35) { const ctx = id(); r = await callRetry(c, 'create_context(uuid,text,text,uuid,text)', [ctx, 'direct', pick(names), id(), sha('f' + rnd())]); if (r.ok) mine.get(c).push({ ctx, member: null }); }
        else if (x < 0.6 && mine.get(c).length) { const e = pick(mine.get(c)); const mid = id(); const o = pick(others); const p = invitePayload(e.ctx, mid, pick(names), x < 0.5 ? o : undefined); r = await callRetry(c, 'invite_member(jsonb,uuid,text)', [p, id(), hashOf(p)]); if (r.ok) e.member = mid; }
        else if (mine.get(c).length) { const e = pick(mine.get(c)); if (!e.member) continue; const p = { contextId: e.ctx, memberId: e.member, displayName: pick(names) }; r = await callRetry(c, 'rename_member(jsonb,uuid,text)', [p, id(), hashOf(p)]); }
        if (r && !r.ok) errs.push(r);
      }
    }));
    noInternal(errs);
    assert.equal(errs.filter((e) => e.code === '40P01').length, 0, 'deadlock victims must be absorbed by retry');
    t.diagnostic('L12 outcomes: ' + JSON.stringify(tally(errs.map((e) => e))) + ` deadlocks(retried)=${stats.deadlocks}`);
    // one split per friend name per creator
    const clash = await num(`SELECT count(*) n FROM shared_expenses.contexts c WHERE c.kind='direct' AND c.state='active' AND c.created_by=ANY($1::uuid[])
      AND shared_expenses._friend_context(c.created_by,c.context_id,shared_expenses._context_label(c.kind,c.name,c.created_by,c.created_by,c.context_id)) IS NOT NULL
      AND EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=c.context_id AND m.profile_id IS DISTINCT FROM c.created_by AND m.state IN ('active','invited'))`, [creators]);
    assert.equal(clash, 0, 'two live direct splits of one creator share a friend name');
    await invariants('L12');
  });

  // ================================================================== G. flag transitions
  await t.test('F01 accepted_writes off parks proposals as awaiting_activation; turning it on does NOT re-evaluate them (F5)', async () => {
    const [a, b] = await users(2); const g = await group(a, [b]);
    await setFlags({ writes: false });
    const p = proposal(g.ctx, g.members[a], [[g.members[a], 400], [g.members[b], 400]]); must(await proposeP(a, p));
    const approveOp = id(); const ap = { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId, decision: 'approve' };
    const parked = must(await respondExpP(b, ap, approveOp));
    assert.equal(parked.status, 'awaiting_activation');
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.journal_entries WHERE context_id=$1', [g.ctx]), 0);
    assert.equal((await events(g.ctx)).at(-1).kind, 'expense.responded', 'parked approval is not announced as accepted');
    await setFlags({});
    // nothing in the database re-evaluates parked revisions
    assert.equal((await one('SELECT accepted_revision_id r FROM shared_expenses.expenses WHERE expense_id=$1', [p.expenseId])).r, null);
    // replaying the OLD approval returns the stored (stale) answer and still does not accept
    const stale = must(await respondExpP(b, ap, approveOp)); assert.equal(stale.status, 'awaiting_activation');
    assert.equal((await one('SELECT accepted_revision_id r FROM shared_expenses.expenses WHERE expense_id=$1', [p.expenseId])).r, null);
    // a fresh operation by an approver (or the author) re-evaluates and accepts exactly once
    const rs = await Promise.all([respondExpP(b, ap), respondExpP(b, ap), respondExpP(a, ap)]);
    for (const r of rs) must(r);
    assert.equal(Number((await one('SELECT head_version h FROM shared_expenses.expenses WHERE expense_id=$1', [p.expenseId])).h), 1);
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.journal_entries WHERE context_id=$1', [g.ctx]), 1);
    await invariants('F01');
  });
  await t.test('F02 flag flips while a command is queued behind the context lock', async () => {
    const [a, b] = await users(2); const g = await group(a, [b]);
    const p = proposal(g.ctx, g.members[a], [[g.members[a], 400], [g.members[b], 400]]); must(await proposeP(a, p));
    const ap = { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId, decision: 'approve' };
    const hold = await q('SELECT 1').then(() => open(null, { role: false }));
    await hold.c.query('SELECT 1 FROM shared_expenses.contexts WHERE context_id=$1 FOR UPDATE', [g.ctx]);
    const queued = settled(respondExpP(b, ap)); await sleep(300); assert.equal(queued.done, false);
    await setFlags({ writes: false }); // flips while queued (checked after the lock)
    await hold.commit();
    const r = must(await queued.p);
    assert.equal(r.status, 'awaiting_activation', 'accepted_writes is read after the lock');
    assert.equal(await num('SELECT count(*) n FROM shared_expenses.journal_entries WHERE context_id=$1', [g.ctx]), 0);
    // reads off while queued: _require_proposals already passed, _can_read_context was evaluated earlier
    await setFlags({});
    const sr = { contextId: g.ctx, settlementId: id(), payerMemberId: g.members[b], receiverMemberId: g.members[a], amountMinor: '10', currency: 'INR', method: 'cash', paidOn: '2026-11-03' };
    must(await reportP(b, sr));
    const hold2 = await open(null, { role: false });
    await hold2.c.query('SELECT 1 FROM shared_expenses.contexts WHERE context_id=$1 FOR UPDATE', [g.ctx]);
    const queued2 = settled(respondSetP(a, { contextId: g.ctx, settlementId: sr.settlementId, decision: 'confirm' })); await sleep(300);
    await setFlags({ settle: false }); await hold2.commit();
    failsWith(await queued2.p, 'feature_disabled'); // confirm re-checks settlements_enabled after the lock
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.settlement_events WHERE settlement_id=$1", [sr.settlementId]), 0, 'refused confirm leaves no event (rolled back with its receipt)');
    // a reject is still allowed while settlements are off
    must(await respondSetP(a, { contextId: g.ctx, settlementId: sr.settlementId, decision: 'reject' }));
    await setFlags({});
    await invariants('F02');
  });
  await t.test('F03 reads/proposals off: every command (including leave, remove, link revoke) refuses with feature_disabled and writes nothing', async () => {
    const [a, b] = await users(2); const g = await group(a, [b]); const before = await evCount(g.ctx);
    for (const f of [{ reads: false }, { proposals: false }]) {
      await setFlags(f);
      const rs = await Promise.all([leave(b, [g.ctx]), remove(a, [g.ctx, id()]), linkRevoke(a, g.ctx), transfer(a, [g.ctx, g.members[b]]), takeOver(b, [g.ctx]),
        inviteP(a, invitePayload(g.ctx, id(), 'Nope')), createCtx(a), call(a, 'lookup_phone(text)', [sha('x')])]);
      for (const r of rs) failsWith(r, 'feature_disabled');
      assert.equal(await evCount(g.ctx), before);
    }
    await setFlags({});
    must(await leave(b, [g.ctx]));
  });
  await t.test('F04 capability change while many commands queue: result is always one of the two legal outcomes, never a half state', async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const ps = Array.from({ length: 6 }, (_, i) => proposal(g.ctx, g.members[a], [[g.members[a], 100 + i], [g.members[b], 100 + i]]));
    for (const p of ps) must(await proposeP(a, p));
    const flipper = (async () => { for (let i = 0; i < 12; i++) { await setFlags({ writes: i % 2 === 1 }); await sleep(8); } await setFlags({}); })();
    const rs = await Promise.all(ps.map((p) => respondExpP(b, { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId, decision: 'approve' })));
    await flipper;
    noInternal(rs);
    for (const [i, r] of rs.entries()) {
      must(r);
      const accepted = (await one('SELECT accepted_revision_id r FROM shared_expenses.expenses WHERE expense_id=$1', [ps[i].expenseId])).r === ps[i].revisionId;
      assert.equal(accepted, r.v.status === 'accepted', 'reported status matches stored head');
    }
    await invariants('F04');
  });

  // ================================================================== H. events / feed consistency
  await t.test('E01 every committed command emits exactly its events; profile streams are gapless and monotonic under concurrency', async () => {
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const base = await events(g.ctx);
    assert.deepEqual(base.map((e) => e.kind), ['context.created', 'member.invited', 'membership.responded', 'member.invited', 'membership.responded']);
    const ps = Array.from({ length: 9 }, (_, i) => proposal(g.ctx, g.members[a], [[g.members[a], 100 + i], [g.members[b], 100 + i]]));
    const rs = await Promise.all([...ps.map((p, i) => proposeP([a, b, c][i % 3 === 2 ? 0 : i % 3], p)), ...Array.from({ length: 6 }, (_, i) => renameP([a, b, c][i % 3], { contextId: g.ctx, memberId: g.members[[a, b, c][i % 3]], displayName: 'N' + i + [a, b, c][i % 3].slice(0, 3) }))]);
    noInternal(rs);
    const ok = rs.filter((r) => r.ok).length;
    const evs = await events(g.ctx);
    assert.equal(evs.length, base.length + ok, 'one event per successful command, none for failures');
    // each profile stream: contiguous and ordered consistently with the context sequence
    const bad = await num(`SELECT count(*) n FROM (SELECT profile_id,sequence,context_sequence,lag(context_sequence) OVER(PARTITION BY profile_id,context_id ORDER BY sequence) prev FROM shared_expenses.profile_events WHERE context_id=$1) x WHERE prev IS NOT NULL AND context_sequence<>prev+1`, [g.ctx]);
    assert.equal(bad, 0, 'per-split events appear in order, consecutively, on every member stream');
    await invariants('E01');
  });
  await t.test('E02 changes feed paged while writers are active: no event lost or skipped across page boundaries', { todo: 'BUG B15 (S1): pullProjectionChanges orders its final page by the TEXT alias profile_sequence ("10" < "2"), so once a profile stream passes sequence 9 a page can end past events 2..9 and the cursor skips them forever' }, async () => {
    const { pullProjectionChanges } = requireApi('./src/shared_expenses/queries');
    const [a, b, c] = await users(3); const g = await group(a, [b, c]);
    const readPage = async (u, after, limit) => {
      const cl = await pool.connect();
      try { await cl.query('BEGIN'); await cl.query('SET LOCAL ROLE app_user'); await cl.query("SELECT set_config('app.user_id',$1,true)", [u]); const r = await pullProjectionChanges(cl, u, { limit: String(limit), ...(after ? { after } : {}) }); await cl.query('COMMIT'); return r; }
      catch (e) { await cl.query('ROLLBACK').catch(() => {}); throw e; } finally { cl.release(); }
    };
    let stop = false; const written = [];
    const writers = [a, b, c].map((u, wi) => (async () => { for (let i = 0; i < 14; i++) { const r = await renameP(u, { contextId: g.ctx, memberId: g.members[u], displayName: `W${wi}x${i}` }); if (r.ok) written.push(r.v.sequence); } })());
    const seen = new Map(); let cursor = null, pages = 0, dupes = 0;
    const drain = async (limit) => {
      for (;;) {
        const pg = await readPage(b, cursor, limit); pages++;
        for (const rec of pg.records) if (rec.entity === 'activity') { if (seen.has(rec.id)) dupes++; seen.set(rec.id, rec); }
        if (pg.nextCursor) cursor = pg.nextCursor;
        if (!pg.hasMore && stop) return;
        if (!pg.hasMore) await sleep(5);
        if (pages > 4000) assert.fail('feed did not terminate');
      }
    };
    const reader = drain(3);
    await Promise.all(writers); stop = true; await reader;
    stop = true; await drain(3); // final exhaustive pass started strictly after the last commit
    const expected = (await q('SELECT ce.event_id FROM shared_expenses.profile_events pe JOIN shared_expenses.context_events ce ON ce.context_id=pe.context_id AND ce.sequence=pe.context_sequence WHERE pe.profile_id=$1 AND pe.context_id=$2', [b, g.ctx])).rows.map((r) => r.event_id);
    assert.ok(expected.length >= 40, 'reader stream has the writers events');
    const missing = expected.filter((e) => !seen.has(e));
    t.diagnostic(`feed: pages=${pages} duplicateRecords=${dupes} events=${expected.length}`);
    assert.deepEqual(missing, [], 'events never returned by the paged feed');
    await invariants('E02');
  });

  await t.test('E03 feed with mixed events (proposals, approvals, settlements) at page sizes 1, 2 and 7 loses nothing while a second group writes', { todo: 'BUG B15 (S1): pullProjectionChanges orders its final page by the TEXT alias profile_sequence ("10" < "2"), so once a profile stream passes sequence 9 a page can end past events 2..9 and the cursor skips them forever' }, async () => {
    const { pullProjectionChanges } = requireApi('./src/shared_expenses/queries');
    const [a, b, c] = await users(3); const g = await group(a, [b, c]); const other = await group(c, [a]);
    const page = async (u, after, limit) => {
      const cl = await pool.connect();
      try { await cl.query('BEGIN'); await cl.query('SET LOCAL ROLE app_user'); await cl.query("SELECT set_config('app.user_id',$1,true)", [u]); const r = await pullProjectionChanges(cl, u, { limit: String(limit), ...(after ? { after } : {}) }); await cl.query('COMMIT'); return r; }
      catch (e) { await cl.query('ROLLBACK').catch(() => {}); throw e; } finally { cl.release(); }
    };
    const work = (async () => {
      for (let i = 0; i < 6; i++) {
        const p = proposal(g.ctx, g.members[a], [[g.members[a], 100 + i], [g.members[b], 100 + i]]);
        must(await proposeP(a, p)); must(await respondExpP(b, { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId, decision: 'approve' }));
        const sr = { contextId: g.ctx, settlementId: id(), payerMemberId: g.members[b], receiverMemberId: g.members[a], amountMinor: '10', currency: 'INR', method: 'cash', paidOn: '2026-11-03' };
        must(await reportP(b, sr)); await respondSetP(a, { contextId: g.ctx, settlementId: sr.settlementId, decision: 'confirm' });
        await renameP(c, { contextId: other.ctx, memberId: other.members[c], displayName: 'Cee' + i });
      }
    })();
    const polled = new Map();
    const pump = async (limit, cursorRef, bag, until) => {
      for (let n = 0; n < 6000; n++) {
        const pg = await page(b, cursorRef.v, limit);
        for (const r of pg.records) if (r.entity === 'activity') bag.set(r.id, (bag.get(r.id) || 0) + 1);
        if (pg.nextCursor) cursorRef.v = pg.nextCursor;
        if (!pg.hasMore && until()) return n;
        if (!pg.hasMore) await sleep(5);
      }
      assert.fail('feed did not terminate');
    };
    let finished = false; work.then(() => { finished = true; });
    const live = pump(2, { v: null }, polled, () => finished);
    await work; await live;
    const bags = {};
    for (const limit of [1, 2, 7]) { const bag = new Map(); await pump(limit, { v: null }, bag, () => true); bags[limit] = bag; }
    const expected = (await q('SELECT ce.event_id FROM shared_expenses.profile_events pe JOIN shared_expenses.context_events ce ON ce.context_id=pe.context_id AND ce.sequence=pe.context_sequence WHERE pe.profile_id=$1', [b])).rows.map((r) => r.event_id);
    for (const [limit, bag] of Object.entries(bags)) assert.deepEqual(expected.filter((e) => !bag.has(e)), [], `limit ${limit}: events lost across page boundaries`);
    assert.deepEqual(expected.filter((e) => !polled.has(e)), [], 'live polling while writers run lost events');
    const dup = [...Object.values(bags).flatMap((bag) => [...bag.values()]), ...polled.values()].filter((n) => n > 1).length;
    t.diagnostic(`E03 events=${expected.length} duplicateActivityRecords=${dup}`);
    await invariants('E03');
  });

  const feedPage = async (u, after, limit) => {
    const { pullProjectionChanges } = requireApi('./src/shared_expenses/queries');
    const cl = await pool.connect();
    try { await cl.query('BEGIN'); await cl.query('SET LOCAL ROLE app_user'); await cl.query("SELECT set_config('app.user_id',$1,true)", [u]); const r = await pullProjectionChanges(cl, u, { ...(limit ? { limit: String(limit) } : {}), ...(after ? { after } : {}) }); await cl.query('COMMIT'); return r; }
    catch (e) { await cl.query('ROLLBACK').catch(() => {}); throw e; } finally { cl.release(); }
  };
  const drainFeed = async (u, limit) => { const seen = new Map(); let cur = null; for (let i = 0; i < 3000; i++) { const pg = await feedPage(u, cur, limit); for (const r of pg.records) if (r.entity === 'activity') seen.set(r.id, (seen.get(r.id) || 0) + 1); if (pg.nextCursor) cur = pg.nextCursor; if (!pg.hasMore) break; } return seen; };
  const streamEvents = async (u) => (await q('SELECT ce.event_id FROM shared_expenses.profile_events pe JOIN shared_expenses.context_events ce ON ce.context_id=pe.context_id AND ce.sequence=pe.context_sequence WHERE pe.profile_id=$1', [u])).rows.map((r) => r.event_id);
  await t.test('E04 control: a profile stream that never passes sequence 9 pages without loss at every page size', async () => {
    const [a, b] = await users(2); const g = await group(a, [b]);
    for (let i = 0; i < 3; i++) must(await renameP(b, { contextId: g.ctx, memberId: g.members[b], displayName: 'Bee' + i }));
    const expected = await streamEvents(b); assert.ok(expected.length < 10);
    for (const limit of [1, 2, 3, 50]) { const seen = await drainFeed(b, limit); assert.deepEqual(expected.filter((e) => !seen.has(e)), [], 'limit ' + limit); }
  });
  await t.test('E05 deterministic repro (quiet database, one reader, page size 30): resuming at sequence 7 skips events 8 and 9 forever', { todo: 'BUG B15 (S1): pullProjectionChanges orders its final page by the TEXT alias profile_sequence ("10" < "2"), so once a profile stream passes sequence 9 a page can end past events 2..9 and the cursor skips them forever' }, async () => {
    const { encodeCursor } = requireApi('./src/shared_expenses/queries');
    const [a, b] = await users(2); const g = await group(a, [b]);
    for (let i = 0; i < 12; i++) { const p = proposal(g.ctx, g.members[a], [[g.members[a], 100 + i], [g.members[b], 100 + i]]); must(await proposeP(a, p)); must(await respondExpP(b, { contextId: g.ctx, expenseId: p.expenseId, revisionId: p.revisionId, decision: 'approve' })); }
    const wanted = (await q('SELECT ce.event_id,pe.sequence::int s FROM shared_expenses.profile_events pe JOIN shared_expenses.context_events ce ON ce.context_id=pe.context_id AND ce.sequence=pe.context_sequence WHERE pe.profile_id=$1 AND pe.sequence>=8', [b])).rows;
    assert.ok(wanted.length >= 16);
    // a client that acknowledged everything up to profile sequence 7 (a perfectly ordinary cursor)
    let cur = encodeCursor({ actorId: b, kind: 'projection_changes', contextId: null }, ['7', '99_granted:' + g.ctx]);
    const seen = new Set();
    for (let i = 0; i < 500; i++) { const pg = await feedPage(b, cur, 30); for (const r of pg.records) if (r.entity === 'activity') seen.add(r.id); cur = pg.nextCursor ?? cur; if (!pg.hasMore) break; }
    const lost = wanted.filter((w) => !seen.has(w.event_id)).map((w) => w.s);
    assert.deepEqual(lost, [], `profile sequences never delivered: ${lost}`);
  });

  // ================================================================== I. purge jobs
  await t.test('P01 lazy purge and hourly purge versus concurrent claim/approve/reveal', async () => {
    const [a] = await users(1); const g = await group(a); await q('INSERT INTO shared_expenses.phone_directory(profile_id,phone_hash) VALUES($1,$2)', [a, sha('owner-phone' + a)]);
    const reqs = await pendingRequests(a, g.ctx, 12);
    await q("UPDATE shared_expenses.invitations SET expires_at=clock_timestamp()-interval '1 minute' WHERE invitation_id=ANY($1::uuid[])", [reqs.slice(0, 6).map((r) => r.inv)]);
    const rs = await Promise.all([
      ...Array.from({ length: 4 }, () => call(a, 'list_join_requests()', [])), call(a, 'list_invitations(uuid,uuid)', [g.ctx, null]),
      ...reqs.slice(6).map((r) => call(a, 'reveal_claimant_phone(uuid)', [r.inv])),
      ...reqs.slice(6, 9).map((r) => respondInv(a, r.inv, true)), q('SELECT shared_expenses.purge_expired_claimant_phones() n'),
      ...Array.from({ length: 3 }, () => q('SELECT shared_expenses.purge_expired_claimant_phones() n')),
    ].map((p) => Promise.resolve(p).then((v) => (v && v.ok !== undefined ? v : { ok: true, v: v }), (e) => fail(e))));
    noInternal(rs.filter((r) => r.message));
    assert.equal(rs.filter((r) => !r.ok).length, 0, JSON.stringify(rs.filter((r) => !r.ok).map((r) => r.message)));
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1 AND claimant_phone_enc IS NOT NULL AND (state<>'awaiting_owner' OR expires_at<=clock_timestamp())", [g.ctx]), 0, 'no resolved/expired request keeps a ciphertext');
    assert.equal(await num("SELECT count(*) n FROM shared_expenses.invitations WHERE context_id=$1 AND state='awaiting_owner' AND expires_at>clock_timestamp() AND claimant_phone_enc IS NULL AND phone_share='shared'", [g.ctx]), 0, 'a live pending request never loses its number to the purge');
    assert.ok(await num("SELECT count(*) n FROM shared_expenses.phone_reveals WHERE owner_profile_id=$1 AND via='tap'", [a]) <= 5);
    await invariants('P01');
  });
  await t.test('P02 the decline route SQL is accepted by PostgreSQL', { todo: 'BUG B10: POST /shared-expenses/invitations/decline runs decline_invitation($1,$2,$4,$5) with five bound parameters; the unreferenced $3 makes PostgreSQL reject the statement (42P18), so declining an invitation always returns 500' }, async () => {
    // routes call: SELECT shared_expenses.decline_invitation($1::uuid,$2::text,$4::uuid,$5::text) with FIVE parameters ($3 unreferenced)
    const [c] = await users(1);
    let err = null;
    try { await pool.query('SELECT shared_expenses.decline_invitation($1::uuid,$2::text,$4::uuid,$5::text) AS result', [id(), sha('p'), '1234', id(), sha('h')]); } catch (e) { err = e; }
    t.diagnostic('decline route SQL with unreferenced $3: ' + (err ? `${err.code} ${err.message}` : 'accepted by the server'));
    if (err && err.code === '42P18') assert.fail('route SQL is rejected by PostgreSQL: ' + err.message);
    void c;
  });

  t.diagnostic(`client-visible retries: deadlocks=${stats.deadlocks} serialization=${stats.serialization}`);
});
