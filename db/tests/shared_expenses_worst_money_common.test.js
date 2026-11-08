'use strict';
// Shared harness for the shared_expenses_worst_money_*.test.js suites.
// It is a *.test.js file only so the naming stays inside this suite; it has no
// tests of its own. Real PostgreSQL only: set PANDAPAY_WORST_MONEY_PG_URL to a
// loopback superuser URL (database "postgres"). Each suite creates and drops
// its own throwaway database. Never reads dotenv / DATABASE_URL.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createRequire } = require('node:module');
const { transactionalSql } = require('../scripts/product_migrate');
const requireApi = createRequire(path.resolve(__dirname, '../../api/package.json'));
const { Client } = requireApi('pg');

const RAW = process.env.PANDAPAY_WORST_MONEY_PG_URL;
const SKIP = !RAW && 'PANDAPAY_WORST_MONEY_PG_URL not supplied (loopback throwaway postgres required)';
const uuid = () => crypto.randomUUID();
const hex = () => crypto.randomBytes(32).toString('hex');
const MIG = f => fs.readFileSync(path.resolve(__dirname, '../supabase/migrations/' + f), 'utf8');
const MIGRATIONS = [
  '20261112213000_shared_expense_totals.sql', '20261112220000_shared_expense_bill_metadata.sql',
  '20261112230000_shared_expense_review_indexes.sql', '20261113000000_shared_expense_invitations.sql',
  '20261114000000_shared_expense_phone_directory.sql', '20261114010000_shared_expense_context_label.sql',
  '20261114020000_shared_expense_group_links.sql', '20261114030000_shared_expense_membership_exit.sql',
  '20261114040000_shared_expense_owner_and_former.sql', '20261116080000_shared_expense_invitation_audience.sql',
  '20261116090100_shared_expense_member_labels.sql', '20261116100100_shared_expense_join_identity.sql',
  '20261117010000_shared_expense_command_safety.sql', '20261117020000_shared_expense_privacy_safety.sql',
];

function loopbackUrl() {
  const url = new URL(RAW);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.pathname !== '/postgres' || url.search || url.hash)
    throw new Error('loopback postgres database "postgres" URL required');
  return url;
}

// mulberry32: deterministic seeded PRNG so a failing random run is replayable.
function rng(seed) {
  let a = seed >>> 0;
  const next = () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  next.int = (lo, hi) => lo + Math.floor(next() * (hi - lo + 1));
  next.pick = arr => arr[Math.floor(next() * arr.length)];
  return next;
}

async function createFixture(tag) {
  const url = loopbackUrl();
  const admin = new Client({ connectionString: url.toString(), connectionTimeoutMillis: 5000 });
  await admin.connect();
  const dbName = `wm_${tag}_${crypto.randomBytes(4).toString('hex')}`;
  await admin.query(`CREATE DATABASE ${dbName}`);
  const dbUrl = new URL(url); dbUrl.pathname = '/' + dbName;
  const db = new Client({ connectionString: dbUrl.toString(), connectionTimeoutMillis: 5000 });
  db.on('error', () => {});
  await db.connect();
  await db.query(`
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
    DO $$ DECLARE n text; BEGIN FOREACH n IN ARRAY ARRAY['transactions','sms_v2_events','sms_v2_instruments','sms_v2_ledger_entries','foreign_payments'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',n); EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY',n); EXECUTE format('CREATE POLICY owner_scope ON public.%I FOR ALL USING(profile_id=pandapay.uid()) WITH CHECK(profile_id=pandapay.uid())',n); END LOOP; END $$;
  `);
  await db.query('BEGIN');
  await db.query(transactionalSql(MIG('20261112210000_shared_expenses_foundation.sql')));
  await db.query('COMMIT');
  for (const f of MIGRATIONS) await db.query(MIG(f));
  await db.query('GRANT USAGE ON SCHEMA public,pandapay TO app_user; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO app_user; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pandapay TO app_user');
  await db.query('UPDATE shared_expenses.settings SET reads_enabled=true,proposals_enabled=true,accepted_writes_enabled=true,settlements_enabled=true');
  return new Fixture(admin, db, dbName, dbUrl);
}

