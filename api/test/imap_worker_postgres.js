'use strict';

// Fresh disposable local DB only. No app config/.env/production/provider URLs.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const { readImapWorkerBatch, deferImapWorkerBatch } = require('../src/imap_worker_capability');
const { sealPassword } = require('../src/imap_credentials');
const { POLL_ADVISORY_LOCK_KEY } = require('../src/imap_poller');
const { expectedServerAddress } = require('./partner_conversion_postgres');
const qIdent = value => `"${String(value).replaceAll('"', '""')}"`;

function fixtureConfig(raw) {
  if (!raw) throw new Error('IMAP_WORKER_TEST_URL is required');
  const url = new URL(raw);
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['127.0.0.1', 'localhost', '::1'].includes(host) || url.pathname !== '/imap_worker_test' ||
      !['postgres:', 'postgresql:'].includes(url.protocol) || !url.username || !url.password || url.search || url.hash) {
    throw new Error('Fixture requires loopback PostgreSQL URL for imap_worker_test');
  }
  return { host, port: Number(url.port || 5432), user: decodeURIComponent(url.username), password: decodeURIComponent(url.password),
    database: 'imap_worker_test', ssl: false, max: 5, connectionTimeoutMillis: 3000, application_name: 'imap-worker-disposable-test' };
}
async function transaction(pool, callback, role) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (role) await client.query(`SET LOCAL ROLE ${qIdent(role)}`);
    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (error) { await client.query('ROLLBACK'); throw error; }
  finally { client.release(); }
}

