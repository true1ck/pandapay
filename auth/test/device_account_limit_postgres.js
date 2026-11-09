'use strict';

// Coordinator-invoked fixture for a disposable loopback PostgreSQL database.
// Run: DEVICE_LIMIT_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:PORT/account_recovery_test node --test test/device_account_limit_postgres.js
// Reuses the account_recovery_test schema. Refuses anything not on loopback.
const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { Pool } = require('pg');

const url = process.env.DEVICE_LIMIT_TEST_DATABASE_URL;
if (!url) throw new Error('DEVICE_LIMIT_TEST_DATABASE_URL is required');
if (!['127.0.0.1', 'localhost', '::1'].includes(new URL(url).hostname)) throw new Error('DEVICE_LIMIT_TEST_DATABASE_URL must be on loopback');
const pool = new Pool({ connectionString: url, max: 4 });
const { createDeviceAccountLimit } = require('../src/services/deviceAccountLimit');

test.before(async () => { await pool.query('TRUNCATE users CASCADE'); });
test.after(async () => { await pool.end(); });

let n = 0;
async function accountOn(deviceId, { deleted = false } = {}) {
  const id = randomUUID();
  await pool.query('INSERT INTO users (id, email, is_email_verified, deleted) VALUES ($1, $2, TRUE, $3)', [id, `dev${++n}@example.com`, deleted]);
  await pool.query(`INSERT INTO user_devices (user_id, device_identifier, device_platform) VALUES ($1, $2, 'android')`, [id, deviceId]);
  return id;
}

function limiter({ limit = 3, enforce = false, failQuery = false } = {}) {
  const events = [];
  const svc = createDeviceAccountLimit({
    query: failQuery ? async () => { throw new Error('db down'); } : (...a) => pool.query(...a),
    audit: async e => { events.push(e); },
    limit, enforce, logger: { warn() {} },
  });
  return { svc, events };
}

test('log-only: the fourth account on a phone is allowed but recorded', async () => {
  const { svc, events } = limiter();
  for (let i = 0; i < 3; i++) await accountOn('phone-a');
  const before = await svc.admitNewAccount({ deviceId: 'phone-a', ip: '203.0.113.9', userAgent: 'ua' });
  assert.deepEqual([before.allowed, before.accounts], [true, 3]);
  assert.equal(events.length, 1);
  assert.deepEqual(events[0], {
    userId: null, action: 'device_account_limit', status: 'flagged', riskLevel: 'SUSPICIOUS',
    deviceId: 'phone-a', ipAddress: '203.0.113.9', userAgent: 'ua', meta: { accounts: 3, limit: 3, enforced: false },
  });
});

test('under the limit nothing is recorded', async () => {
  const { svc, events } = limiter();
  await accountOn('phone-b'); await accountOn('phone-b');
  assert.deepEqual(await svc.admitNewAccount({ deviceId: 'phone-b' }), { allowed: true, accounts: 2 });
  assert.equal(events.length, 0);
});

test('enforced: the fourth account is refused and recorded as blocked', async () => {
  const { svc, events } = limiter({ enforce: true });
  for (let i = 0; i < 3; i++) await accountOn('phone-c');
  const result = await svc.admitNewAccount({ deviceId: 'phone-c' });
  assert.deepEqual([result.allowed, result.accounts], [false, 3]);
  assert.equal(events[0].status, 'blocked');
  assert.equal(events[0].meta.enforced, true);
});

test('deleted accounts do not count, and one user on one phone counts once', async () => {
  const { svc } = limiter({ limit: 2, enforce: true });
  await accountOn('phone-d', { deleted: true }); await accountOn('phone-d', { deleted: true });
  const live = await accountOn('phone-d');
  await pool.query(`INSERT INTO user_devices (user_id, device_identifier, device_platform) VALUES ($1, 'phone-d-other', 'android')`, [live]);
  assert.equal(await svc.liveAccountsOn('phone-d'), 1);
  assert.equal((await svc.admitNewAccount({ deviceId: 'phone-d' })).allowed, true);
});

test('placeholders shared by many installs are never counted as one phone', async () => {
  const { svc, events } = limiter({ limit: 1, enforce: true });
  for (const placeholder of ['unknown-device', 'app-mobile']) {
    await accountOn(placeholder); await accountOn(placeholder);
    assert.deepEqual(await svc.admitNewAccount({ deviceId: placeholder }), { allowed: true, accounts: null });
  }
  assert.deepEqual(await svc.admitNewAccount({ deviceId: '' }), { allowed: true, accounts: null });
  assert.deepEqual(await svc.admitNewAccount({ deviceId: undefined }), { allowed: true, accounts: null });
  assert.equal(events.length, 0);
});

test('a limit of zero switches the check off', async () => {
  const { svc, events } = limiter({ limit: 0, enforce: true });
  for (let i = 0; i < 5; i++) await accountOn('phone-e');
  assert.deepEqual(await svc.admitNewAccount({ deviceId: 'phone-e' }), { allowed: true, accounts: null });
  assert.deepEqual(await svc.flagNewAccount({ userId: randomUUID(), deviceId: 'phone-e' }), { flagged: false });
  assert.equal(events.length, 0);
});

