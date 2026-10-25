'use strict';

// Disposable, loopback-only PostgreSQL integration fixture for the hosted auth
// runtime role grant. It refuses any database except a fresh
// auth_runtime_permissions_test database. It never falls back to DATABASE_URL.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const {
  configureAuthRuntimeRole,
  quotePgIdentifier,
} = require('../scripts/runtimePermissions');
const { createPostgresRateLimitStore } = require('../src/services/authAbuseStore');
const { createReadinessHandler } = require('../src/services/authReadiness');

function fixtureConfig(raw) {
  if (!raw) throw new Error('AUTH_RUNTIME_PERMISSION_TEST_URL is required');
  let url;
  try { url = new URL(raw); } catch { throw new Error('Fixture URL is invalid'); }
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['127.0.0.1', 'localhost', '::1'].includes(host) ||
      url.pathname !== '/auth_runtime_permissions_test' ||
      !['postgres:', 'postgresql:'].includes(url.protocol) ||
      !url.username || !url.password || url.search || url.hash) {
    throw new Error('Fixture requires a loopback PostgreSQL URL for auth_runtime_permissions_test');
  }
  const port = url.port ? Number(url.port) : 5432;
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Fixture port is invalid');
  return {
    host,
    port,
    user: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password),
    database: 'auth_runtime_permissions_test',
    ssl: false,
    max: 1,
    connectionTimeoutMillis: 3000,
    application_name: 'auth-runtime-permissions-disposable-test',
  };
}

const config = fixtureConfig(process.env.AUTH_RUNTIME_PERMISSION_TEST_URL);
const ownTables = ['db_access_log', 'auth_abuse_buckets', 'users', 'contact_resolution_history', 'auth_schema_migrations'];
const migration = fs.readFileSync(path.join(__dirname, '../db/migrations/0004_auth_abuse_buckets.sql'), 'utf8');
const migrationFile = { file: '0004_auth_abuse_buckets.sql', version: '0004_auth_abuse_buckets' };
const logMigration = fs.readFileSync(path.join(__dirname, '../db/migrations/0005_db_access_log.sql'), 'utf8');
const logMigrationFile = { file: '0005_db_access_log.sql', version: '0005_db_access_log' };

async function assertNoRoleDml(client, role, table) {
  const result = await client.query(
    `SELECT has_table_privilege($1, $2, 'SELECT') AS can_select,
            has_table_privilege($1, $2, 'INSERT') AS can_insert,
            has_table_privilege($1, $2, 'UPDATE') AS can_update,
            has_table_privilege($1, $2, 'DELETE') AS can_delete`,
    [role, `public.${table}`],
  );
  assert.deepEqual(Object.values(result.rows[0]), [false, false, false, false]);
}

async function readinessResult(query, extraEnv = {}) {
  let statusCode = 200;
  let body;
  const response = {
    json(value) { body = value; return this; },
    status(value) { statusCode = value; return this; },
  };
  await createReadinessHandler({ query, env: { NODE_ENV: 'production', ...extraEnv }, logger: { error() {} } })(null, response);
  return { statusCode, body };
}

