'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomBytes } = require('node:crypto');
const { createConsoleSessionStore, digest } = require('../src/services/consoleSessionStore');

const key = () => randomBytes(32).toString('base64');

function fakePool() {
  const rows = new Map(), calls = [], releases = [];
  let fail, rollbackFails = false;
  async function query(sql, values = []) {
    calls.push({ sql, values });
    if (fail?.(sql)) throw new Error('synthetic SQL failure');
    if (sql === 'ROLLBACK' && rollbackFails) throw new Error('rollback failed');
    if (sql.startsWith('INSERT INTO')) rows.set(values[0], { encrypted_tokens: values[1] });
    if (sql.startsWith('SELECT encrypted_tokens')) return { rows: rows.has(values[0]) ? [{ ...rows.get(values[0]) }] : [] };
    if (sql.startsWith('UPDATE console_private.sessions')) rows.set(values[0], { encrypted_tokens: values[1] });
    if (sql.startsWith('DELETE FROM') && values.length) rows.delete(values[0]);
    return { rows: [], rowCount: 0 };
  }
  return {
    rows, calls, releases, query,
    setFailure(value, brokenRollback = false) { fail = value; rollbackFails = brokenRollback; },
    async connect() { return { query, release(error) { releases.push(error); } }; },
  };
}

test('console store requires a canonical separate 256-bit encryption key', () => {
  for (const encryptionKey of [undefined, '', 'password', randomBytes(31).toString('base64'), randomBytes(33).toString('base64'), key()+'\n']) {
    assert.throws(() => createConsoleSessionStore({ pool: fakePool(), encryptionKey }), /configuration invalid/);
  }
  assert.throws(() => createConsoleSessionStore({ encryptionKey: key() }), /configuration invalid/);
});

test('console store saves only an opaque ID hash and authenticated ciphertext, using database expiry', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  const session = await store.create({ access: 'synthetic-private-access', refresh: 'synthetic-private-refresh' });
  assert.match(session.id, /^[A-Za-z0-9_-]{43}$/);
  assert.match(session.csrf, /^[A-Za-z0-9_-]{43}$/);
  const insert = pool.calls[0];
  assert.equal(insert.values[0], digest(session.id));
  assert.equal(insert.values.length, 2);
  assert.match(insert.sql, /now\(\)\+interval '12 hours'/);
  assert.doesNotMatch(insert.values[1], /synthetic-private|access|refresh/);
  assert.equal(Buffer.from(insert.values[1], 'base64').includes(Buffer.from('synthetic-private')), false);
  assert.equal(JSON.stringify(pool.rows).includes(session.id), false);
});

test('console store rejects malformed identifiers without checking out a connection', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  for (const id of [null, '', 'short', 'a'.repeat(42), 'a'.repeat(44), '../'+ 'a'.repeat(40), ' '.repeat(43)]) assert.equal(await store.withSession(id, () => assert.fail('must not enter')), null);
  assert.equal(pool.calls.length, 0);
});

test('missing, expired or idle-filtered console session returns no state and releases its client', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  assert.equal(await store.withSession(randomBytes(32).toString('base64url'), () => assert.fail('must not enter')), null);
  const select = pool.calls.find(row => row.sql.startsWith('SELECT encrypted_tokens'));
  assert.match(select.sql, /expires_at>now\(\)/);
  assert.match(select.sql, /last_used_at>now\(\)-interval '30 minutes'/);
  assert.match(select.sql, /FOR UPDATE/);
  assert.equal(pool.calls.at(-1).sql, 'COMMIT');
  assert.equal(pool.releases.length, 1);
});

test('confirmed token rotation persists before a later upstream callback error is rethrown', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  const session = await store.create({ access: 'old-access', refresh: 'old-refresh' });
  const failure = new Error('later provider outage');
  await assert.rejects(store.withSession(session.id, async state => { state.access = 'rotated-access'; state.refresh = 'rotated-refresh'; throw failure; }), error => error === failure);
  assert.equal(pool.calls.at(-1).sql, 'COMMIT');
  assert.equal(pool.calls.some(row => row.sql === 'ROLLBACK'), false);
  await store.withSession(session.id, state => { assert.equal(state.refresh, 'rotated-refresh'); assert.equal(state.access, 'rotated-access'); assert.equal(state.csrf, session.csrf); return { ok: true }; });
});

test('console session destroy removes ciphertext and cannot be replayed', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  const session = await store.create({ access: 'a', refresh: 'r' });
  assert.deepEqual(await store.withSession(session.id, () => ({ destroy: true })), { destroy: true });
  assert.equal(await store.withSession(session.id, () => assert.fail('destroyed')), null);
  assert.equal(pool.rows.size, 0);
});

test('denied CSRF work neither re-encrypts credentials nor extends idle activity', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  const session = await store.create({ access: 'a', refresh: 'r' });
  const original = pool.rows.get(digest(session.id)).encrypted_tokens;
  assert.deepEqual(await store.withSession(session.id, state => { state.refresh = 'untrusted-mutation'; return { denied: true }; }), { denied: true });
  assert.equal(pool.rows.get(digest(session.id)).encrypted_tokens, original);
  assert.equal(pool.calls.some(row => row.sql.startsWith('UPDATE console_private.sessions')), false);
  assert.equal(pool.calls.at(-1).sql, 'COMMIT');
});

