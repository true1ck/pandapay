'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { readRetentionPolicy } = require('../src/services/retentionPolicy');
const { runRetention, RETENTION_LOCK } = require('../src/services/retentionRunner');
const { main } = require('../scripts/retention');

function fakeClient({ counts = [0], locked = true, unlock = true, fail } = {}) {
  const calls = [];
  let ended = false;
  const client = {
    calls,
    async connect() {},
    async end() { ended = true; },
    get ended() { return ended; },
    async query(sql, values) {
      calls.push({ sql, values });
      if (fail?.(sql)) throw Object.assign(new Error('private-url-and-contact@example.test'), { code: '42501' });
      if (sql.includes('pg_try_advisory_lock')) return { rows: [{ locked }] };
      if (sql.includes('pg_advisory_unlock')) return { rows: [{ unlocked: unlock }] };
      if (sql.includes('AS count FROM')) return { rows: [{ count: counts.shift() ?? 0 }] };
      return { rows: [] };
    },
  };
  return client;
}

test('retention preserves all rows and avoids any connection without configured policies', async () => {
  const policy = readRetentionPolicy({});
  const output = await runRetention(null, policy);
  assert.equal(output.status, 'no_policy');
  assert.equal(output.mode, 'dry_run');
  assert.deepEqual(output.scopes, []);
  await assert.rejects(runRetention(null, policy, { apply: true }), /explicit retention policy/);
});

test('retention policy validates days and free-host resource caps strictly', () => {
  const valid = readRetentionPolicy({ AUTH_DB_ACCESS_LOG_RETENTION_DAYS: '30', AUTH_ABUSE_STATE_RETENTION_DAYS: '1' });
  assert.deepEqual(valid.scopes, [{ scope: 'db_access_log', days: 30 }, { scope: 'expired_abuse_state', days: 1 }]);
  assert.equal(Object.isFrozen(valid.scopes), true);
  for (const [variable, values] of Object.entries({
    AUTH_DB_ACCESS_LOG_RETENTION_DAYS: ['0', '1', '29', '3651', '30.1', '-30', ' 30', '030', '30;DELETE'],
    AUTH_ABUSE_STATE_RETENTION_DAYS: ['0', '366', 'NaN'],
    AUTH_RETENTION_BATCH_SIZE: ['0', '1001'], AUTH_RETENTION_MAX_BATCHES: ['0', '101'],
    AUTH_RETENTION_MAX_DURATION_MS: ['99', '60001'],
  })) for (const value of values) assert.throws(() => readRetentionPolicy({ [variable]: value }));
});

test('unknown, duplicate and prototype scopes cannot become SQL identifiers', async () => {
  const policy = readRetentionPolicy({});
  for (const scope of ['auth_audit', 'otp_requests', 'users', 'db_access_log; DELETE', '__proto__', 'constructor']) {
    await assert.rejects(runRetention(fakeClient(), { ...policy, scopes: [{ scope, days: 30 }] }), /Invalid retention scope/);
  }
  await assert.rejects(runRetention(fakeClient(), { ...policy, scopes: [{ scope: 'db_access_log', days: 30 }, { scope: 'db_access_log', days: 30 }] }), /Invalid retention scope/);
});

test('default dry run uses bounded read-only counts and emits no row data', async () => {
  const client = fakeClient({ counts: [101, 4] });
  const result = await runRetention(client, readRetentionPolicy({ AUTH_DB_ACCESS_LOG_RETENTION_DAYS: '90', AUTH_ABUSE_STATE_RETENTION_DAYS: '2' }));
  assert.deepEqual(result.scopes.map(row => [row.candidates, row.deleted, row.more_possible]), [[100, 0, true], [4, 0, false]]);
  assert.equal(result.batches, 2);
  assert.equal(client.calls.filter(row => row.sql === 'BEGIN READ ONLY').length, 2);
  assert.equal(client.calls.some(row => /\bDELETE\b/.test(row.sql)), false);
  assert.deepEqual(client.calls.filter(row => row.sql.includes('AS count FROM')).map(row => row.values), [[90, 101], [2, 101]]);
  assert.doesNotMatch(JSON.stringify(result), /private|example\.test|bucket_key|query_text/);
});

test('apply requires explicit policy, locks the dedicated session and deletes bounded batches only', async () => {
  const client = fakeClient({ counts: [2, 1, 0] });
  const policy = readRetentionPolicy({ AUTH_DB_ACCESS_LOG_RETENTION_DAYS: '90', AUTH_RETENTION_BATCH_SIZE: '2' });
  const result = await runRetention(client, policy, { apply: true });
  assert.equal(result.scopes[0].deleted, 3);
  assert.equal(result.batches, 2);
  assert.equal(result.scopes[0].more_possible, null);
  const statements = client.calls.filter(row => row.sql.includes('DELETE FROM'));
  assert.equal(statements.length, 2);
  for (const row of statements) {
    assert.match(row.sql, /DELETE FROM ONLY public\.db_access_log/);
    assert.match(row.sql, /FOR UPDATE SKIP LOCKED/);
    assert.match(row.sql, /target\.created_at </);
    assert.deepEqual(row.values, [90, 2]);
  }
  assert.equal(client.calls.some(row => /auth_audit|otp_requests|refresh_tokens|users|contact_resolution_history/.test(row.sql)), false);
  assert.deepEqual(client.calls[0].values, RETENTION_LOCK);
  assert.match(client.calls.at(-1).sql, /pg_advisory_unlock/);
});

