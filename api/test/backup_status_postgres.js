'use strict';

// Explicit standalone fixture. Never reads DATABASE_URL/.env or connects to
// a hosted database. The caller must provision a fresh loopback-only database
// named backup_status_test in its own disposable PostgreSQL cluster.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const { READ_BACKUP_STATUS_SQL, READ_CONFLICTS_SQL } = require('../src/backup_status_routes');
const { PUBLISH_SQL } = require('../../db/scripts/publish_backup_status');

function fixtureConfig(raw) {
  if (!raw) throw new Error('BACKUP_STATUS_TEST_URL is required');
  let url;
  try { url = new URL(raw); } catch { throw new Error('Fixture URL is invalid'); }
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['127.0.0.1', 'localhost', '::1'].includes(host) || url.pathname !== '/backup_status_test' ||
      !['postgres:', 'postgresql:'].includes(url.protocol) || !url.username || !url.password || url.search || url.hash) {
    throw new Error('Fixture requires a loopback PostgreSQL URL for backup_status_test');
  }
  return { host, port: Number(url.port || 5432), user: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password), database: 'backup_status_test', ssl: false,
    max: 3, connectionTimeoutMillis: 3000, application_name: 'backup-status-disposable-test' };
}
const ident = value => `"${value.replaceAll('"', '""')}"`;
const rolePools = new Map();

async function asRole(_pool, role, profile, run) {
  const runtimePool = rolePools.get(role);
  if (!runtimePool) throw new Error('Fixture runtime login is missing');
  const client = await runtimePool.connect();
  try {
    await client.query('BEGIN');
    if (profile) await client.query("SELECT set_config('app.user_id',$1,true)", [profile]);
    const result = await run(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {}); throw error;
  } finally { client.release(); }
}

// Test setup only: age an attestation and inspect its bounded storage. The
// managed administrator is not the table owner and has no persistent owner
// membership after migration. Restore its own prior grant on transaction end.
async function asFixtureOwner(pool, run) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const name = (await client.query('SELECT current_user AS name')).rows[0].name;
    const previous = (await client.query(`SELECT inherit_option,set_option FROM pg_auth_members
      WHERE roleid='backup_status_owner'::regrole AND member=current_user::regrole AND grantor=current_user::regrole`)).rows[0];
    await client.query(`GRANT backup_status_owner TO ${ident(name)} WITH INHERIT FALSE GRANTED BY ${ident(name)}`);
    await client.query(`GRANT backup_status_owner TO ${ident(name)} WITH SET TRUE GRANTED BY ${ident(name)}`);
    await client.query('SET LOCAL ROLE backup_status_owner');
    const result = await run(client);
    await client.query("SELECT set_config('role',$1,true)",[name]);
    if (!previous) await client.query(`REVOKE backup_status_owner FROM ${ident(name)} GRANTED BY ${ident(name)}`);
    else {
      await client.query(`GRANT backup_status_owner TO ${ident(name)} WITH INHERIT ${previous.inherit_option} GRANTED BY ${ident(name)}`);
      await client.query(`GRANT backup_status_owner TO ${ident(name)} WITH SET ${previous.set_option} GRANTED BY ${ident(name)}`);
    }
    await client.query('COMMIT'); return result;
  } catch (error) { await client.query('ROLLBACK').catch(() => {}); throw error; }
  finally { client.release(); }
}