class Fixture {
  constructor(admin, db, dbName, dbUrl) { this.admin = admin; this.db = db; this.dbName = dbName; this.dbUrl = dbUrl; this.names = new Map(); this.errors = new Map(); this.extra = []; }
  async close() {
    for (const c of this.extra) await c.end().catch(() => {});
    await this.db.end().catch(() => {});
    await this.admin.query(`DROP DATABASE IF EXISTS ${this.dbName} WITH (FORCE)`).catch(() => {});
    await this.admin.end().catch(() => {});
  }
  async profile(name) { const id = uuid(); await this.db.query('INSERT INTO public.profiles(id,display_name) VALUES($1,$2)', [id, name || null]); this.names.set(id, name); return id; }
  async profiles(n, prefix = 'p') { const out = []; for (let i = 0; i < n; i++) out.push(await this.profile(`${prefix}${i}`)); return out; }
  // Superuser read (bypasses RLS) for invariant checking.
  async q(sql, params) { return (await this.db.query(sql, params)).rows; }
  // One request as `profile`: own transaction, app_user role, RLS identity set.
  async asActor(profile, sql, params, client = this.db) {
    await client.query('BEGIN');
    try {
      await client.query('SET LOCAL ROLE app_user');
      await client.query("SELECT set_config('app.user_id',$1,true)", [profile]);
      const r = await client.query(sql, params);
      await client.query('COMMIT');
      return r;
    } catch (e) { await client.query('ROLLBACK').catch(() => {}); this.tally(e); throw e; }
  }
  // Run an arbitrary async function (e.g. an API query helper) as `profile`.
  async withActor(profile, fn, client = this.db) {
    await client.query('BEGIN');
    try {
      await client.query('SET LOCAL ROLE app_user');
      await client.query("SELECT set_config('app.user_id',$1,true)", [profile]);
      const r = await fn(client);
      await client.query('COMMIT');
      return r;
    } catch (e) { await client.query('ROLLBACK').catch(() => {}); this.tally(e); throw e; }
  }
  tally(e) { const k = (e.message || String(e)).split('\n')[0].slice(0, 90); this.errors.set(k, (this.errors.get(k) || 0) + 1); }
  async newClient() { const c = new Client({ connectionString: this.dbUrl.toString(), connectionTimeoutMillis: 5000 }); c.on('error', () => {}); await c.connect(); this.extra.push(c); return c; }
  async cmd(profile, fn, ...args) { // fn(args..., op, hash)
    const ph = args.map((_, i) => `$${i + 1}`).concat([`$${args.length + 1}`, `$${args.length + 2}`]).join(',');
    return (await this.asActor(profile, `SELECT shared_expenses.${fn}(${ph}) AS v`, [...args, uuid(), hex()])).rows[0].v;
  }
  async cmdOn(client, profile, fn, ...args) {
    const ph = args.map((_, i) => `$${i + 1}`).concat([`$${args.length + 1}`, `$${args.length + 2}`]).join(',');
    return (await this.asActor(profile, `SELECT shared_expenses.${fn}(${ph}) AS v`, [...args, uuid(), hex()], client)).rows[0].v;
  }
  async createContext(owner, kind, name) {
    const ctx = uuid();
    const v = await this.asActor(owner, 'SELECT shared_expenses.create_context($1,$2,$3,$4,$5) AS v', [ctx, kind, name, uuid(), hex()]);
    return { ctx, owner: v.rows[0].v.memberId };
  }
  // Add an already-registered friend and let them accept: returns memberId.
  async join(ownerProfile, ctx, profile, name) {
    const member = uuid();
    await this.cmd(ownerProfile, 'invite_member', { contextId: ctx, memberId: member, displayName: name || this.names.get(profile) || 'friend', profileId: profile });
    await this.asActor(profile, 'SELECT shared_expenses.respond_membership($1,$2,$3,$4,$5)', [ctx, member, true, uuid(), hex()]);
    return member;
  }
  async nameOnly(ownerProfile, ctx, name) {
    const member = uuid();
    await this.cmd(ownerProfile, 'invite_member', { contextId: ctx, memberId: member, displayName: name });
    return member;
  }
  // Late join of a name-only member through a phone-bound invitation.
  async bindLate(ownerProfile, ctx, member, joiner) {
    const phone = hex(), token = hex(), id = uuid();
    await this.asActor(ownerProfile, 'SELECT shared_expenses.create_invitation($1,$2)', [{ invitationId: id, contextId: ctx, memberId: member, targetPhoneHash: phone, tokenHash: token }, hex()]);
    const request = (await this.asActor(joiner, 'SELECT shared_expenses.claim_invitation($1,$2,$3,$4,$5) AS v', [token, phone, '3210', uuid(), hex()])).rows[0].v;
    if (request.status !== 'awaiting_owner') throw new Error('late bind must first request owner confirmation');
    return this.cmd(ownerProfile, 'respond_invitation', id, true);
  }
  // paid / shares: { memberId: minorString|number }
  snapshot(total, paid, shares, order) {
    const rows = o => Object.entries(o).map(([memberId, a]) => ({ memberId, amountMinor: String(a) }));
    const ids = order || [...new Set([...Object.keys(paid), ...Object.keys(shares)])];
    return { currency: 'INR', totalMinor: String(total), memberOrder: ids, contributions: rows(paid), shares: rows(shares) };
  }
  async propose(actor, ctx, o) {
    const expenseId = o.expenseId || uuid(), revisionId = o.revisionId || uuid();
    const payload = { contextId: ctx, expenseId, revisionId, expectedHeadRevisionId: o.head || null, title: o.title || 'dinner', occurredOn: o.date || '2026-11-05', sources: [], void: !!o.void,
      snapshot: o.void ? null : (o.snapshot || this.snapshot(o.total, o.paid, o.shares, o.order)) };
    const v = await this.cmd(actor, 'submit_proposal', payload);
    return { ...v, expenseId, revisionId };
  }
  respond(actor, ctx, expenseId, revisionId, decision = 'approve') { return this.cmd(actor, 'respond_expense', { contextId: ctx, expenseId, revisionId, decision }); }
  report(actor, ctx, payer, receiver, amount, o = {}) {
    const settlementId = o.settlementId || uuid();
    return this.cmd(actor, 'report_settlement', { contextId: ctx, settlementId, payerMemberId: payer, receiverMemberId: receiver, amountMinor: String(amount), currency: 'INR', method: o.method || 'upi', paidOn: o.paidOn || '2026-11-06' }).then(v => ({ ...v, settlementId }));
  }
  settle(actor, ctx, settlementId, decision = 'confirm') { return this.cmd(actor, 'respond_settlement', { contextId: ctx, settlementId, decision }); }
  leave(actor, ctx) { return this.cmd(actor, 'leave_context', ctx); }
  async balances(ctx) {
    const rows = await this.q('SELECT member_id,balance_minor::text b FROM shared_expenses.member_balances WHERE context_id=$1', [ctx]);
    return Object.fromEntries(rows.map(r => [r.member_id, BigInt(r.b)]));
  }
  async pairs(ctx) { return this.q('SELECT low_member_id l,high_member_id h,balance_minor::text b FROM shared_expenses.pair_balances WHERE context_id=$1 ORDER BY 1,2', [ctx]); }

