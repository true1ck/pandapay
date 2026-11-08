'use strict';
// The local rollback helper for the join-identity migration restores exactly the previous schema,
// and the migration can then be applied again. Opt-in:
// PANDAPAY_SHARED_EXPENSES_ROLLBACK_URL=postgres://.../shared_expenses_rollback_test (loopback, database must be absent).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createRequire } = require('node:module');
const { transactionalSql } = require('../scripts/product_migrate');
const requireApi = createRequire(path.resolve(__dirname, '../../api/package.json'));
const raw = process.env.PANDAPAY_SHARED_EXPENSES_ROLLBACK_URL;
const DB = 'shared_expenses_rollback_test';
const MIGRATION = '20261116100100_shared_expense_join_identity.sql';

function target(value) {
  const url = new URL(value);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.pathname !== `/${DB}` || url.search || url.hash) throw new Error('loopback ' + DB + ' required');
  return url;
}

test('rollback fixture refuses ambient targets', () => {
  assert.throws(() => target('postgres://localhost/pandapay'));
});

test('rollback restores the previous schema exactly, and the migration applies again', { skip: !raw && 'PANDAPAY_SHARED_EXPENSES_ROLLBACK_URL not supplied', timeout: 120000 }, async (t) => {
  const { Client } = requireApi('pg');
  const url = target(raw), adminUrl = new URL(url);
  adminUrl.pathname = '/postgres';
  const admin = new Client({ connectionString: adminUrl.toString(), connectionTimeoutMillis: 5000 });
  await admin.connect();
  let owns = false;
  let db;
  t.after(async () => { await db?.end().catch(() => {}); if (owns) await admin.query(`DROP DATABASE ${DB} WITH (FORCE)`).catch(() => {}); await admin.end(); });
  assert.equal((await admin.query('SELECT 1 FROM pg_database WHERE datname=$1', [DB])).rowCount, 0, 'refuse an existing database');
  await admin.query(`CREATE DATABASE ${DB}`);
  owns = true;
  db = new Client({ connectionString: url.toString(), connectionTimeoutMillis: 5000 });
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
  `);
  const dir = path.resolve(__dirname, '../supabase/migrations');
  await db.query('BEGIN');
  await db.query(transactionalSql(fs.readFileSync(path.join(dir, '20261112210000_shared_expenses_foundation.sql'), 'utf8')));
  await db.query('COMMIT');
  const earlier = fs.readdirSync(dir).filter((n) => n.includes('_shared_expense_') && n > '20261112210000' && n < MIGRATION).sort();
  for (const f of earlier) await db.query(fs.readFileSync(path.join(dir, f), 'utf8'));

  const snapshot = async () => ({
    functions: (await db.query(`SELECT p.oid::regprocedure::text AS sig, replace(pg_get_functiondef(p.oid),chr(13),'') AS def, pg_get_userbyid(p.proowner) AS owner, p.proacl::text AS acl
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='shared_expenses' ORDER BY 1`)).rows,
    columns: (await db.query(`SELECT table_name,column_name,data_type,is_nullable FROM information_schema.columns WHERE table_schema='shared_expenses' ORDER BY 1,2`)).rows,
    indexes: (await db.query(`SELECT indexname FROM pg_indexes WHERE schemaname='shared_expenses' ORDER BY 1`)).rows,
    triggers: (await db.query(`SELECT tgrelid::regclass::text AS tbl,tgname FROM pg_trigger WHERE NOT tgisinternal AND (tgrelid::regclass::text LIKE 'shared_expenses.%' OR tgrelid::regclass::text='profiles') ORDER BY 1,2`)).rows,
    constraints: (await db.query(`SELECT conrelid::regclass::text AS tbl,conname FROM pg_constraint WHERE connamespace='shared_expenses'::regnamespace ORDER BY 1,2`)).rows,
  });
  const before = await snapshot();
  const apply = () => db.query(fs.readFileSync(path.join(dir, MIGRATION), 'utf8'));
  await apply();
  const applied = await snapshot();
  assert.ok(applied.functions.length > before.functions.length && applied.columns.length > before.columns.length);
  const rollback = fs.readFileSync(path.resolve(__dirname, '../../docs/implementation/shared-expenses/rollback_join_identity_local.sql'), 'utf8');
  await db.query(rollback);
  const after = await snapshot();
  assert.deepEqual(after.columns, before.columns, 'columns and the audit table are gone');
  assert.deepEqual(after.indexes, before.indexes);
  assert.deepEqual(after.triggers, before.triggers, 'including the trigger on profiles');
  assert.deepEqual(after.constraints, before.constraints);
  assert.deepEqual(after.functions.map((f) => f.sig), before.functions.map((f) => f.sig), 'no new function is left behind and none is missing');
  for (const [i, f] of before.functions.entries()) {
    assert.equal(after.functions[i].def, f.def, 'definition restored: ' + f.sig);
    assert.equal(after.functions[i].owner, f.owner, 'owner restored: ' + f.sig);
    assert.equal(after.functions[i].acl, f.acl, 'grants restored: ' + f.sig);
  }
  await apply();
  assert.deepEqual(await snapshot(), applied, 'a second application gives the same schema as the first');
  await db.query(rollback);
  assert.deepEqual((await snapshot()).functions, after.functions, 'and it rolls back again');
  assert.equal(crypto.randomUUID().length, 36);
});
