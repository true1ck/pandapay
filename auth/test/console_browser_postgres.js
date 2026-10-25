'use strict';
// Fresh loopback-only database and independent synthetic LOGINs. No live URLs,
// .env, providers, customer rows or operator keys are read by this fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { isIP } = require('node:net');
const { Client, Pool } = require('pg');
const { createConsoleSessionStore, digest } = require('../src/services/consoleSessionStore');
const { configureConsoleSessionLogin } = require('../scripts/consoleSessionPermissions');
const { createConsoleBrowserRuntime } = require('../src/services/consoleBrowserRuntime');

async function main() {
  const raw = process.env.CONSOLE_BROWSER_TEST_URL;
  if (!raw) throw new Error('CONSOLE_BROWSER_TEST_URL is required');
  const url = new URL(raw);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.pathname !== '/console_browser_test' || !url.username || !url.password || url.search || url.hash) throw new Error('A fresh loopback console_browser_test is required');
  const admin = new Client({ connectionString: raw, ssl: false, connectionTimeoutMillis: 3000 });
  // Docker publishes a loopback port while PostgreSQL sees its private
  // container address. Require an explicit IP attestation for this one owned
  // disposable server; this never permits a non-loopback connection URL.
  const attestedAddress = process.env.CONSOLE_BROWSER_TEST_SERVER_ADDRESS;
  if (attestedAddress && !isIP(attestedAddress)) throw new Error('Fixture server attestation must be a literal IP');
  const ordinaryName = 'console_ordinary_'+crypto.randomBytes(5).toString('hex');
  const createdRoles = [], clients = [];
  let pool, runtime, operatorName;
  await admin.connect();
  try {
    const server = (await admin.query("SELECT current_database() AS database,host(inet_server_addr()) AS address,current_user AS owner,current_setting('is_superuser')='on' AS superuser")).rows[0];
    operatorName = server.owner;
    assert.equal(server.database, 'console_browser_test');
    assert.ok(['127.0.0.1', '::1'].includes(server.address) || (attestedAddress && server.address === attestedAddress), 'must reach the attested disposable server');
    const existing = await admin.query("SELECT count(*)::integer AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast') AND c.relkind IN ('r','p','v','m','S','f') AND c.relname NOT LIKE 'pg_%'");
    assert.equal(existing.rows[0].count, 0, 'fixture refuses a nonempty DB');
    assert.equal((await admin.query("SELECT 1 FROM pg_roles WHERE rolname='console_session_runtime'")).rowCount, 0, 'fixture requires a fresh synthetic runtime LOGIN');
    const hadCapability = (await admin.query("SELECT 1 FROM pg_roles WHERE rolname='pandapay_console_session'")).rowCount > 0;
    await admin.query(fs.readFileSync(path.join(__dirname, '../db/pandapay-auth/init.sql'), 'utf8'));
    const migration = fs.readFileSync(path.join(__dirname, '../db/migrations/0009_console_browser_sessions.sql'), 'utf8');
    async function migrate() { await admin.query('BEGIN'); try { await admin.query(migration); await admin.query('COMMIT'); } catch (error) { await admin.query('ROLLBACK'); throw error; } }
    await migrate();
    if (!hadCapability) createdRoles.push('pandapay_console_session');
    const password = crypto.randomBytes(32).toString('hex');
    assert.equal(await configureConsoleSessionLogin(admin, {}), false);
    assert.equal(await configureConsoleSessionLogin(admin, { CONSOLE_SESSION_DB_PASSWORD: password }), true);
    createdRoles.push('console_session_runtime');
    assert.equal(await configureConsoleSessionLogin(admin, { CONSOLE_SESSION_DB_PASSWORD: crypto.randomBytes(32).toString('hex') }), true);
    assert.doesNotMatch(configureConsoleSessionLogin.toString(), /ALTER\s+ROLE[\s\S]*PASSWORD/i, 'repeat bootstrap must never issue a password alteration');
    const runtimeUrl = new URL(raw); runtimeUrl.username = 'console_session_runtime'; runtimeUrl.password = password;
    pool = new Pool({ connectionString: runtimeUrl.toString(), ssl: false, max: 2, connectionTimeoutMillis: 3000 });
    const identity = (await pool.query('SELECT current_user AS name')).rows[0];
    assert.equal(identity.name, 'console_session_runtime', 'fixture must use an independent actual LOGIN');
    // This connection authenticates using the original password after repeat
    // bootstrap. No superuser-only password catalog is read by the fixture.
    const attributes = (await pool.query('SELECT rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolreplication FROM pg_roles WHERE rolname=current_user')).rows[0];
    assert.deepEqual(Object.values(attributes), [false, false, false, false, false]);
    await assert.rejects(pool.query('SELECT * FROM public.users'), error => error.code === '42501');
    await assert.rejects(pool.query('SELECT * FROM public.refresh_tokens'), error => error.code === '42501');
    await assert.rejects(pool.query('CREATE TABLE console_private.forbidden(id integer)'), error => error.code === '42501');
    await assert.rejects(pool.query(`SET ROLE "${server.owner.replaceAll('"', '""')}"`), error => error.code === '42501');
    const ordinaryPassword = crypto.randomBytes(32).toString('hex');
    await admin.query(`CREATE ROLE "${ordinaryName}" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '${ordinaryPassword}'`);
    createdRoles.push(ordinaryName);
    await admin.query(`GRANT USAGE ON SCHEMA public TO "${ordinaryName}"`);
    const ordinaryUrl = new URL(raw); ordinaryUrl.username = ordinaryName; ordinaryUrl.password = ordinaryPassword;
    const ordinary = new Client({ connectionString: ordinaryUrl.toString(), ssl: false, connectionTimeoutMillis: 3000 });
    await ordinary.connect(); clients.push(ordinary);
    await assert.rejects(ordinary.query('SELECT * FROM console_private.sessions'), error => error.code === '42501');
    await assert.rejects(ordinary.query('SET ROLE pandapay_console_session'), error => error.code === '42501');

    const encryptionKey = crypto.randomBytes(32).toString('base64');
    runtime = createConsoleBrowserRuntime({ env: {
      NODE_ENV: 'test', DB_SSL: 'false', CONSOLE_BROWSER_ENABLED: 'true',
      CONSOLE_SESSION_DATABASE_URL: runtimeUrl.toString(), CONSOLE_SESSION_ENCRYPTION_KEY: encryptionKey,
      CONSOLE_BROWSER_ORIGIN: 'https://console.example.test',
    }, logger: { error() {} } });
    await runtime.readiness();
    for (const privilege of ['INSERT', 'UPDATE', 'DELETE', 'SELECT']) {
      await admin.query(`REVOKE ${privilege} ON console_private.sessions FROM pandapay_console_session`);
      await assert.rejects(runtime.readiness(), 'readiness must require every needed DML privilege');
      await admin.query(`GRANT ${privilege} ON console_private.sessions TO pandapay_console_session`);
      await runtime.readiness();
    }
    for (const [unsafe, restore] of [['CREATEDB', 'NOCREATEDB'], ['CREATEROLE', 'NOCREATEROLE'], ['REPLICATION', 'NOREPLICATION']]) {
      await admin.query(`ALTER ROLE pandapay_console_session ${unsafe}`);
      await assert.rejects(configureConsoleSessionLogin(admin, { CONSOLE_SESSION_DB_PASSWORD: password }), /unsafe/i);
      await assert.rejects(runtime.readiness(), 'capability drift must prevent readiness');
      await admin.query(`ALTER ROLE pandapay_console_session ${restore}`);
      await runtime.readiness();
    }
    await admin.query(`GRANT "${ordinaryName}" TO pandapay_console_session`);
    await assert.rejects(configureConsoleSessionLogin(admin, { CONSOLE_SESSION_DB_PASSWORD: password }), /membership|inherit|unsafe/i);
    await assert.rejects(runtime.readiness(), 'unexpected inherited capability must prevent readiness');
    await admin.query(`REVOKE "${ordinaryName}" FROM pandapay_console_session`);
    await admin.query(`GRANT "${ordinaryName}" TO console_session_runtime`);
    await assert.rejects(configureConsoleSessionLogin(admin, { CONSOLE_SESSION_DB_PASSWORD: password }), /membership|inherit|unsafe/i);
    await assert.rejects(runtime.readiness(), 'unexpected runtime membership must prevent readiness');
    await admin.query(`REVOKE "${ordinaryName}" FROM console_session_runtime`);
    await runtime.readiness();
    for (const [unsafe, restore] of [['NO FORCE ROW LEVEL SECURITY', 'FORCE ROW LEVEL SECURITY'], ['DISABLE ROW LEVEL SECURITY', 'ENABLE ROW LEVEL SECURITY']]) {
      await admin.query(`ALTER TABLE console_private.sessions ${unsafe}`);
      await assert.rejects(runtime.readiness(), 'disabled or unforced RLS must prevent readiness');
      await admin.query(`ALTER TABLE console_private.sessions ${restore}`);
      await runtime.readiness();
    }
    for (const owner of ['pandapay_console_session', 'console_session_runtime']) {
      // PG16+ CREATEROLE grants ADMIN without SET on newly created roles.
      // Temporarily add SET only to this fixture operator, retaining and
      // restoring its own grant separately from the bootstrap grantor.
      const operator = '"'+server.owner.replaceAll('"', '""')+'"';
      const prior = (await admin.query('SELECT inherit_option,set_option FROM pg_auth_members WHERE roleid=$1::regrole AND member=current_user::regrole AND grantor=current_user::regrole', [owner])).rows[0];
      if (!server.superuser) {
        await admin.query(`GRANT "${owner}" TO ${operator} WITH INHERIT TRUE GRANTED BY ${operator}`);
        await admin.query(`GRANT "${owner}" TO ${operator} WITH SET TRUE GRANTED BY ${operator}`);
      }
      try {
        // A nonsuperuser may transfer ownership only when the proposed owner
        // can CREATE in the schema. Remove that temporary permission before
        // asserting ownership itself is rejected by runtime readiness.
        if (!server.superuser) await admin.query(`GRANT CREATE ON SCHEMA console_private TO "${owner}"`);
        try { await admin.query(`ALTER TABLE console_private.sessions OWNER TO "${owner}"`); }
        finally { if (!server.superuser) await admin.query(`REVOKE CREATE ON SCHEMA console_private FROM "${owner}"`); }
        await assert.rejects(runtime.readiness(), 'capability/runtime ownership must prevent readiness');
        await admin.query(`ALTER TABLE console_private.sessions OWNER TO ${operator}`);
      } finally {
        if (!server.superuser) {
          if (prior) {
            await admin.query(`GRANT "${owner}" TO ${operator} WITH INHERIT ${prior.inherit_option ? 'TRUE' : 'FALSE'} GRANTED BY ${operator}`);
            await admin.query(`GRANT "${owner}" TO ${operator} WITH SET ${prior.set_option ? 'TRUE' : 'FALSE'} GRANTED BY ${operator}`);
          } else await admin.query(`REVOKE "${owner}" FROM ${operator} GRANTED BY ${operator}`);
        }
      }
      // ALTER OWNER rewrites owner ACL entries. Reapply the canonical grant
      // migration after restoring ownership, as an operator repair would.
      await migrate();
      await runtime.readiness();
    }
    for (const [table, permission] of [['users', 'SELECT(id)'], ['users', 'UPDATE(token_version)'], ['refresh_tokens', 'SELECT(id)']]) {
      await admin.query(`GRANT ${permission} ON public.${table} TO pandapay_console_session`);
      await assert.rejects(runtime.readiness(), 'even column-level identity/credential grants must prevent readiness');
      await admin.query(`REVOKE ${permission} ON public.${table} FROM pandapay_console_session`);
      await runtime.readiness();
    }
    const store = createConsoleSessionStore({ pool, encryptionKey });
    const session = await store.create({ access: 'synthetic-private-access', refresh: 'synthetic-private-refresh' });
    const row = (await admin.query('SELECT * FROM console_private.sessions WHERE session_hash=$1', [digest(session.id)])).rows[0];
    assert.ok(row);
    assert.equal(row.session_hash, digest(session.id));
    assert.notEqual(row.session_hash, session.id);
    assert.equal(Buffer.from(row.encrypted_tokens, 'base64').includes(Buffer.from('synthetic-private')), false);
    assert.equal(new Date(row.expires_at)-new Date(row.created_at), 12*3600000);
    assert.deepEqual(await store.withSession(session.id, state => ({ csrf: state.csrf, refresh: state.refresh })), { csrf: session.csrf, refresh: 'synthetic-private-refresh' });
    await migrate();
    assert.equal(await store.withSession(session.id, state => state.csrf), session.csrf, 'migration replay preserves decryptable sessions');
    const activityBefore = (await admin.query('SELECT last_used_at,encrypted_tokens FROM console_private.sessions WHERE session_hash=$1', [digest(session.id)])).rows[0];
    assert.deepEqual(await store.withSession(session.id, () => ({ denied: true })), { denied: true });
    const activityAfter = (await admin.query('SELECT last_used_at,encrypted_tokens FROM console_private.sessions WHERE session_hash=$1', [digest(session.id)])).rows[0];
    assert.equal(activityAfter.last_used_at.getTime(), activityBefore.last_used_at.getTime());
    assert.equal(activityAfter.encrypted_tokens, activityBefore.encrypted_tokens);

    let active = 0, maximum = 0;
    const order = [];
    await Promise.all([1, 2].map(value => store.withSession(session.id, async state => {
      active++; maximum = Math.max(maximum, active); order.push(state.refresh);
      await new Promise(resolve => setTimeout(resolve, 35));
      state.refresh += '-'+value; active--; return { ok: true };
    })));
    assert.equal(maximum, 1, 'FOR UPDATE must serialize refresh callbacks for one opaque session');
    assert.deepEqual(order, ['synthetic-private-refresh', 'synthetic-private-refresh-1']);
    await assert.rejects(store.withSession(session.id, async state => { state.refresh = 'confirmed-rotation'; throw new Error('later-upstream-503'); }), /later-upstream-503/);
    assert.equal(await store.withSession(session.id, state => state.refresh), 'confirmed-rotation');

    const second = await store.create({ access: 'second-access', refresh: 'second-refresh' });
    const originalSecond = (await admin.query('SELECT encrypted_tokens FROM console_private.sessions WHERE session_hash=$1', [digest(second.id)])).rows[0].encrypted_tokens;
    await admin.query('UPDATE console_private.sessions SET encrypted_tokens=$2 WHERE session_hash=$1', [digest(second.id), row.encrypted_tokens]);
    await assert.rejects(store.withSession(second.id, () => assert.fail('copied ciphertext/AAD must fail')));
    const corrupt = Buffer.from(originalSecond, 'base64'); corrupt[28] ^= 1;
    await admin.query('UPDATE console_private.sessions SET encrypted_tokens=$2 WHERE session_hash=$1', [digest(second.id), corrupt.toString('base64')]);
    await assert.rejects(store.withSession(second.id, () => assert.fail('tampered ciphertext must fail')));
    await admin.query('UPDATE console_private.sessions SET encrypted_tokens=$2 WHERE session_hash=$1', [digest(second.id), originalSecond]);
    const wrongKeyStore = createConsoleSessionStore({ pool, encryptionKey: crypto.randomBytes(32).toString('base64') });
    await assert.rejects(wrongKeyStore.withSession(second.id, () => assert.fail('wrong key must fail')));
    assert.equal(await store.withSession(second.id, state => state.refresh), 'second-refresh');

    const idle = await store.create({ access: 'idle', refresh: 'idle' }), expired = await store.create({ access: 'expired', refresh: 'expired' });
    await admin.query("UPDATE console_private.sessions SET last_used_at=now()-interval '31 minutes' WHERE session_hash=$1", [digest(idle.id)]);
    await admin.query("UPDATE console_private.sessions SET created_at=now()-interval '13 hours',expires_at=now()-interval '1 hour' WHERE session_hash=$1", [digest(expired.id)]);
    assert.equal(await store.withSession(idle.id, () => assert.fail('idle session must not authorize')), null);
    assert.equal(await store.withSession(expired.id, () => assert.fail('expired session must not authorize')), null);
    await store.cleanup();
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM console_private.sessions WHERE session_hash=ANY($1::text[])', [[digest(idle.id), digest(expired.id)]])).rows[0].count, 0);
    assert.equal(await store.withSession(session.id, state => state.refresh), 'confirmed-rotation');
    for (let index = 0; index < 105; index++) {
      await admin.query("INSERT INTO console_private.sessions(session_hash,encrypted_tokens,created_at,last_used_at,expires_at) VALUES ($1,'expired-synthetic',now()-interval '13 hours',now()-interval '13 hours',now()-interval '1 hour')", [crypto.randomBytes(32).toString('hex')]);
    }
    assert.equal((await store.cleanup()).rowCount, 100);
    assert.equal((await store.cleanup()).rowCount, 5);
    await store.withSession(second.id, () => ({ destroy: true }));
    assert.equal(await store.withSession(second.id, () => assert.fail('destroyed session cannot replay')), null);
    assert.equal((await admin.query('SELECT count(*)::integer AS count FROM console_private.sessions')).rows[0].count, 1);
    console.log('PASS: console browser independent restricted LOGIN/bootstrap replay, ordinary/PUBLIC/owner denial, encrypted AAD/cipher/key isolation, serialized refresh and rotation recovery, expiry/idle/100-row cleanup, session destruction and migration replay');
  } catch (error) {
    console.error('Synthetic console browser execution failed', error.stack);
    throw error;
  } finally {
    if (runtime) await runtime.close();
    if (pool) await pool.end();
    for (const client of clients) await client.end();
    await admin.query('ROLLBACK').catch(() => {});
    try {
      for (const role of [...createdRoles].reverse()) {
        // All listed roles were created by this invocation. CREATEROLE's
        // ADMIN grant is not SET on managed PG16+, while DROP OWNED needs SET.
        const operator = '"'+operatorName.replaceAll('"', '""')+'"';
        await admin.query(`GRANT "${role}" TO ${operator} WITH SET TRUE GRANTED BY ${operator}`);
        await admin.query(`DROP OWNED BY "${role}"`);
        await admin.query(`DROP ROLE "${role}"`);
      }
    } finally { await admin.end(); }
  }
}
main().catch(error => { console.error('Synthetic console browser fixture failed', error.stack); process.exitCode = 1; });