  // Invariants derived independently of the journal code path. Returns a list
  // of violation strings (empty = all hold).
  async invariants(ctx) {
    const bad = [];
    const one = async (name, sql) => { const rows = await this.q(sql, [ctx]); if (rows.length) bad.push(`${name}: ${JSON.stringify(rows.slice(0, 3))}`); };
    await one('I1 member_balances sum != 0', 'SELECT sum(balance_minor)::text s FROM shared_expenses.member_balances WHERE context_id=$1 HAVING sum(balance_minor)<>0');
    await one('I2 member_balances != journal recomputation', `
      WITH j AS (SELECT member_id,sum(d) d FROM (SELECT low_member_id member_id,balance_minor d FROM shared_expenses.journal_entries WHERE context_id=$1 UNION ALL SELECT high_member_id,-balance_minor FROM shared_expenses.journal_entries WHERE context_id=$1) x GROUP BY 1),
      b AS (SELECT member_id,balance_minor d FROM shared_expenses.member_balances WHERE context_id=$1)
      SELECT coalesce(j.member_id,b.member_id) m,j.d::text j,b.d::text b FROM j FULL JOIN b USING(member_id) WHERE coalesce(j.d,0)<>coalesce(b.d,0)`);
    await one('I3 pair_balances != journal recomputation', `
      WITH j AS (SELECT low_member_id l,high_member_id h,sum(balance_minor) d FROM shared_expenses.journal_entries WHERE context_id=$1 GROUP BY 1,2 HAVING sum(balance_minor)<>0),
      p AS (SELECT low_member_id l,high_member_id h,balance_minor d FROM shared_expenses.pair_balances WHERE context_id=$1)
      SELECT coalesce(j.l,p.l) l,coalesce(j.h,p.h) h,j.d::text j,p.d::text p FROM j FULL JOIN p USING(l,h) WHERE j.d IS DISTINCT FROM p.d`);
    await one('I3b member_balances != sum(pair_balances)', `
      WITH p AS (SELECT member_id,sum(d) d FROM (SELECT low_member_id member_id,balance_minor d FROM shared_expenses.pair_balances WHERE context_id=$1 UNION ALL SELECT high_member_id,-balance_minor FROM shared_expenses.pair_balances WHERE context_id=$1) x GROUP BY 1),
      b AS (SELECT member_id,balance_minor d FROM shared_expenses.member_balances WHERE context_id=$1)
      SELECT coalesce(p.member_id,b.member_id) m,p.d::text p,b.d::text b FROM p FULL JOIN b USING(member_id) WHERE coalesce(p.d,0)<>coalesce(b.d,0)`);
    await one('I4 per-expense journal net != (paid-share) of accepted revision', `
      WITH jj AS (SELECT context_id,origin_id,low_member_id member_id,balance_minor d FROM shared_expenses.journal_entries WHERE context_id=$1 AND kind='revision'
                  UNION ALL SELECT context_id,origin_id,high_member_id,-balance_minor FROM shared_expenses.journal_entries WHERE context_id=$1 AND kind='revision'),
      j AS (SELECT r.expense_id,jj.member_id,sum(jj.d) d FROM jj JOIN shared_expenses.expense_revisions r ON r.context_id=jj.context_id AND r.revision_id=jj.origin_id GROUP BY 1,2),
      e AS (SELECT e.expense_id,rm.member_id,rm.paid_minor-rm.share_minor v FROM shared_expenses.expenses e JOIN shared_expenses.revision_members rm ON rm.context_id=e.context_id AND rm.revision_id=e.accepted_revision_id WHERE e.context_id=$1)
      SELECT coalesce(j.expense_id,e.expense_id) x,coalesce(j.member_id,e.member_id) m,j.d::text j,e.v::text e FROM j FULL JOIN e USING(expense_id,member_id) WHERE coalesce(j.d,0)<>coalesce(e.v,0)`);
    await one('I5 member_balances != accepted revisions + confirmed settlements', `
      WITH acc AS (SELECT rm.member_id,rm.paid_minor-rm.share_minor v FROM shared_expenses.expenses e JOIN shared_expenses.revision_members rm ON rm.context_id=e.context_id AND rm.revision_id=e.accepted_revision_id WHERE e.context_id=$1),
      st AS (SELECT r.payer_member_id member_id,r.amount_minor v FROM shared_expenses.settlement_reports r JOIN shared_expenses.settlement_events ev ON ev.context_id=r.context_id AND ev.settlement_id=r.settlement_id AND ev.kind='confirmed' WHERE r.context_id=$1
             UNION ALL SELECT r.receiver_member_id,-r.amount_minor FROM shared_expenses.settlement_reports r JOIN shared_expenses.settlement_events ev ON ev.context_id=r.context_id AND ev.settlement_id=r.settlement_id AND ev.kind='confirmed' WHERE r.context_id=$1),
      want AS (SELECT member_id,sum(v) v FROM (SELECT * FROM acc UNION ALL SELECT * FROM st) x GROUP BY 1),
      b AS (SELECT member_id,balance_minor v FROM shared_expenses.member_balances WHERE context_id=$1)
      SELECT coalesce(want.member_id,b.member_id) m,want.v::text want,b.v::text got FROM want FULL JOIN b USING(member_id) WHERE coalesce(want.v,0)<>coalesce(b.v,0)`);
    await one('I6 journal posted from a revision lacking an approve from every required reviewer (or with a reject)', `
      SELECT DISTINCT j.origin_id FROM shared_expenses.journal_entries j WHERE j.context_id=$1 AND j.kind='revision' AND (
        EXISTS(SELECT 1 FROM shared_expenses.revision_members m WHERE m.context_id=j.context_id AND m.revision_id=j.origin_id AND m.approval_required AND NOT EXISTS(SELECT 1 FROM shared_expenses.revision_approvals a WHERE a.context_id=m.context_id AND a.revision_id=m.revision_id AND a.member_id=m.member_id AND a.decision='approve'))
        OR EXISTS(SELECT 1 FROM shared_expenses.revision_approvals a WHERE a.context_id=j.context_id AND a.revision_id=j.origin_id AND a.decision='reject'))`);
    await one('I7 accepted head revision lacks full approvals', `
      SELECT e.expense_id FROM shared_expenses.expenses e WHERE e.context_id=$1 AND e.accepted_revision_id IS NOT NULL AND EXISTS(SELECT 1 FROM shared_expenses.revision_members m WHERE m.context_id=e.context_id AND m.revision_id=e.accepted_revision_id AND m.approval_required AND NOT EXISTS(SELECT 1 FROM shared_expenses.revision_approvals a WHERE a.context_id=m.context_id AND a.revision_id=m.revision_id AND a.member_id=m.member_id AND a.decision='approve'))`);
    await one('I8 non-INR / zero / out-of-range balances', `SELECT 1 FROM shared_expenses.pair_balances WHERE context_id=$1 AND (balance_minor=0 OR currency<>'INR') UNION ALL SELECT 1 FROM shared_expenses.member_balances WHERE context_id=$1 AND (abs(balance_minor)>9007199254740991 OR currency<>'INR')`);
    await one('I10 context_totals/member_totals drift from accepted heads', `
      WITH acc AS (SELECT e.expense_id,r.total_minor,r.is_void,e.accepted_revision_id rid FROM shared_expenses.expenses e JOIN shared_expenses.expense_revisions r ON r.context_id=e.context_id AND r.revision_id=e.accepted_revision_id WHERE e.context_id=$1),
      want AS (SELECT coalesce(sum(total_minor),0) t,count(*) FILTER(WHERE NOT is_void) c FROM acc),
      got AS (SELECT coalesce(total_minor,0) t,coalesce(expense_count,0) c FROM (SELECT 1) x LEFT JOIN shared_expenses.context_totals ON context_id=$1)
      SELECT want.t::text wt,got.t::text gt,want.c::text wc,got.c::text gc FROM want,got WHERE want.t<>got.t OR want.c<>got.c
      UNION ALL
      SELECT w.member_id::text,coalesce(g.paid_minor,0)::text,w.p::text,w.s::text FROM (SELECT rm.member_id,sum(rm.paid_minor) p,sum(rm.share_minor) s FROM shared_expenses.expenses e JOIN shared_expenses.revision_members rm ON rm.context_id=e.context_id AND rm.revision_id=e.accepted_revision_id WHERE e.context_id=$1 GROUP BY 1) w
        LEFT JOIN shared_expenses.member_totals g ON g.context_id=$1 AND g.member_id=w.member_id WHERE coalesce(g.paid_minor,0)<>w.p OR coalesce(g.share_minor,0)<>w.s`);
    return bad;
  }
  // Keep approving with every still-eligible reviewer until nothing is pending.
  async approveAll(ctx, r) {
    for (let guard = 0; guard < 80; guard++) {
      const rows = await this.q(`SELECT DISTINCT coalesce(rm.approver_profile_id,m.profile_id) p FROM shared_expenses.revision_members rm JOIN shared_expenses.members m ON m.context_id=rm.context_id AND m.member_id=rm.member_id
        WHERE rm.context_id=$1 AND rm.revision_id=$2 AND rm.approval_required AND coalesce(rm.approver_profile_id,m.profile_id) IS NOT NULL AND m.state='active'
        AND NOT EXISTS(SELECT 1 FROM shared_expenses.revision_approvals a WHERE a.context_id=rm.context_id AND a.revision_id=rm.revision_id AND a.member_id=rm.member_id)`, [ctx, r.revisionId]);
      if (!rows.length) break;
      for (const row of rows) await this.respond(row.p, ctx, r.expenseId, r.revisionId);
    }
    return (await this.q('SELECT accepted_revision_id=$3::uuid AS ok FROM shared_expenses.expenses WHERE context_id=$1 AND expense_id=$2', [ctx, r.expenseId, r.revisionId]))[0].ok;
  }
  // Group of n people: profiles[0] owns. Returns {ctx, p:[profile..], m:[member..]}.
  async group(n, name = 'grp') {
    const p = await this.profiles(n, 'u');
    const { ctx, owner } = await this.createContext(p[0], 'group', name + '-' + uuid().slice(0, 6));
    const m = [owner];
    for (let i = 1; i < n; i++) m.push(await this.join(p[0], ctx, p[i], 'u' + i + '-' + ctx.slice(0, 4)));
    return { ctx, p, m };
  }
  // Propose + fully approve. Returns {r, accepted}.
  async post(g, authorIdx, total, paid, shares, extra = {}) {
    const r = await this.propose(g.p[authorIdx], g.ctx, { total, paid, shares, ...extra });
    const accepted = r.status === 'accepted' ? true : await this.approveAll(g.ctx, r);
    return { r, accepted };
  }
}

// Largest-remainder splits via the real API domain code (equal/shares/percentage/exact).
const { allocateExpense } = requireApi('./src/shared_expenses/domain');
function split(mode, total, members, weights) {
  const participants = members.map((memberId, i) => mode === 'equal' ? { memberId } : mode === 'exact' ? { memberId, amountMinor: String(weights[i]) } : { memberId, weight: String(weights[i]) });
  const out = allocateExpense({ currency: 'INR', totalMinor: String(total), mode, participants, tieOrder: members });
  return Object.fromEntries(out.allocations.map(a => [a.memberId, BigInt(a.amountMinor)]));
}
module.exports = { SKIP, createFixture, rng, uuid, hex, split };
