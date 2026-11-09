'use strict';

// Coordinator-invoked fixture for a disposable loopback PostgreSQL database.
// Run: RECOVERY_EMAIL_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:PORT/recovery_email_test \
//      node --test test/recovery_email_postgres.js
// Applies the baseline schema and migrations 9001, 0015, 0016 and 0017 if users is
// missing. Refuses any database that is not recovery_email_test on loopback.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const jwt = require('jsonwebtoken');
const { Pool } = require('pg');

process.env.NODE_ENV = 'test';

const svc = require('../src/services/recoveryEmail');
const { sendDueReminderEmails } = require('../src/services/recoveryReminders');

const url = process.env.RECOVERY_EMAIL_TEST_DATABASE_URL;
if (!url) throw new Error('RECOVERY_EMAIL_TEST_DATABASE_URL is required');
const parsed = new URL(url);
if (!['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname) || parsed.pathname !== '/recovery_email_test') {
  throw new Error('RECOVERY_EMAIL_TEST_DATABASE_URL must name the loopback recovery_email_test database');
}
const root = path.join(__dirname, '..');
const sql = file => fs.readFileSync(path.join(root, file), 'utf8');
const pool = new Pool({ connectionString: url, max: 6 });
const query = (...a) => pool.query(...a);

test.before(async () => {
  const exists = await pool.query("SELECT to_regclass('public.users') AS t");
  if (!exists.rows[0].t) {
    for (const file of ['db/pandapay-auth/init.sql', 'db/migrations/9001_active_contact_uniqueness.sql',
      'db/migrations/0015_claimed_phone.sql', 'db/migrations/0016_email_canonical.sql', 'db/migrations/0017_recovery_email.sql']) {
      await pool.query(sql(file));
    }
  }
  await pool.query('TRUNCATE users CASCADE');
});
test.after(async () => { await pool.end(); });

async function user(email, { daysOld = 0, ...columns } = {}) {
  const { rows } = await pool.query(
    `INSERT INTO users (email, is_email_verified, created_at, deleted, is_active)
     VALUES ($1, $2, NOW() - ($3::integer * INTERVAL '1 day'), $4, $5) RETURNING id`,
    [email, columns.verified !== false, daysOld, columns.deleted === true, columns.active !== false],
  );
  return rows[0].id;
}

test('the migration adds the fields and the trigger keeps the mailbox form', async () => {
  const id = await user('owner.one@gmail.com');
  await pool.query("UPDATE users SET recovery_email = 'Back.Up+x@Gmail.com', recovery_email_added_at = NOW() WHERE id = $1", [id]);
  const row = (await pool.query('SELECT recovery_email_canonical FROM users WHERE id = $1', [id])).rows[0];
  assert.equal(row.recovery_email_canonical, 'backup@gmail.com');
  await pool.query('UPDATE users SET recovery_email = NULL, recovery_email_added_at = NULL WHERE id = $1', [id]);
  assert.equal((await pool.query('SELECT recovery_email_canonical FROM users WHERE id = $1', [id])).rows[0].recovery_email_canonical, null);
});

test('the database refuses a half-set recovery email and one that is the sign-in mailbox', async () => {
  const id = await user('same.box@gmail.com');
  await assert.rejects(pool.query("UPDATE users SET recovery_email = 'x@outlook.com' WHERE id = $1", [id]), /chk_users_recovery_email_complete/);
  await assert.rejects(pool.query("UPDATE users SET recovery_email = 'samebox+tag@googlemail.com', recovery_email_added_at = NOW() WHERE id = $1", [id]),
    /chk_users_recovery_email_differs/);
});

test('the real service saves a recovery email through the real database, end to end', async () => {
  const id = await user('real.flow@gmail.com');
  await user('someone.else@yahoo.com');
  const SECRET = 'real-flow-secret-0123456789abcdef';
  const jwtApi = { sign: (c, ttl) => jwt.sign(c, SECRET, { expiresIn: ttl }), verify: t => jwt.verify(t, SECRET) };
  const codes = new Map(); const mails = []; const notices = [];
  const otp = {
    async createOtpV2(identifier, _t, _p, deviceId) { const code = String(111111 + codes.size); const requestId = `00000000-0000-4000-8000-00000000000${codes.size + 1}`; codes.set(identifier, { code, requestId, deviceId }); return { code, requestId }; },
    async discardUndeliveredOtpV2() {},
    async verifyOtpV2(identifier, code, _t, _p, deviceId, requestId) { const c = codes.get(identifier); return { ok: Boolean(c) && c.code === code && c.requestId === requestId && c.deviceId === deviceId }; },
  };
  const mail = { async sendOtpEmail(to, code, o) { mails.push({ to, code, purpose: o.purpose }); return { success: true }; }, async sendSecurityNotice(n) { notices.push(n); return { success: true }; } };
  const base = { query, userId: id, deviceId: 'device-real', otp, mail, jwtApi };

  await assert.rejects(svc.startChange({ ...base, ttlSeconds: 60, email: 'someone.else@yahoo.com' }), e => e.code === 'email_unavailable');
  await assert.rejects(svc.startChange({ ...base, ttlSeconds: 60, email: 'RE.AL.flow+x@googlemail.com' }), e => e.code === 'same_as_sign_in');
  const started = await svc.startChange({ ...base, ttlSeconds: 60, email: 'recovery.box@outlook.com' });
  const toSignIn = mails.find(m => m.purpose === 'recovery-email-signin'); const toNew = mails.find(m => m.purpose === 'recovery-email-new');
  assert.deepEqual([toSignIn.to, toNew.to], ['real.flow@gmail.com', 'recovery.box@outlook.com']);
  await svc.finishChange({ ...base, challenge: started.challenge, signInCode: toSignIn.code, newCode: toNew.code });
  const row = (await pool.query('SELECT recovery_email, recovery_email_canonical, recovery_email_added_at FROM users WHERE id = $1', [id])).rows[0];
  assert.equal(row.recovery_email, 'recovery.box@outlook.com');
  assert.equal(row.recovery_email_canonical, 'recovery.box@outlook.com');
  assert.ok(row.recovery_email_added_at);
  assert.equal(notices.length, 1);
  assert.deepEqual(await svc.getStatus({ query, userId: id }), { has_recovery_email: true, recovery_email_hint: 'r•••@outlook.com', added_at: row.recovery_email_added_at });
  // The recovery email did not become a way to find or sign in to the account.
  const bySignIn = await pool.query("SELECT 1 FROM users WHERE email_canonical = 'recovery.box@outlook.com'");
  assert.equal(bySignIn.rows.length, 0);
  assert.deepEqual(await svc.removeRecoveryEmail({ query, userId: id, mail }), { removed: true });
  assert.equal((await svc.getStatus({ query, userId: id })).has_recovery_email, false);
});

test('reminder emails go only to accounts that are due, once, in bounded batches', async () => {
  await pool.query('TRUNCATE users CASCADE');
  await user('due1@x.test', { daysOld: 8 });
  await user('due2@x.test', { daysOld: 9 });
  await user('due3@x.test', { daysOld: 30 });
  await user('too.new@x.test', { daysOld: 3 });
  const has = await user('has.recovery@x.test', { daysOld: 20 });
  await pool.query("UPDATE users SET recovery_email = 'r@y.test', recovery_email_added_at = NOW() WHERE id = $1", [has]);
  await user('deleted@x.test', { daysOld: 20, deleted: true });
  await user('inactive@x.test', { daysOld: 20, active: false });
  await user('unverified@x.test', { daysOld: 20, verified: false });
  const sent = [];
  const sendNotice = async n => { sent.push(n.to); return { success: true }; };

  const first = await sendDueReminderEmails({ pool, sendNotice, batch: 2 });
  assert.deepEqual([first.claimed, first.sent], [2, 2]);
  assert.deepEqual([...sent].sort(), ['due2@x.test', 'due3@x.test'], 'the oldest accounts are reminded first');
  const second = await sendDueReminderEmails({ pool, sendNotice, batch: 25 });
  assert.equal(second.claimed, 1);
  const third = await sendDueReminderEmails({ pool, sendNotice });
  assert.equal(third.claimed, 0, 'each account is reminded exactly once');
  assert.deepEqual([...sent].sort(), ['due1@x.test', 'due2@x.test', 'due3@x.test']);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM users WHERE recovery_reminder_email_sent_at IS NOT NULL')).rows[0].n, 3);
});

test('two instances running at once never email the same account twice', async () => {
  await pool.query('TRUNCATE users CASCADE');
  for (let i = 0; i < 12; i++) await user(`race${i}@x.test`, { daysOld: 10 });
  const sent = [];
  const sendNotice = async n => { await new Promise(r => setTimeout(r, 5)); sent.push(n.to); return { success: true }; };
  const outcomes = await Promise.all([1, 2, 3].map(() => sendDueReminderEmails({ pool, sendNotice, batch: 25 })));
  assert.equal(sent.length, new Set(sent).size, 'no address appears twice');
  assert.equal(sent.length, 12);
  assert.ok(outcomes.some(o => o.skipped === 'another_instance_running') || outcomes.filter(o => o.claimed > 0).length === 1);
});