test('job batch limit stops safely and leaves a truthful count-only continuation indicator', async () => {
  const client = fakeClient({ counts: [2, 2, 2] });
  const result = await runRetention(client, readRetentionPolicy({ AUTH_DB_ACCESS_LOG_RETENTION_DAYS: '30', AUTH_ABUSE_STATE_RETENTION_DAYS: '1', AUTH_RETENTION_BATCH_SIZE: '2', AUTH_RETENTION_MAX_BATCHES: '1' }), { apply: true });
  assert.equal(result.status, 'budget_exhausted');
  assert.equal(result.batches, 1);
  assert.equal(result.scopes[0].deleted, 2);
  assert.equal(result.scopes[0].more_possible, true);
  assert.equal(result.scopes[1].examined, false);
  assert.equal(result.scopes[1].more_possible, null);
});

test('elapsed job budget prevents a new transaction', async () => {
  const client = fakeClient();
  const times = [0, 101];
  const result = await runRetention(client, readRetentionPolicy({ AUTH_ABUSE_STATE_RETENTION_DAYS: '1', AUTH_RETENTION_MAX_DURATION_MS: '100' }), { apply: true, now: () => times.shift() ?? 101 });
  assert.equal(result.status, 'budget_exhausted');
  assert.equal(client.calls.some(row => row.sql === 'BEGIN'), false);
  assert.equal(result.scopes[0].examined, false);
});

test('busy worker makes no transactions or deletes and does not unlock another session', async () => {
  const client = fakeClient({ locked: false });
  const result = await runRetention(client, readRetentionPolicy({ AUTH_ABUSE_STATE_RETENTION_DAYS: '1' }), { apply: true });
  assert.equal(result.status, 'busy');
  assert.equal(client.calls.length, 1);
});

test('failed batch rolls back and releases its session lock', async () => {
  const client = fakeClient({ fail: sql => sql.includes('DELETE FROM') });
  await assert.rejects(runRetention(client, readRetentionPolicy({ AUTH_ABUSE_STATE_RETENTION_DAYS: '1' }), { apply: true }), { code: '42501' });
  assert.ok(client.calls.some(row => row.sql === 'ROLLBACK'));
  assert.match(client.calls.at(-1).sql, /pg_advisory_unlock/);
});

test('unexpected row counts and uncertain unlock fail closed', async () => {
  for (const count of [-1, 102, '1', NaN]) {
    const client = fakeClient({ counts: [count] });
    await assert.rejects(runRetention(client, readRetentionPolicy({ AUTH_ABUSE_STATE_RETENTION_DAYS: '1' })), /Invalid retention result/);
    assert.ok(client.calls.some(row => row.sql === 'ROLLBACK'));
  }
  await assert.rejects(runRetention(fakeClient({ unlock: false }), readRetentionPolicy({ AUTH_ABUSE_STATE_RETENTION_DAYS: '1' })), /could not be released/);
});

test('CLI is dry-run by default, omits secrets from output and always closes its client', async () => {
  const client = fakeClient({ counts: [1] });
  const writes = [];
  const env = { AUTH_RETENTION_DATABASE_URL: 'postgresql://synthetic:synthetic@localhost/auth_retention_test', NODE_ENV: 'test', DB_SSL: 'false', AUTH_ABUSE_STATE_RETENTION_DAYS: '1' };
  await main({ args: [], env, write: row => writes.push(row), clientFactory: options => { assert.equal(options.ssl, false); return client; } });
  assert.equal(client.ended, true);
  assert.equal(JSON.parse(writes[0]).mode, 'dry_run');
  assert.doesNotMatch(writes[0], /synthetic|postgresql|localhost/);
  const failed = fakeClient({ fail: sql => sql.includes('AS count FROM') });
  await assert.rejects(main({ args: [], env, write() {}, clientFactory: () => failed }));
  assert.equal(failed.ended, true);
});

test('CLI rejects unknown arguments and needs no secret or database for help/no policy', async () => {
  let connections = 0;
  const options = { env: {}, write() {}, clientFactory: () => { connections++; throw new Error('must not connect'); } };
  await main({ ...options, args: [] });
  await main({ ...options, args: ['--help'] });
  assert.equal(connections, 0);
  await assert.rejects(main({ ...options, args: ['--force'] }), /Invalid retention command/);
  await assert.rejects(main({ ...options, args: ['--apply'] }), /explicit retention policy/);
});