test('at most two upstream session operations occupy the dedicated pool and capacity recovers', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  const sessions = await Promise.all([1, 2, 3].map(value => store.create({ access: 'a'+value, refresh: 'r'+value })));
  let release, entered = 0, bothEntered;
  const gate = new Promise(resolve => { release = resolve; });
  const ready = new Promise(resolve => { bothEntered = resolve; });
  const pending = sessions.slice(0, 2).map(session => store.withSession(session.id, async () => { if (++entered === 2) bothEntered(); await gate; return { ok: true }; }));
  await ready;
  await assert.rejects(store.withSession(sessions[2].id, () => assert.fail('third operation must not start')), /capacity unavailable/);
  release(); await Promise.all(pending);
  assert.deepEqual(await store.withSession(sessions[2].id, () => ({ ok: true })), { ok: true });
});

test('failed connection checkout returns the session capacity permit', async () => {
  const pool = fakePool(), originalConnect = pool.connect;
  const store = createConsoleSessionStore({ pool, encryptionKey: key() });
  const session = await store.create({ access: 'a', refresh: 'r' });
  pool.connect = async () => { throw new Error('checkout failed'); };
  for (let index = 0; index < 3; index++) await assert.rejects(store.withSession(session.id, () => ({})), /checkout failed/);
  pool.connect = originalConnect;
  assert.deepEqual(await store.withSession(session.id, () => ({ ok: true })), { ok: true });
});

test('console runtime remains opt-in and reserves a third connection for readiness', async () => {
  const { createConsoleBrowserRuntime } = require('../src/services/consoleBrowserRuntime');
  assert.equal(createConsoleBrowserRuntime({ env: {} }), null);
  let options, ended = false;
  class PoolClass {
    constructor(value) { options = value; }
    on() {}
    async query(sql) {
      return { rows: sql.includes('FROM pg_catalog.pg_roles') ? [{ bounded: true, can_create: false, reads_users: false, reads_refresh: false, manages_sessions: true, unsafe_membership: false, unsafe_capability: false, table_safe: true }] : [] };
    }
    async end() { ended = true; }
  }
  const runtime = createConsoleBrowserRuntime({ env: { NODE_ENV: 'test', DB_SSL: 'false', CONSOLE_BROWSER_ENABLED: 'true', CONSOLE_SESSION_DATABASE_URL: 'postgresql://synthetic:synthetic@localhost/console_browser_test', CONSOLE_SESSION_ENCRYPTION_KEY: key(), CONSOLE_BROWSER_ORIGIN: 'https://console.example.test' }, PoolClass });
  assert.equal(options.max, 3); assert.equal(options.statement_timeout, 5000);
  await runtime.readiness(); await runtime.close(); assert.equal(ended, true);
});

test('GCM rejects copied ciphertext, corrupted bytes and a different key before invoking application work', async () => {
  const pool = fakePool(), encryptionKey = key(), store = createConsoleSessionStore({ pool, encryptionKey });
  const first = await store.create({ access: 'a', refresh: 'r' }), second = await store.create({ access: 'b', refresh: 's' });
  pool.rows.get(digest(second.id)).encrypted_tokens = pool.rows.get(digest(first.id)).encrypted_tokens;
  await assert.rejects(store.withSession(second.id, () => assert.fail('AAD mismatch must fail')));
  const bytes = Buffer.from(pool.rows.get(digest(first.id)).encrypted_tokens, 'base64');
  bytes[28] ^= 1;
  pool.rows.get(digest(first.id)).encrypted_tokens = bytes.toString('base64');
  await assert.rejects(store.withSession(first.id, () => assert.fail('corruption must fail')));
  const third = await store.create({ access: 'c', refresh: 't' });
  const wrong = createConsoleSessionStore({ pool, encryptionKey: key() });
  await assert.rejects(wrong.withSession(third.id, () => assert.fail('wrong key must fail')));
  assert.equal(pool.calls.filter(row => row.sql === 'ROLLBACK').length, 3);
});

test('database failures roll back and an uncertain rollback destroys the pooled session', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  const session = await store.create({ access: 'a', refresh: 'r' });
  pool.setFailure(sql => sql.startsWith('UPDATE console_private.sessions'), true);
  await assert.rejects(store.withSession(session.id, () => ({ ok: true })), /synthetic SQL failure/);
  assert.equal(pool.releases.length, 1);
  assert.match(pool.releases[0].message, /rollback failed/);
});

test('cleanup targets only expired or idle private sessions in batches of 100', async () => {
  const pool = fakePool(), store = createConsoleSessionStore({ pool, encryptionKey: key() });
  await store.cleanup();
  assert.match(pool.calls[0].sql, /DELETE FROM console_private\.sessions/);
  assert.match(pool.calls[0].sql, /expires_at<=now\(\)/);
  assert.match(pool.calls[0].sql, /last_used_at<=now\(\)-interval '30 minutes'/);
  assert.match(pool.calls[0].sql, /LIMIT 100/);
  assert.doesNotMatch(pool.calls[0].sql, /public\.|users|refresh_tokens/);
});