async function main() {
  const pool = new Pool(fixtureConfig(process.env.BACKUP_STATUS_TEST_URL));
  try {
    const server = (await pool.query('SELECT host(inet_server_addr()) AS address,current_database() AS database')).rows[0];
    const expectedBridge = process.env.BACKUP_STATUS_TEST_EXPECTED_SERVER_ADDRESS;
    if (expectedBridge && !require('node:net').isIP(expectedBridge)) throw new Error('Fixture server attestation is invalid');
    if (!['127.0.0.1', '::1', ...(expectedBridge ? [expectedBridge] : [])].includes(server.address) || server.database !== 'backup_status_test') {
      throw new Error('Fixture connection did not reach required loopback database');
    }
    const existing = await pool.query(`SELECT count(*)::int AS total FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','extensions')
        AND c.relkind IN ('r','p','v','m','S','f') AND c.relname NOT LIKE 'pg_%' AND c.relname<>'sql_features'`);
    if (existing.rows[0].total !== 0) throw new Error('Fixture refuses a non-empty database');

    const migrationDir = path.resolve(__dirname, '../../db/supabase/migrations');
    const base = ['extensions_and_enums','reference_data','card_catalogue','user_domain','sync','ingest',
      'crowdsource','admin_console','platform_ops','functions_and_views','rls_policies'];
    for (const [index, name] of base.entries()) await pool.query(fs.readFileSync(
      path.join(migrationDir, `${String(index + 1).padStart(4, '0')}_${name}.sql`), 'utf8'));
    const migration = fs.readFileSync(path.join(migrationDir, '20261023185353_verified_backup_status.sql'), 'utf8');
    await pool.query(migration);
    const suffix = `${process.pid}_${crypto.randomBytes(4).toString('hex')}`;
    const runtime = `backup_runtime_${suffix}`;
    const publisher = `backup_publisher_${suffix}`;
    const anonymous = `backup_anon_${suffix}`;
    for (const role of [runtime, publisher, anonymous]) {
      const password = crypto.randomBytes(24).toString('hex');
      await pool.query(`CREATE ROLE ${ident(role)} LOGIN PASSWORD '${password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`);
      const login = new Pool({ ...fixtureConfig(process.env.BACKUP_STATUS_TEST_URL), user: role, password, max: 2 });
      rolePools.set(role, login);
      const identity = (await login.query(`SELECT current_user,session_user,r.rolsuper,r.rolbypassrls
        FROM pg_roles r WHERE r.rolname=current_user`)).rows[0];
      assert.equal(identity.current_user,role); assert.equal(identity.session_user,role);
      assert.equal(identity.rolsuper,false); assert.equal(identity.rolbypassrls,false);
    }
    await pool.query(`GRANT USAGE ON SCHEMA public,pandapay TO ${ident(runtime)}`);
    await pool.query(`GRANT EXECUTE ON FUNCTION pandapay.uid() TO ${ident(runtime)}`);
    await pool.query(`GRANT backup_status_reader TO ${ident(runtime)}`);
    await pool.query(`GRANT SELECT ON public.sync_conflicts TO ${ident(runtime)}`);
    await pool.query(`GRANT backup_status_writer TO ${ident(publisher)}`);
    const a = crypto.randomUUID(), b = crypto.randomUUID();
    await pool.query('INSERT INTO profiles(id) VALUES ($1),($2)', [a,b]);
    // Historical rows can carry secrets and falsely green stub values; they
    // must never qualify as paired-v5 recovery evidence.
    const legacy = await pool.query(`INSERT INTO backup_runs(kind,status,location,error_text)
      VALUES ('logical','success','/private/secret-backup','secret-provider-token') RETURNING id`);
    await pool.query(`INSERT INTO restore_drills(backup_run_id,restored_ok,notes)
      VALUES ($1,true,'secret restore notes')`, [legacy.rows[0].id]);
    const read = (profile, requested = profile) => asRole(pool, runtime, profile,
      client => client.query(READ_BACKUP_STATUS_SQL, [requested]));
    const initial = (await read(a)).rows[0].status;
    assert.equal(initial.latestBackup, null);
    assert.equal(initial.latestRestoreDrill, null);
    assert.equal(initial.backupAvailability, 'unavailable');

    const denied = error => error.code === '42501';
    for (const sql of ['SELECT * FROM backup_status.attestations', 'SELECT * FROM backup_runs', 'SELECT * FROM restore_drills']) {
      await assert.rejects(asRole(pool, runtime, a, c => c.query(sql)), denied);
    }
    await assert.rejects(read(null, a), denied);
    await assert.rejects(read(a,b), denied);
    await assert.rejects(read(crypto.randomUUID()), denied);
    await assert.rejects(asRole(pool, anonymous, a, c => c.query(READ_BACKUP_STATUS_SQL, [a])), denied);
    await assert.rejects(asRole(pool, publisher, a, c => c.query(READ_BACKUP_STATUS_SQL, [a])), denied);
    await assert.rejects(asRole(pool, publisher, null, c => c.query('SELECT * FROM backup_status.attestations')), denied);
    await assert.rejects(asRole(pool, runtime, a, c => c.query('SET ROLE backup_status_owner')), denied);
    await assert.rejects(asRole(pool, publisher, null, c => c.query('SET ROLE backup_status_owner')), denied);

    const completed = new Date(Date.now() - 60 * 60000).toISOString();
    const verified = new Date(Date.now() - 30 * 60000).toISOString();
    const values = ['1'.repeat(32),'a'.repeat(64),completed,12345,'local',verified,'not_run','passed'];
    const publish = args => asRole(pool, publisher, null, c => c.query(PUBLISH_SQL, args));
    await assert.rejects(asRole(pool, runtime, a, c => c.query(PUBLISH_SQL, values)), denied);
    assert.equal((await publish(values)).rows[0].published, true);
    assert.equal((await publish(values)).rows[0].published, true, 'same-set replay remains idempotent');
    const current = (await read(a)).rows[0].status;
    assert.equal(current.backupAvailability, 'available');
    assert.equal(current.latestBackup.status, 'success');
    assert.equal(current.latestBackup.size_bytes, 12345);
    assert.equal(current.backupVerification.storage, 'local');
    assert.equal(current.backupVerification.applicationCheck, 'not_run');
    assert.equal(current.latestRestoreDrill.restored_ok, true);
    assert.deepEqual((await read(b)).rows[0].status, current, 'same sanitized ops status for each valid caller');
    assert.doesNotMatch(JSON.stringify(current), /secret|private|manifest|set_id|notes|error|location|row_count/);

    for (const [position, invalid] of [[0,'bad'],[1,'bad'],[2,null],[3,-1],[4,'object://secret'],
      [5,new Date(Date.now() + 6 * 60000).toISOString()],[6,'failed'],[7,'failed']]) {
      const args = [...values]; args[position] = invalid;
      await assert.rejects(publish(args), error => error.code === '22023');
    }
    const tampered = [...values]; tampered[1] = 'b'.repeat(64);
    await assert.rejects(publish(tampered), error => error.code === '22023');
    const old = [...values]; old[2] = new Date(Date.now() - 49 * 3600000).toISOString();
    await assert.rejects(publish(old), error => error.code === '22023');

    for (const profile of [a,b]) await pool.query(`INSERT INTO sync_conflicts
      (profile_id,entity,entity_id,field,local_value,server_value,chosen_value,strategy)
      VALUES ($1,'transactions',$2,'merchant_name',$3::jsonb,'"server"','"server"','last_write_wins')`,
    [profile,crypto.randomUUID(),JSON.stringify(profile === a ? 'caller-a' : 'caller-b')]);
    const ownConflicts = await asRole(pool, runtime, a, c => c.query(READ_CONFLICTS_SQL, [a]));
    assert.equal(ownConflicts.rows.length, 1);
    assert.equal(ownConflicts.rows[0].local_value, 'caller-a');
    const foreignConflicts = await asRole(pool, runtime, a, c => c.query(READ_CONFLICTS_SQL, [b]));
    assert.equal(foreignConflicts.rows.length, 0);

    // A hostile temporary relation cannot shadow the private table because
    // both definer functions qualify every relation and fix search_path.
    await asRole(pool, runtime, a, async c => {
      await c.query('CREATE TEMP TABLE attestations (secret text)');
      assert.equal((await c.query(READ_BACKUP_STATUS_SQL,[a])).rows[0].status.backupAvailability, 'available');
    });
    await asFixtureOwner(pool, c => c.query("UPDATE backup_status.attestations SET completed_at=now()-interval '49 hours',verified_at=now()-interval '48 hours'"));
    const stale = (await read(a)).rows[0].status;
    assert.equal(stale.backupAvailability, 'stale');
    assert.equal(stale.latestBackup.status, 'stale');

    // Retention is a count bound, without deleting or touching any backup
    // file or legacy operational row.
    for (let index = 0; index < 40; index += 1) {
      const args = [...values]; args[0] = (index + 10).toString(16).padStart(32,'0');
      await publish(args);
    }
    assert.equal((await asFixtureOwner(pool, c => c.query('SELECT count(*)::int AS n FROM backup_status.attestations'))).rows[0].n, 32);
    await pool.query(migration);
    assert.equal((await asFixtureOwner(pool, c => c.query('SELECT count(*)::int AS n FROM backup_status.attestations'))).rows[0].n, 32);
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM backup_runs')).rows[0].n, 1);
    const config = await pool.query(`SELECT p.prosecdef,p.proconfig,r.rolsuper,r.rolbypassrls FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_roles r ON r.oid=p.proowner WHERE n.nspname='backup_status'`);
    assert.equal(config.rows.length, 2);
    for (const row of config.rows) {
      assert.equal(row.prosecdef,true); assert.equal(row.rolsuper,false); assert.equal(row.rolbypassrls,false);
      assert.deepEqual(row.proconfig,['search_path=pg_catalog']);
    }
    console.log('PASS: backup status least-privilege roles, verified-only projection, caller RLS, stale/unavailable states, bounded replay and diagnostic redaction');
  } finally {
    for (const runtimePool of rolePools.values()) await runtimePool.end();
    await pool.end();
  }
}

main().catch(error => { console.error('Synthetic backup-status fixture failed', error.stack); process.exitCode = 1; });