test('a database failure never blocks a sign-up, even when enforcing', async () => {
  const { svc, events } = limiter({ enforce: true, failQuery: true });
  assert.deepEqual(await svc.admitNewAccount({ deviceId: 'phone-f' }), { allowed: true, accounts: null });
  assert.deepEqual(await svc.flagNewAccount({ userId: randomUUID(), deviceId: 'phone-f' }), { flagged: false });
  assert.equal(events.length, 0);
});

test('an account created another way is flagged only once it makes the phone go over', async () => {
  const { svc, events } = limiter({ enforce: true });
  for (let i = 0; i < 3; i++) await accountOn('phone-g');
  const third = await svc.flagNewAccount({ userId: randomUUID(), deviceId: 'phone-g' });
  assert.deepEqual(third, { flagged: false, accounts: 3 });
  const fourth = await accountOn('phone-g');
  const flagged = await svc.flagNewAccount({ userId: fourth, deviceId: 'phone-g', ip: '198.51.100.4' });
  assert.deepEqual([flagged.flagged, flagged.accounts], [true, 4]);
  assert.equal(events.length, 1);
  assert.equal(events[0].status, 'flagged', 'after the fact it only records, even when enforcing');
  assert.equal(events[0].userId, fourth);
});

// ------------------------------------------------------------ admin cluster view

const clusters = require('../scripts/account_clusters');
const runClusters = async (...argv) => {
  const out = [];
  await clusters.run({ pool, argv, write: v => out.push(v) });
  return { text: out.join('\n'), json: JSON.parse(out.join('\n')) };
};

test('clusters: devices lists phones that hold more than the minimum, with masked members', async () => {
  await pool.query('TRUNCATE users CASCADE');
  const crowd = []; for (let i = 0; i < 4; i++) crowd.push(await accountOn('shared-phone'));
  await accountOn('quiet-phone'); await accountOn('quiet-phone');
  for (let i = 0; i < 6; i++) await accountOn('app-mobile');
  await accountOn('shared-phone', { deleted: true });
  const r = await runClusters('devices', '--min', '3');
  assert.equal(r.json.clusters.length, 1, 'only the real shared phone; placeholders and small groups are left out');
  assert.equal(r.json.clusters[0].device, 'shared-phone');
  assert.equal(r.json.clusters[0].accounts, 4, 'a deleted account is not counted');
  assert.deepEqual(r.json.clusters[0].members.map(m => m.user_id).sort(), [...crowd].sort());
  assert.match(r.json.clusters[0].members[0].account, /^d•••@example\.com$/);
  assert.doesNotMatch(r.text, /dev\d+@example/);
  assert.equal((await runClusters('devices', '--min', '4')).json.clusters.length, 0, 'the minimum is exclusive');
});

test('clusters: ips lists addresses that made many new accounts recently', async () => {
  await pool.query('TRUNCATE users CASCADE');
  const ids = []; for (let i = 0; i < 3; i++) ids.push(await accountOn(`ip-phone-${i}`));
  const old = await accountOn('ip-phone-old');
  const audit = (userId, ip, isNew, ageDays = 0) => pool.query(
    `INSERT INTO auth_audit (user_id, action, status, ip_address, meta, created_at)
     VALUES ($1, 'otp_verify_email', 'success', $2, $3, NOW() - ($4::int * INTERVAL '1 day'))`, [userId, ip, JSON.stringify({ is_new_account: isNew }), ageDays]);
  for (const id of ids) await audit(id, '203.0.113.50', true);
  await audit(old, '203.0.113.50', true, 30);
  await audit(ids[0], '198.51.100.7', false);
  const r = await runClusters('ips', '--days', '7', '--min', '2');
  assert.equal(r.json.clusters.length, 1);
  assert.equal(r.json.clusters[0].ip, '203.0.113.50');
  assert.equal(r.json.clusters[0].accounts, 3, 'an old sign-up and a plain sign-in do not count');
  assert.match(r.json.note, /not proof/);
});

test('clusters: flags lists what the device limit recorded, newest first', async () => {
  await pool.query('TRUNCATE users CASCADE');
  const id = await accountOn('flag-phone');
  const log = (status, ageHours) => pool.query(
    `INSERT INTO auth_audit (user_id, action, status, device_id, ip_address, meta, created_at)
     VALUES ($1, 'device_account_limit', $2, 'flag-phone', '203.0.113.8', $3, NOW() - ($4::int * INTERVAL '1 hour'))`,
    [id, status, JSON.stringify({ accounts: 4, limit: 3, enforced: status === 'blocked' }), ageHours]);
  await log('flagged', 5); await log('blocked', 1); await log('flagged', 24 * 20);
  const r = await runClusters('flags', '--days', '7');
  assert.deepEqual(r.json.events.map(e => [e.status, e.accounts_on_device, e.limit, e.enforced]), [['blocked', 4, 3, true], ['flagged', 4, 3, false]]);
  assert.match(r.json.events[0].account, /^d•••@example\.com$/);
});

test('clusters: options are checked and unknown commands refused', async () => {
  await assert.rejects(runClusters('devices', '--min', '1'), /--min must be/);
  await assert.rejects(runClusters('ips', '--days', '0'), /--days must be/);
  await assert.rejects(runClusters('flags', '--limit', '500'), /--limit must be/);
  await assert.rejects(runClusters('devices', 'min', '3'), /Bad option/);
  await assert.rejects(runClusters('phones'), /Usage/);
});