async function main() {
  const adminPool = new Pool(config);
  let role;
  let roleCreated = false;
  let fixtureStarted = false;
  let runtimePool;
  let runtimeClient;
  try {
    const server = await adminPool.query('SELECT host(inet_server_addr()) AS address, current_database() AS database');
    const address = String(server.rows[0]?.address || '').replace(/^\[|\]$/g, '').toLowerCase();
    if (!['127.0.0.1', '::1'].includes(address) || server.rows[0]?.database !== 'auth_runtime_permissions_test') {
      throw new Error('Fixture connection did not reach the required loopback test database');
    }
    const existing = await adminPool.query(
      `SELECT count(*)::bigint AS relations FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','S','f')
         AND c.relname NOT LIKE 'pg_%' AND c.relname <> 'sql_features'`,
    );
    if (Number(existing.rows[0].relations) !== 0) {
      throw new Error('Fixture refuses a non-empty disposable database');
    }
    fixtureStarted = true;

    role = `auth_rt_test_${process.pid}_${require('node:crypto').randomBytes(4).toString('hex')}`;
    const quotedRole = quotePgIdentifier(role);
    await adminPool.query(`CREATE ROLE ${quotedRole} NOLOGIN`);
    roleCreated = true;
    await adminPool.query(`GRANT USAGE ON SCHEMA public TO ${quotedRole}`);

    await adminPool.query('CREATE TABLE public.users (id integer PRIMARY KEY)');
    await adminPool.query('CREATE TABLE public.contact_resolution_history (id integer PRIMARY KEY)');
    await adminPool.query('CREATE TABLE public.auth_schema_migrations (version text PRIMARY KEY)');
    await adminPool.query('REVOKE ALL ON TABLE public.users, public.contact_resolution_history, public.auth_schema_migrations FROM PUBLIC');
    await adminPool.query(migration);
    await adminPool.query(logMigration);
    await adminPool.query("INSERT INTO public.db_access_log(query_type,query_text) VALUES ('SELECT','synthetic legacy audit')");
    // The optional runtime logger used to create this table. Reapplying its
    // additive adoption migration must preserve compatible existing rows.
    await adminPool.query(logMigration);
    assert.equal((await adminPool.query('SELECT count(*)::int AS count FROM public.db_access_log')).rows[0].count, 1);

    await assertNoRoleDml(adminPool, role, 'auth_abuse_buckets');
    for (const table of ['users', 'contact_resolution_history', 'auth_schema_migrations']) {
      await assertNoRoleDml(adminPool, role, table);
    }

    await configureAuthRuntimeRole(adminPool, { files: [migrationFile, logMigrationFile], runtimeRole: role, dbAccessLoggingEnabled: true });
    await assertNoRoleDml(adminPool, role, 'users');
    await assertNoRoleDml(adminPool, role, 'contact_resolution_history');
    await assertNoRoleDml(adminPool, role, 'auth_schema_migrations');

    runtimePool = new Pool(config);
    runtimeClient = await runtimePool.connect();
    await runtimeClient.query(`SET ROLE ${quotedRole}`);
    await runtimeClient.query("INSERT INTO public.db_access_log(query_type,query_text,params_sanitized) VALUES ('SELECT','[query omitted]','{\"count\":1}'::jsonb)");
    for (const sql of ['SELECT * FROM public.db_access_log', 'DELETE FROM public.db_access_log', "UPDATE public.db_access_log SET query_text='changed'", 'ALTER TABLE public.db_access_log ADD COLUMN bad text']) {
      await assert.rejects(runtimeClient.query(sql), error => error.code === '42501');
    }
    const runtimePoolProvider = async () => ({
      connect: async () => ({
        query: (...args) => runtimeClient.query(...args),
        release() {},
      }),
    });
    const store = createPostgresRateLimitStore({
      poolProvider: runtimePoolProvider,
      hmacKey: Buffer.alloc(32, 23),
      capacity: 32,
      cleanupBatch: 8,
    });
    assert.equal(await store.increment('synthetic:auth-runtime-role', 30), 1);
    assert.equal(await store.get('synthetic:auth-runtime-role'), 1);
    await store.setWithTTL('synthetic:auth-runtime-marker', 'fixture-marker', 30);
    assert.equal(await store.exists('synthetic:auth-runtime-marker'), true);
    assert.equal(await store.compareDelete('synthetic:auth-runtime-marker', 'fixture-marker'), true);

    const ready = await readinessResult(runtimeClient.query.bind(runtimeClient));
    assert.deepEqual(ready, { statusCode: 200, body: { ok: true, database: 'ready' } });
    const logReady = await readinessResult(runtimeClient.query.bind(runtimeClient), { DB_ACCESS_LOGGING_ENABLED: 'true' });
    assert.equal(logReady.statusCode, 200);
    await adminPool.query(`REVOKE INSERT ON TABLE public.db_access_log FROM ${quotedRole}`);
    assert.equal((await readinessResult(runtimeClient.query.bind(runtimeClient), { DB_ACCESS_LOGGING_ENABLED: 'true' })).statusCode, 503);
    assert.equal((await readinessResult(runtimeClient.query.bind(runtimeClient))).statusCode, 200);

    await adminPool.query(`REVOKE DELETE ON TABLE public.auth_abuse_buckets FROM ${quotedRole}`);
    const denied = await readinessResult(runtimeClient.query.bind(runtimeClient));
    assert.equal(denied.statusCode, 503);
    assert.deepEqual(denied.body, { ok: false, database: 'unavailable' });
    console.log('PASS: runtime role has scoped abuse DML and optional INSERT-only audit access; migration replay preserves audit history; readiness detects privilege loss');
  } finally {
    if (runtimeClient) {
      await runtimeClient.query('RESET ROLE').catch(() => {});
      runtimeClient.release();
    }
    if (runtimePool) await runtimePool.end().catch(() => {});
    if (fixtureStarted) {
      for (const table of ownTables) {
        await adminPool.query(`DROP TABLE IF EXISTS public.${table} CASCADE`).catch(() => {});
      }
    }
    if (roleCreated) await adminPool.query(`DROP ROLE IF EXISTS ${quotePgIdentifier(role)}`).catch(() => {});
    await adminPool.end();
  }
}

main().catch(error => {
  // This guarded fixture contains only synthetic identities and objects.
  console.error('Synthetic auth runtime permission PostgreSQL fixture failed', error.stack);
  process.exitCode = 1;
});
