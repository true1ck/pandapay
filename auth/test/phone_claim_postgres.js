'use strict';

// Coordinator-invoked fixture for a disposable loopback PostgreSQL database.
// Run: PHONE_CLAIM_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:PORT/phone_claim_test \
//      node --test test/phone_claim_postgres.js
// It applies the baseline schema, the contact uniqueness migration and
// 0015_claimed_phone.sql if the users table is missing, and never touches a
// database that is not named phone_claim_test on a loopback address.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');

process.env.NODE_ENV = 'test';
process.env.PHONE_LOOKUP_HMAC_KEY ||= 'test-phone-lookup-hmac-key-0123456789abcdef';

const { phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');
const { claimPhone, releaseClaimedPhone, getPhoneClaimStatus } = require('../src/services/phoneClaim');

const url = process.env.PHONE_CLAIM_TEST_DATABASE_URL;
if (!url) throw new Error('PHONE_CLAIM_TEST_DATABASE_URL is required');
const parsed = new URL(url);
if (!['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname) || parsed.pathname !== '/phone_claim_test') {
  throw new Error('PHONE_CLAIM_TEST_DATABASE_URL must name the loopback phone_claim_test database');
}

const root = path.join(__dirname, '..');
const pool = new Pool({ connectionString: url, max: 12 });

async function newUser(email, changes = {}) {
  const { rows } = await pool.query(
    `INSERT INTO users (email, is_email_verified, deleted, is_active) VALUES ($1, TRUE, $2, $3) RETURNING id`,
    [email, changes.deleted === true, changes.is_active !== false],
  );
  return rows[0].id;
}

test.before(async () => {
  const exists = await pool.query("SELECT to_regclass('public.users') AS t");
  if (!exists.rows[0].t) {
    for (const file of ['db/pandapay-auth/init.sql', 'db/migrations/9001_active_contact_uniqueness.sql', 'db/migrations/0015_claimed_phone.sql']) {
      await pool.query(fs.readFileSync(path.join(root, file), 'utf8'));
    }
  }
  await pool.query('TRUNCATE users CASCADE');
});
test.after(async () => { await pool.end(); });

test('the migration added the fields, the check and the live-only unique index', async () => {
  const columns = await pool.query(
    `SELECT column_name FROM information_schema.columns WHERE table_name = 'users' AND column_name LIKE 'claimed_phone%' ORDER BY 1`);
  assert.deepEqual(columns.rows.map(r => r.column_name), ['claimed_phone_at', 'claimed_phone_enc', 'claimed_phone_hash']);
  const index = await pool.query("SELECT indexdef FROM pg_indexes WHERE indexname = 'uq_users_live_claimed_phone'");
  assert.match(index.rows[0].indexdef, /WHERE .*deleted = false.*claimed_phone_hash IS NOT NULL/);
  const a = await newUser('check-a@example.test');
  await assert.rejects(pool.query("UPDATE users SET claimed_phone_hash = 'not-a-hash' WHERE id = $1", [a]), /chk_users_claimed_phone_complete/);
  await assert.rejects(pool.query(`UPDATE users SET claimed_phone_hash = $2 WHERE id = $1`, [a, 'a'.repeat(64)]), /chk_users_claimed_phone_complete/);
});

test('a number is claimed once, and every way of writing it collides', async () => {
  const a = await newUser('one@example.test');
  const b = await newUser('two@example.test');
  const first = await claimPhone({ pool, userId: a, phone: '98765 43210' });
  assert.equal(first.already, false);
  for (const typed of ['9876543210', '+91-98765-43210', '09876543210']) {
    await assert.rejects(claimPhone({ pool, userId: b, phone: typed }), error => error.code === 'phone_unavailable', typed);
  }
  const row = (await pool.query('SELECT claimed_phone_hash, is_phone_verified, phone_lookup_hash FROM users WHERE id = $1', [a])).rows[0];
  assert.equal(row.claimed_phone_hash, phoneLookupHash('+919876543210'));
  assert.equal(row.is_phone_verified, false);
  assert.equal(row.phone_lookup_hash, null);
});

test('twenty sign-ups racing for one number: exactly one wins', async () => {
  const ids = [];
  for (let i = 0; i < 20; i++) ids.push(await newUser(`race-${i}@example.test`));
  const results = await Promise.allSettled(ids.map(userId => claimPhone({ pool, userId, phone: '9123456780' })));
  const won = results.filter(r => r.status === 'fulfilled');
  const lost = results.filter(r => r.status === 'rejected');
  assert.equal(won.length, 1);
  assert.equal(lost.length, 19);
  for (const r of lost) assert.equal(r.reason.code, 'phone_unavailable');
  const holders = await pool.query('SELECT count(*)::int AS n FROM users WHERE claimed_phone_hash = $1', [phoneLookupHash('+919123456780')]);
  assert.equal(holders.rows[0].n, 1);
});

test('the unique index alone stops a duplicate even if the service is bypassed', async () => {
  const a = await newUser('index-a@example.test');
  const b = await newUser('index-b@example.test');
  const hash = phoneLookupHash('+919000000001');
  const set = (id) => pool.query(
    `UPDATE users SET claimed_phone_enc = 'x', claimed_phone_hash = $2, claimed_phone_at = NOW() WHERE id = $1`, [id, hash]);
  await set(a);
  await assert.rejects(set(b), /uq_users_live_claimed_phone/);
});

test('a number on another account as a verified phone is refused', async () => {
  const holder = await newUser('verified-holder@example.test');
  const hash = phoneLookupHash('+919000000002');
  await pool.query(`UPDATE users SET phone_number = '+919000000002', phone_lookup_hash = $2, is_phone_verified = TRUE WHERE id = $1`, [holder, hash]);
  const other = await newUser('verified-other@example.test');
  await assert.rejects(claimPhone({ pool, userId: other, phone: '9000000002' }), error => error.code === 'phone_unavailable');
});

test('a deleted account frees its number, a disabled one cannot claim', async () => {
  const gone = await newUser('gone@example.test');
  await claimPhone({ pool, userId: gone, phone: '9000000003' });
  await pool.query('UPDATE users SET deleted = TRUE WHERE id = $1', [gone]);
  const heir = await newUser('heir@example.test');
  assert.equal((await claimPhone({ pool, userId: heir, phone: '9000000003' })).already, false);
  const off = await newUser('off@example.test', { is_active: false });
  await assert.rejects(claimPhone({ pool, userId: off, phone: '9000000004' }), error => error.code === 'account_unavailable');
});

test('the number cannot be swapped by the person, and same-number repeats are harmless', async () => {
  const a = await newUser('swap@example.test');
  await claimPhone({ pool, userId: a, phone: '9000000005' });
  assert.equal((await claimPhone({ pool, userId: a, phone: '+91 90000 00005' })).already, true);
  await assert.rejects(claimPhone({ pool, userId: a, phone: '9000000006' }), error => error.code === 'phone_already_set');
});

test('support release frees the number, is audited, and the account needs a phone again', async () => {
  const squatter = await newUser('squatter@example.test');
  const owner = await newUser('owner@example.test');
  await claimPhone({ pool, userId: squatter, phone: '9000000007' });
  await assert.rejects(claimPhone({ pool, userId: owner, phone: '9000000007' }), error => error.code === 'phone_unavailable');
  assert.deepEqual(await releaseClaimedPhone({ pool, userId: squatter, actor: 'Asha (support)', reason: 'Real owner showed the SIM and ID' }), { released: true });
  const audit = await pool.query("SELECT status, meta FROM auth_audit WHERE user_id = $1 AND action = 'phone_claim_released'", [squatter]);
  assert.equal(audit.rows.length, 1);
  assert.deepEqual(audit.rows[0].meta, { actor: 'Asha (support)', reason: 'Real owner showed the SIM and ID' });
  const status = await getPhoneClaimStatus({ query: (...args) => pool.query(...args), userId: squatter, env: { REQUIRE_PHONE_AT_SIGNUP: 'true' } });
  assert.equal(status.needs_phone, true);
  assert.equal((await claimPhone({ pool, userId: owner, phone: '9000000007' })).already, false);
});