async function main() {
  const config = fixtureConfig(process.env.IMAP_WORKER_TEST_URL);
  const pool = new Pool(config);
  let workerPool;
  try {
    const server = (await pool.query('SELECT host(inet_server_addr()) AS address,current_database() AS database,current_user AS fixture_admin')).rows[0];
    if (!expectedServerAddress(server.address, process.env.IMAP_WORKER_TEST_SERVER_ADDRESS) || server.database !== 'imap_worker_test') throw new Error('Fixture server verification failed');
    const existing = await pool.query("SELECT count(*)::int AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','extensions') AND c.relkind IN ('r','p','v','m','S','f') AND c.relname NOT LIKE 'pg_%'");
    if (existing.rows[0].count !== 0) throw new Error('Fixture refuses a non-empty disposable database');
    await pool.query('CREATE SCHEMA IF NOT EXISTS extensions');
    // The first worker migration (replayed below) still requires pgcrypto to exist.
    await pool.query('CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions');
    await pool.query('CREATE EXTENSION IF NOT EXISTS citext');
    await pool.query('CREATE TABLE public.profiles(id uuid PRIMARY KEY)');
    await pool.query('CREATE SCHEMA pandapay');
    await pool.query("CREATE FUNCTION pandapay.uid() RETURNS uuid LANGUAGE sql STABLE SET search_path='' AS $$SELECT nullif(pg_catalog.current_setting('app.user_id',true),'')::uuid$$");
    const migrationDir = path.join(__dirname, '../../db/supabase/migrations');
    await pool.query(fs.readFileSync(path.join(migrationDir, '0018_imap_connections.sql'), 'utf8'));
    // Permit only this disposable migration owner to seed/inspect fixture
    // rows under FORCE RLS. Neither function owner nor worker/app roles are
    // members of this role; their real policies remain exercised below.
    await pool.query(`CREATE POLICY imap_fixture_migration_admin ON public.imap_connections FOR ALL TO ${qIdent(server.fixture_admin)} USING (true) WITH CHECK (true)`);
    const migration = fs.readFileSync(path.join(migrationDir, '20261023190128_imap_worker_capability.sql'), 'utf8');
    await transaction(pool, client => client.query(migration));
    await transaction(pool, client => client.query(migration));
    // Fresh start: mailbox passwords are sealed in the API; the worker only enumerates.
    const sealedMigration = fs.readFileSync(path.join(migrationDir, '20261115020000_imap_credentials_app_encryption.sql'), 'utf8');
    await transaction(pool, client => client.query(sealedMigration));

    const suffix = `${process.pid}_${crypto.randomBytes(4).toString('hex')}`;
    const runtime = `imap_runtime_${suffix}`;
    const appRole = `imap_app_${suffix}`;
    const outsider = `imap_outsider_${suffix}`;
    const password = crypto.randomBytes(32).toString('hex');
    for (const role of [runtime, appRole, outsider]) {
      await pool.query(`CREATE ROLE ${qIdent(role)} ${role === runtime ? `LOGIN PASSWORD '${password}'` : 'NOLOGIN'} NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS`);
      await pool.query(`GRANT ${qIdent(role)} TO ${qIdent(server.fixture_admin)} WITH SET TRUE GRANTED BY ${qIdent(server.fixture_admin)}`);
    }
    await pool.query(`GRANT pandapay_imap_worker TO ${qIdent(runtime)}`);
    await pool.query(`GRANT USAGE ON SCHEMA public,pandapay TO ${qIdent(appRole)}`);
    await pool.query(`GRANT SELECT,UPDATE ON public.imap_connections TO ${qIdent(appRole)}`);

    const firstUser = '00000000-0000-4000-8000-000000000001';
    const secondUser = '00000000-0000-4000-8000-000000000002';
    await pool.query('INSERT INTO public.profiles(id) VALUES ($1),($2)', [firstUser,secondUser]);
    const apiKey = { id: 'k1', bytes: crypto.randomBytes(32) };
    const keys = new Map([[apiKey.id, apiKey.bytes]]);
    const ids = [];
    for (let i = 1; i <= 105; i++) {
      const id = `00000000-0000-4000-8000-${String(i).padStart(12,'0')}`;
      ids.push(id);
      const owner = i % 2 ? firstUser : secondUser;
      const sealed = sealPassword(`synthetic-password-${i}`, { profileId: owner, connectionId: id }, apiKey);
      await pool.query(`INSERT INTO public.imap_connections(id,profile_id,email,app_password_ciphertext,app_password_key_id,imap_host,sender_filter)
        VALUES ($1,$2,$3,$4,$5,'imap.example.test','alerts@bank.example.test')`,
      [id, owner, `mailbox-${i}@example.test`, sealed.ciphertext, sealed.keyId]);
    }
    await pool.query('UPDATE public.imap_connections SET is_active=FALSE WHERE id=$1', [ids[104]]);
    await pool.query("UPDATE public.imap_connections SET app_password_ciphertext='\\x636f7272757074'::bytea WHERE id=$1", [ids[0]]);

    assert.equal((await transaction(pool, client => client.query('SELECT count(*)::int AS count FROM public.imap_connections'), appRole)).rows[0].count, 0);
    await transaction(pool, async client => {
      await client.query("SELECT set_config('app.user_id',$1,true)", [firstUser]);
      assert.equal((await client.query('SELECT count(*)::int AS count FROM public.imap_connections')).rows[0].count, 53);
      assert.equal((await client.query('UPDATE public.imap_connections SET last_poll_status=$1 WHERE profile_id=$2 RETURNING id', ['cannot-change-other-user',secondUser])).rowCount, 0);
    }, appRole);
    // A denied RPC aborts its transaction; test each denial in its own scope.
    for (const role of [appRole,outsider]) {
      await assert.rejects(transaction(pool, client => client.query('SELECT * FROM imap_worker.next_connections($1)', [100]), role), error => error.code === '42501');
      await assert.rejects(transaction(pool, client => client.query('SELECT imap_worker.defer_connections(NULL)', []), role), error => error.code === '42501');
    }
    assert.equal((await pool.query("SELECT has_function_privilege($1,'imap_worker.next_connections(integer)','EXECUTE') AS allowed", [outsider])).rows[0].allowed, false);
    assert.equal((await pool.query("SELECT has_table_privilege($1,'public.imap_connections','SELECT') AS read,has_table_privilege($1,'imap_worker.poll_state','SELECT') AS state", [runtime])).rows[0].read, false);
    assert.equal((await pool.query("SELECT has_table_privilege($1,'imap_worker.poll_state','SELECT') AS state", [runtime])).rows[0].state, false);
    const attributes = (await pool.query("SELECT rolcanlogin,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole FROM pg_roles WHERE rolname='imap_worker_owner'")).rows[0];
    assert.ok(Object.values(attributes).every(value => value === false));

    workerPool = new Pool({ ...config, user: runtime, password, max: 2 });
    const first = await readImapWorkerBatch(workerPool, keys);
    assert.equal(first.length, 100);
    assert.equal(first[0].credential_error, true);
    assert.equal(first[0].app_password, null);
    assert.equal(first[1].app_password, 'synthetic-password-2');
    const second = await readImapWorkerBatch(workerPool, keys);
    assert.equal(second.length, 4);
    assert.equal(new Set([...first,...second].map(row => row.id)).size, 104);
    assert.ok(![...first,...second].some(row => row.id === ids[104]));
    // Simulate a deadline after the first row of a short tail batch. The
    // next tick starts at deferred rows, not the earlier slow first mailbox.
    await deferImapWorkerBatch(workerPool,second[0].id);
    const deferred = await readImapWorkerBatch(workerPool,keys);
    assert.deepEqual(deferred.map(row => row.id),second.slice(1).map(row => row.id));
    const wrapped = await readImapWorkerBatch(workerPool, keys);
    assert.equal(wrapped[0].id, ids[0]);
    assert.equal((await pool.query('SELECT count(*)::int AS count FROM public.imap_connections WHERE last_poll_at IS NOT NULL')).rows[0].count, 0);

    for (const args of [[0],[101],[null]]) {
      await assert.rejects(workerPool.query('SELECT * FROM imap_worker.next_connections($1)',args), error => error.code === '22023');
    }
    const wrongKeyRows = await readImapWorkerBatch(workerPool, new Map([['k1', crypto.randomBytes(32)]]));
    assert.ok(wrongKeyRows.every(row => row.credential_error === true && row.app_password === null));
    const hold = await workerPool.connect();
    const other = await workerPool.connect();
    try {
      assert.equal((await hold.query('SELECT pg_try_advisory_lock($1) AS acquired',[POLL_ADVISORY_LOCK_KEY])).rows[0].acquired, true);
      assert.equal((await other.query('SELECT pg_try_advisory_lock($1) AS acquired',[POLL_ADVISORY_LOCK_KEY])).rows[0].acquired, false);
      assert.equal((await hold.query('SELECT pg_advisory_unlock($1) AS released',[POLL_ADVISORY_LOCK_KEY])).rows[0].released, true);
    } finally { hold.release(); other.release(); }
    await assert.rejects(workerPool.query('SELECT * FROM public.imap_connections'), error => error.code === '42501');
    await assert.rejects(workerPool.query('UPDATE public.imap_connections SET is_active=FALSE'), error => error.code === '42501');
    await assert.rejects(workerPool.query('UPDATE imap_worker.poll_state SET last_connection_id=NULL'), error => error.code === '42501');

    // Temp/search_path names cannot shadow fully qualified capability tables.
    await transaction(workerPool, async client => {
      await client.query('CREATE TEMP TABLE imap_connections(id uuid)');
      await client.query('CREATE TEMP TABLE poll_state(singleton boolean,last_connection_id uuid)');
      await client.query('SET LOCAL search_path=pg_temp,public');
      assert.ok((await readImapWorkerBatch(client,keys)).length > 0);
    });
    console.log(`PASS: IMAP worker additive migration/replay; non-owner active-row RLS; no app/PUBLIC/direct worker access; durable bounded100 cursor, rotation and deadline resume; corrupt/wrong-key isolation; SQL argument validation; per-user status boundary; session lock exclusion; search-path isolation; sealed credentials open only in the API`);
  } finally {
    if (workerPool) await workerPool.end();
    await pool.end();
  }
}

module.exports = { fixtureConfig };
if (require.main === module) main().catch(error => { console.error('Synthetic IMAP worker fixture failed',error.stack); process.exitCode=1; });
