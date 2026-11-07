'use strict';
// Independent PostgreSQL sessions racing for the same member / friend name.
// Opt-in: PANDAPAY_SHARED_EXPENSES_NAMES_RACE_URL=postgres://.../shared_expenses_names_race_test on loopback.
// The database must be absent; the test creates and drops it. Never reads dotenv or DATABASE_URL.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createRequire } = require('node:module');
const { transactionalSql } = require('../scripts/product_migrate');
const requireApi = createRequire(path.resolve(__dirname, '../../api/package.json'));
const raw = process.env.PANDAPAY_SHARED_EXPENSES_NAMES_RACE_URL;
const DB = 'shared_expenses_names_race_test';
const OWNER = '90000000-0000-0000-0000-000000000001';
const id = () => crypto.randomUUID();
const H = (c) => c.repeat(64);

function target(value) {
  const url = new URL(value);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.pathname !== `/${DB}` || url.search || url.hash) throw new Error('loopback ' + DB + ' required');
  return url;
}

test('names race fixture refuses ambient targets', () => {
  assert.throws(() => target('postgres://localhost/pandapay'));
  assert.throws(() => target('postgres://remote/' + DB));
});

test('two sessions cannot both take one member name or one friend name', { skip: !raw && 'PANDAPAY_SHARED_EXPENSES_NAMES_RACE_URL not supplied', timeout: 120000 }, async (t) => {
  const { Client } = requireApi('pg');
  const url = target(raw), adminUrl = new URL(url);
  adminUrl.pathname = '/postgres';
  const marker = 'names-race-' + id();
  const admin = new Client({ connectionString: adminUrl.toString(), connectionTimeoutMillis: 5000, application_name: marker });
  await admin.connect();
  let owns = false;
  const sessions = new Set();
  t.after(async () => {
    for (const s of sessions) { await s.client.query('ROLLBACK').catch(() => {}); await s.client.end().catch(() => {}); }
    if (owns) await admin.query(`DROP DATABASE ${DB} WITH (FORCE)`).catch(() => {});
    await admin.end();
  });
  assert.equal((await admin.query('SELECT 1 FROM pg_database WHERE datname=$1', [DB])).rowCount, 0, 'refuse an existing database');
  await admin.query(`CREATE DATABASE ${DB}`);
  owns = true;
  const setup = new Client({ connectionString: url.toString(), connectionTimeoutMillis: 5000 });
  await setup.connect();
  try {
    await setup.query(`
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
    await setup.query('BEGIN');
    await setup.query(transactionalSql(fs.readFileSync(path.join(dir, '20261112210000_shared_expenses_foundation.sql'), 'utf8')));
    await setup.query('COMMIT');
    for (const f of fs.readdirSync(dir).filter((n) => n.includes('_shared_expense_') && n > '20261112210000').sort()) await setup.query(fs.readFileSync(path.join(dir, f), 'utf8'));
    await setup.query('GRANT USAGE ON SCHEMA public,pandapay TO app_user; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO app_user; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pandapay TO app_user');
    await setup.query("INSERT INTO public.profiles VALUES($1,'Race Owner')", [OWNER]);
    await setup.query('UPDATE shared_expenses.settings SET reads_enabled=true,proposals_enabled=true');
  } finally { await setup.end(); }

  async function begin() {
    const client = new Client({ connectionString: url.toString(), connectionTimeoutMillis: 5000, application_name: marker });
    client.on('error', () => {});
    await client.connect();
    const pid = (await client.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout='20000ms'; SET LOCAL lock_timeout='15000ms'; SET LOCAL ROLE app_user");
    await client.query("SELECT set_config('app.user_id',$1,true)", [OWNER]);
    const s = { client, pid };
    sessions.add(s);
    return s;
  }
  const fn = (s, sql, args) => s.client.query(sql, args).then((r) => r.rows[0].v);
  async function blocked(s) {
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      const st = await admin.query('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1 AND application_name=$2', [s.pid, marker]);
      if (st.rows[0]?.wait_event_type === 'Lock') return;
      await new Promise((r) => setTimeout(r, 20));
    }
    assert.fail('expected the second session to wait on a lock');
  }
  const finish = async (s) => { await s.client.query('COMMIT').catch(() => {}); await s.client.end().catch(() => {}); sessions.delete(s); };

  await t.test('same member name in one split: the second waits, then is refused', async () => {
    const ctx = id();
    const first = await begin();
    await fn(first, "SELECT shared_expenses.create_context($1,'group','Race',$2,$3) AS v", [ctx, id(), H('1')]);
    await first.client.query('COMMIT');
    await first.client.query('BEGIN');
    await first.client.query("SET LOCAL ROLE app_user");
    await first.client.query("SELECT set_config('app.user_id',$1,true)", [OWNER]);
    const second = await begin();
    const invite = (s, name) => fn(s, 'SELECT shared_expenses.invite_member($1::jsonb,$2::uuid,$3::text) AS v', [{ contextId: ctx, memberId: id(), displayName: name }, id(), H('2')]);
    await invite(first, 'Racer');
    const pending = invite(second, 'racer');
    pending.catch(() => {});
    await blocked(second);
    await first.client.query('COMMIT');
    await assert.rejects(pending, /member_name_taken/);
    await finish(first); await finish(second);
  });

  await t.test('same friend name in two direct splits of one creator: the second is refused', async () => {
    const first = await begin(), second = await begin();
    const create = (s, ctx) => fn(s, "SELECT shared_expenses.create_context($1,'direct','Zed',$2,$3) AS v", [ctx, id(), H('3')]);
    const c1 = id(), c2 = id();
    await create(first, c1);
    const pending = create(second, c2);
    pending.catch(() => {});
    await blocked(second);
    await first.client.query('COMMIT');
    const error = await pending.then(() => null, (e) => e);
    assert.equal(error?.message, 'friend_name_taken');
    assert.equal(error.detail, c1, 'points at the split that won');
    await finish(first); await finish(second);
  });
});
