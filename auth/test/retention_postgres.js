'use strict';

// Independent fresh loopback fixture. Never reads DATABASE_URL or .env and
// refuses an existing database. Every account/contact used here is synthetic.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const { Client } = require('pg');
const { readRetentionPolicy } = require('../src/services/retentionPolicy');
const { runRetention, RETENTION_LOCK } = require('../src/services/retentionRunner');

function loadAuditLogger(query) {
  const filename = path.resolve(__dirname, '../src/services/auditLogger.js');
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = name => name === '../db' ? { query } : Module.prototype.require.call(loaded, name);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

async function main() {
  const raw = process.env.AUTH_RETENTION_TEST_URL;
  if (!raw) throw new Error('AUTH_RETENTION_TEST_URL is required');
  const url = new URL(raw);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.pathname !== '/auth_retention_test' || !url.username || !url.password || url.search || url.hash) throw new Error('A fresh loopback auth_retention_test database is required');
  const admin = new Client({ connectionString: raw, ssl: false, connectionTimeoutMillis: 3000 });
  const clients = [];
  const suffix = crypto.randomBytes(5).toString('hex');
  const roles = [`auth_retention_rt_${suffix}`, `auth_retention_ops_${suffix}`];
  let operatorName;
  await admin.connect();
  try {
    const reached = await admin.query('SELECT current_database() AS database, host(inet_server_addr()) AS address,current_user AS operator');
    operatorName=reached.rows[0].operator;
    assert.equal(reached.rows[0].database, 'auth_retention_test');
    assert.ok(['127.0.0.1', '::1'].includes(reached.rows[0].address));
    const existing = await admin.query("SELECT count(*)::integer AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast') AND c.relkind IN ('r','p','v','m','S','f') AND c.relname NOT LIKE 'pg_%'");
    assert.equal(existing.rows[0].count, 0, 'fixture refuses a nonempty DB');
    await admin.query(fs.readFileSync(path.join(__dirname, '../db/pandapay-auth/init.sql'), 'utf8'));
    for (const file of ['0004_auth_abuse_buckets.sql', '0005_db_access_log.sql']) await admin.query(fs.readFileSync(path.join(__dirname, '../db/migrations', file), 'utf8'));
    const auditId = crypto.randomUUID();
    await admin.query("INSERT INTO public.auth_audit(id,action,status,meta,created_at) VALUES ($1,'login','success','{\"history\":\"preserved\"}',now()-interval '5000 days')", [auditId]);
    const migration = fs.readFileSync(path.join(__dirname, '../db/migrations/0008_auth_audit_risk_level.sql'), 'utf8');
    await admin.query(migration);
    let adopted = (await admin.query('SELECT id,meta,risk_level FROM public.auth_audit WHERE id=$1', [auditId])).rows[0];
    assert.equal(adopted.risk_level, 'INFO');
    assert.deepEqual(adopted.meta, { history: 'preserved' });
    await admin.query("UPDATE public.auth_audit SET risk_level='HIGH_RISK' WHERE id=$1", [auditId]);
    await admin.query(migration);
    adopted = (await admin.query('SELECT id,meta,risk_level FROM public.auth_audit WHERE id=$1', [auditId])).rows[0];
    assert.equal(adopted.risk_level, 'HIGH_RISK', 'adoption must preserve pre-existing logger values');
    assert.deepEqual(adopted.meta, { history: 'preserved' });
    for (const role of roles) {
      const password = crypto.randomBytes(32).toString('hex');
      await admin.query(`CREATE ROLE "${role}" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '${password}'`);
      await admin.query(`GRANT USAGE ON SCHEMA public TO "${role}"`);
      const connection = new URL(raw);
      connection.username = role;
      connection.password = password;
      const client = new Client({ connectionString: connection.toString(), ssl: false, connectionTimeoutMillis: 3000 });
      await client.connect();
      clients.push(client);
    }
    const [runtime, maintenance] = clients;
    await admin.query(`GRANT INSERT ON public.auth_audit TO "${roles[0]}"`);
    await admin.query(`GRANT SELECT(id,created_at) ON public.auth_audit TO "${roles[0]}"`);
    // Row locking requires UPDATE on at least one column. These fixture-only
    // grants do not alter the application's existing runtime permissions.
    await admin.query(`GRANT SELECT,DELETE ON public.db_access_log,public.auth_abuse_buckets TO "${roles[1]}"`);
    await admin.query(`GRANT UPDATE(id) ON public.db_access_log TO "${roles[1]}"`);
    await admin.query(`GRANT UPDATE(bucket_key) ON public.auth_abuse_buckets TO "${roles[1]}"`);
    const queryCalls = [];
    const logger = loadAuditLogger(async (sql, values) => { queryCalls.push(sql); return runtime.query(sql, values); });
    await logger.logAuthEvent({ action: 'login', status: 'success' });
    assert.equal(queryCalls.length, 1);
    assert.match(queryCalls[0], /INSERT INTO auth_audit/);
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM public.auth_audit')).rows[0].count, 2);
    await assert.rejects(runtime.query('ALTER TABLE public.auth_audit ADD COLUMN forbidden text'), error => error.code === '42501');
    await assert.rejects(runtime.query('DELETE FROM public.db_access_log'), error => error.code === '42501');
    await assert.rejects(maintenance.query('DELETE FROM public.auth_audit'), error => error.code === '42501');
    await assert.rejects(maintenance.query('SELECT * FROM public.users'), error => error.code === '42501');

    await admin.query("INSERT INTO public.db_access_log(query_type,query_text,created_at) SELECT 'SELECT','[query omitted]',now()-interval '90 days' FROM generate_series(1,7)");
    await admin.query("INSERT INTO public.db_access_log(query_type,query_text,created_at) VALUES ('SELECT','[query omitted]',now()-interval '1 day'),('SELECT','[query omitted]',now()-interval '29 days')");
    const expired = crypto.randomBytes(32), recent = crypto.randomBytes(32), live = crypto.randomBytes(32);
    for (const [key, interval] of [[expired, '-3 days'], [recent, '-1 hour'], [live, '1 hour']]) {
      await admin.query("INSERT INTO public.auth_abuse_buckets(bucket_key,bucket_kind,counter_value,expires_at) VALUES ($1,'counter',1,now()+$2::interval)", [key, interval]);
    }
    const policy = readRetentionPolicy({ AUTH_DB_ACCESS_LOG_RETENTION_DAYS: '30', AUTH_ABUSE_STATE_RETENTION_DAYS: '1', AUTH_RETENTION_BATCH_SIZE: '2' });
    const before = await runRetention(maintenance, policy);
    assert.deepEqual(before.scopes.map(row => row.candidates), [2, 1]);
    assert.deepEqual(before.scopes.map(row => row.deleted), [0, 0]);
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM public.db_access_log')).rows[0].count, 9);

    await admin.query('SELECT pg_advisory_lock($1,$2)', RETENTION_LOCK);
    const busy = await runRetention(maintenance, policy, { apply: true });
    assert.equal(busy.status, 'busy');
    await admin.query('SELECT pg_advisory_unlock($1,$2)', RETENTION_LOCK);
    const bounded = await runRetention(maintenance, { ...policy, maxBatches: 1 }, { apply: true });
    assert.equal(bounded.status, 'budget_exhausted');
    assert.equal(bounded.scopes[0].deleted, 2);
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM public.db_access_log')).rows[0].count, 7);

    await admin.query('BEGIN');
    const held = (await admin.query("SELECT id FROM public.db_access_log WHERE created_at < now()-interval '30 days' ORDER BY id LIMIT 1 FOR UPDATE")).rows[0].id;
    const during = await runRetention(maintenance, policy, { apply: true });
    assert.equal(during.scopes[0].deleted, 4, 'other sessions locked row must be skipped');
    assert.equal(during.scopes[1].deleted, 1);
    await admin.query('COMMIT');
    const retry = await runRetention(maintenance, policy, { apply: true });
    assert.equal(retry.scopes[0].deleted, 1);
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM public.db_access_log')).rows[0].count, 2);
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM public.auth_abuse_buckets')).rows[0].count, 2);
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM public.auth_audit')).rows[0].count, 2);
    assert.equal((await admin.query('SELECT risk_level FROM public.auth_audit WHERE id=$1', [auditId])).rows[0].risk_level, 'HIGH_RISK');
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM public.db_access_log WHERE id=$1', [held])).rows[0].count, 0);
    console.log('PASS: explicit bounded auth retention, dry-run preservation, job/session/row locking, active/grace state protection, repeat continuation; fresh/legacy audit migration and INSERT-only runtime logger with all security history retained');
  } finally {
    await admin.query('ROLLBACK').catch(() => {});
    for (const client of clients) await client.end();
    // Role names are invocation-owned. Do not remove any existing objects.
    try {
      for (const role of roles) {
        const exists = await admin.query('SELECT 1 FROM pg_roles WHERE rolname=$1', [role]);
        if (exists.rows.length) {
          // PG16+ CREATEROLE grants ADMIN without SET. Only the two roles
          // created by this invocation need temporary SET for cleanup.
          const operator='"'+operatorName.replaceAll('"','""')+'"';
          await admin.query(`GRANT "${role}" TO ${operator} WITH SET TRUE GRANTED BY ${operator}`);
          await admin.query(`DROP OWNED BY "${role}"`);
          await admin.query(`DROP ROLE "${role}"`);
        }
      }
    } finally {await admin.end();}
  }
}

main().catch(error => { console.error('Synthetic auth retention fixture failed', error.stack); process.exitCode = 1; });
