'use strict';

// Coordinator-invoked fixture for a disposable loopback PostgreSQL database.
// Run: ACCOUNT_RECOVERY_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:PORT/account_recovery_test \
//      node --test test/account_recovery_postgres.js
// Applies the baseline schema and migrations 9001 and 0015 to 0018 if users is missing.
// Refuses any database that is not account_recovery_test on loopback.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { Pool } = require('pg');

process.env.NODE_ENV = 'test';
process.env.PHONE_LOOKUP_HMAC_KEY ||= 'test-phone-lookup-hmac-key-0123456789abcdef';

const { phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');
const { canonicalEmail } = require('../src/utils/emailIdentity');
const { createAccountRecovery, RecoveryError, parseFact, signUpMonthIst } = require('../src/services/accountRecovery');
const { RateLimitExceededError } = require('../src/services/authAbuseStore');

const url = process.env.ACCOUNT_RECOVERY_TEST_DATABASE_URL;
if (!url) throw new Error('ACCOUNT_RECOVERY_TEST_DATABASE_URL is required');
const parsed = new URL(url);
if (!['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname) || parsed.pathname !== '/account_recovery_test') {
  throw new Error('ACCOUNT_RECOVERY_TEST_DATABASE_URL must name the loopback account_recovery_test database');
}
const root = path.join(__dirname, '..');
const sql = file => fs.readFileSync(path.join(root, file), 'utf8');
const pool = new Pool({ connectionString: url, max: 8 });

test.before(async () => {
  const exists = await pool.query("SELECT to_regclass('public.users') AS t");
  if (!exists.rows[0].t) {
    for (const file of ['db/pandapay-auth/init.sql', 'db/migrations/9001_active_contact_uniqueness.sql', 'db/migrations/0015_claimed_phone.sql',
      'db/migrations/0016_email_canonical.sql', 'db/migrations/0017_recovery_email.sql', 'db/migrations/0018_account_recovery.sql']) {
      await pool.query(sql(file));
    }
  }
  await pool.query('TRUNCATE users CASCADE');
});
test.after(async () => { await pool.end(); });

let phoneCounter = 0;
const phoneFor = new Map();
const DEVICE = 'device-recover-1';

async function account({ email, recoveryEmail = null, phone = `98${String(++phoneCounter).padStart(8, '0')}`, createdAt = null, cards = null } = {}) {
  const id = randomUUID();
  phoneFor.set(canonicalEmail(email), phone);
  await pool.query(
    `INSERT INTO users (id, email, is_email_verified, claimed_phone_enc, claimed_phone_hash, claimed_phone_at, created_at)
     VALUES ($1, $2, TRUE, 'x', $3, NOW(), COALESCE($4::timestamptz, NOW()))`,
    [id, email, phoneLookupHash(`+91${phone}`), createdAt],
  );
  if (recoveryEmail) {
    await pool.query('UPDATE users SET recovery_email = $2, recovery_email_added_at = NOW() WHERE id = $1', [id, recoveryEmail]);
  }
  return { id, email, cards };
}

function world({ clock = { t: new Date() }, cardsByUser = new Map(), budgetLimits = {} } = {}) {
  const w = { codes: new Map(), mails: [], notices: [], budgets: new Map(), cardsByUser, clock, tokens: [] };
  let n = 0;
  const otp = {
    async createOtpV2(identifier, _t, _p, deviceId) {
      n++; const code = String(200000 + n); const requestId = randomUUID(); w.codes.set(identifier, { code, requestId, deviceId }); return { code, requestId };
    },
    async verifyOtpV2(identifier, code, _t, _p, deviceId, requestId) {
      const c = w.codes.get(identifier);
      return { ok: Boolean(c) && c.code === code && c.requestId === requestId && c.deviceId === deviceId && !c.used && (c.used = true) };
    },
    async discardUndeliveredOtpV2() {},
  };
  const mail = {
    async sendOtpEmail(to, code, o) { w.mails.push({ to, code, purpose: o.purpose }); return { success: !w.mailFails }; },
    async sendSecurityNotice(m) { w.notices.push(m); return { success: true }; },
  };
  const svc = createAccountRecovery({
    query: (...a) => pool.query(...a),
    transaction: async work => {
      const client = await pool.connect();
      try { await client.query('BEGIN'); const r = await work(client); await client.query('COMMIT'); return r; }
      catch (e) { await client.query('ROLLBACK'); throw e; } finally { client.release(); }
    },
    otp, mail,
    cardFact: async ({ userId, last4 }) => {
      if (w.cardFactDown) throw new Error('api down');
      const cards = w.cardsByUser.get(userId) || [];
      return { has_cards: cards.length > 0, matched: last4 ? cards.includes(last4) : false };
    },
    budget: async (name, subject, limit) => {
      const key = `${name}:${subject}`; const count = (w.budgets.get(key) || 0) + 1; w.budgets.set(key, count);
      if (count > (budgetLimits[name] ?? limit)) throw new RateLimitExceededError();
    },
    issueSession: async ({ client, user, deviceId }) => {
      await client.query(
        `INSERT INTO refresh_tokens (user_id, token_id, token_hash, device_id, expires_at) VALUES ($1, $2, 'h', $3, NOW() + INTERVAL '1 day')`,
        [user.id, randomUUID(), deviceId]);
      w.tokens.push(user.id);
      return { access_token: `access-${user.id}`, refresh_token: 'refresh', user: { id: user.id, email: user.email } };
    },
    now: () => w.clock.t, sleep: async () => {}, minStartMs: 0, publicBaseUrl: 'https://auth.test', logger: { warn() {} },
  });
  w.svc = svc;
  return w;
}

const start = (w, { email, phone = phoneFor.get(canonicalEmail(email)) || '9000000000', fact, device = DEVICE }) => w.svc.start({ lostEmail: email, phone, fact, deviceId: device, ip: '203.0.113.7' });
const stateOf = async id => (await pool.query('SELECT * FROM recovery_attempts WHERE id = $1', [id])).rows[0];
const lastMail = (w, purpose) => [...w.mails].reverse().find(m => m.purpose === purpose);
const month = date => { const m = signUpMonthIst(date); return `${m.year}-${String(m.month).padStart(2, '0')}`; };

test('the fact is a card or a month, and four digits alone is always a card', () => {
  assert.deepEqual(parseFact('4821'), { kind: 'card', last4: '4821' });
  assert.deepEqual(parseFact(' 2026-11 '), { kind: 'month', year: 2026, month: 11 });
  assert.deepEqual(parseFact('11/2026'), { kind: 'month', year: 2026, month: 11 });
  assert.deepEqual(parseFact('1-2026'), { kind: 'month', year: 2026, month: 1 });
  for (const bad of ['', 'abc', '2026-13', '2026-00', '13/2026', '1999-05', '12345', null, 5]) assert.equal(parseFact(bad), null, String(bad));
});

test('a start looks the same whether or not the details match', async () => {
  const w = world({ budgetLimits: { 'recovery-start-mailbox': 99 } });
  const real = await account({ email: 'same.look@gmail.com', recoveryEmail: 'rec@outlook.com' });
  w.cardsByUser.set(real.id, ['4821']);
  const shapes = [];
  for (const attempt of [
    { email: 'same.look@gmail.com', fact: '4821' },                      // matches
    { email: 'same.look@gmail.com', fact: '1111' },                      // wrong card
    { email: 'same.look@gmail.com', fact: '4821', phone: '9123456780' }, // wrong phone
    { email: 'nobody.here@gmail.com', fact: '4821' },                    // no such account
    { email: 'same.look@gmail.com', fact: 'garbage' },                   // not a fact at all
  ]) {
    const r = await start(w, attempt);
    shapes.push(Object.keys(r).sort().join() + typeof r.attempt_id + r.expires_in + r.code_length + r.version);
  }
  assert.equal(new Set(shapes).size, 1, 'one reply shape for every start');
  const rows = (await pool.query("SELECT matched, user_id IS NOT NULL AS has_user FROM recovery_attempts WHERE device_hash <> 'x' ORDER BY created_at")).rows;
  assert.equal(rows.filter(r => r.matched).length >= 1, true);
  assert.equal(w.mails.filter(m => m.purpose === 'recovery-code').length, 1, 'only the matching start sends a code, and only to the recovery email');
  assert.equal(lastMail(w, 'recovery-code').to, 'rec@outlook.com');
});

test('strong path end to end: code, new email, immediate access, others signed out, undo freezes', async () => {
  const w = world();
  const a = await account({ email: 'strong.path@gmail.com', recoveryEmail: 'strong.backup@outlook.com' });
  w.cardsByUser.set(a.id, ['4821']);
  await pool.query("INSERT INTO user_devices (user_id, device_identifier, device_platform) VALUES ($1, 'old-phone', 'android'), ($1, $2, 'ios')", [a.id, DEVICE]);
  await pool.query("INSERT INTO refresh_tokens (user_id, token_id, token_hash, device_id, expires_at) VALUES ($1, $2, 'h', 'old-phone', NOW() + INTERVAL '1 day')", [a.id, randomUUID()]);
  const versionBefore = (await pool.query('SELECT token_version FROM users WHERE id = $1', [a.id])).rows[0].token_version;

  const s = await start(w, { email: 'Strong.Path@gmail.com', fact: '4821' });
  assert.ok(w.notices.some(n => n.to === 'strong.path@gmail.com' && /started recovering/.test(n.subject)), 'the owner is told it began');
  const code = lastMail(w, 'recovery-code').code;
  await assert.rejects(w.svc.verifyCode({ attemptId: s.attempt_id, code: '000000', deviceId: DEVICE }), e => e.code === 'recovery_failed');
  await assert.rejects(w.svc.verifyCode({ attemptId: s.attempt_id, code, deviceId: 'some-other-device' }), e => e.code === 'recovery_failed', 'another device cannot use the attempt');
  assert.deepEqual(await w.svc.verifyCode({ attemptId: s.attempt_id, code, deviceId: DEVICE }), { ok: true, next: 'new_email', can_use_recovery_email: true });

  await assert.rejects(w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: 'x@mailinator.com' }), e => e.code === 'email_not_allowed');
  await assert.rejects(w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: 'Str.ong.Path+1@gmail.com' }), e => e.code === 'same_as_old_email');
  const set = await w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: 'brand.new@yahoo.com' });
  assert.equal(set.needs_code, true);
  const newCode = lastMail(w, 'recovery-new-email');
  assert.equal(newCode.to, 'brand.new@yahoo.com');
  await assert.rejects(w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE, newEmailCode: '000000' }), e => e.code === 'code_invalid');
  const done = await w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE, newEmailCode: newCode.code });
  assert.equal(done.pending, false);
  assert.equal(done.access_token, `access-${a.id}`);
  assert.equal(done.new_email_hint, 'b•••@yahoo.com');

  const u = (await pool.query('SELECT email, email_canonical, is_email_verified, token_version, recovery_email FROM users WHERE id = $1', [a.id])).rows[0];
  assert.equal(u.email, 'brand.new@yahoo.com');
  assert.equal(u.recovery_email, 'strong.backup@outlook.com', 'the recovery email stays');
  assert.equal(u.token_version, versionBefore + 1, 'every older access token is dead');
  const tokens = (await pool.query('SELECT device_id, revoked_at IS NULL AS live FROM refresh_tokens WHERE user_id = $1', [a.id])).rows;
  assert.deepEqual(tokens.filter(t => t.live).map(t => t.device_id), [DEVICE], 'only this device holds a live refresh token');
  const devices = (await pool.query('SELECT device_identifier, is_active FROM user_devices WHERE user_id = $1 ORDER BY 1', [a.id])).rows;
  assert.deepEqual(devices, [{ device_identifier: 'old-phone', is_active: false }, { device_identifier: DEVICE, is_active: true }].sort((x, y) => x.device_identifier.localeCompare(y.device_identifier)));
  const sent = w.notices.filter(n => /changed/.test(n.subject));
  assert.deepEqual(sent.map(n => n.to).sort(), ['strong.backup@outlook.com', 'strong.path@gmail.com']);
  const link = sent[0].text.match(/token=([A-Za-z0-9_-]+)/);
  assert.ok(link, 'the notice carries a stop link');

  // The link freezes the account within 24 hours, once.
  assert.deepEqual(await w.svc.stopByToken({ token: link[1] }), { outcome: 'frozen' });
  assert.equal((await pool.query('SELECT is_active FROM users WHERE id = $1', [a.id])).rows[0].is_active, false);
  assert.equal((await stateOf(s.attempt_id)).state, 'undone');
  assert.deepEqual(await w.svc.stopByToken({ token: link[1] }), { outcome: 'expired' });
  assert.deepEqual(await w.svc.stopByToken({ token: 'not-a-real-token-at-all-xxxxxxxx' }), { outcome: 'unknown' });
});

test('strong path can use the recovery email as the new sign-in email', async () => {
  const w = world();
  const a = await account({ email: 'swap.me@gmail.com', recoveryEmail: 'swap.backup@outlook.com' });
  w.cardsByUser.set(a.id, ['1234']);
  const s = await start(w, { email: 'swap.me@gmail.com', fact: '1234' });
  await w.svc.verifyCode({ attemptId: s.attempt_id, code: lastMail(w, 'recovery-code').code, deviceId: DEVICE });
  const set = await w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, useRecoveryEmail: true });
  assert.equal(set.needs_code, false);
  const done = await w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE });
  assert.equal(done.pending, false);
  const u = (await pool.query('SELECT email, recovery_email, recovery_email_added_at FROM users WHERE id = $1', [a.id])).rows[0];
  assert.deepEqual([u.email, u.recovery_email, u.recovery_email_added_at], ['swap.backup@outlook.com', null, null]);
});

test('weak path: no code, a 24-hour hold, cancel from a signed-in device, and finishing after the hold', async () => {
  const clock = { t: new Date('2026-11-09T10:00:00Z') };
  const w = world({ clock });
  const a = await account({ email: 'weak.path@gmail.com', createdAt: '2026-10-15T05:00:00Z' });
  const fact = month('2026-10-15T05:00:00Z');
  const s = await start(w, { email: 'weak.path@gmail.com', fact });
  assert.equal(w.mails.filter(m => m.purpose === 'recovery-code').length, 0, 'no recovery email, so no code');
  await assert.rejects(w.svc.verifyCode({ attemptId: s.attempt_id, code: '123456', deviceId: DEVICE }), e => e.code === 'recovery_failed');
  assert.deepEqual(await w.svc.noRecoveryEmail({ attemptId: s.attempt_id, deviceId: DEVICE }), { ok: true, next: 'new_email', hold_hours: 24, can_use_recovery_email: false });
  await w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: 'weak.new@yahoo.com' });
  const held = await w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE, newEmailCode: lastMail(w, 'recovery-new-email').code });
  assert.equal(held.pending, true);
  assert.equal(held.access_token, undefined, 'nothing is granted yet');
  assert.equal(held.hold_until, '2026-11-10T10:00:00.000Z');
  assert.equal((await pool.query('SELECT email FROM users WHERE id = $1', [a.id])).rows[0].email, 'weak.path@gmail.com', 'the email has not changed');
  assert.ok(w.notices.some(n => n.to === 'weak.path@gmail.com' && /24 hours/.test(n.subject) && /stop\?token=/.test(n.text)));
  assert.deepEqual(await w.svc.pendingForUser(a.id), { pending: true, hold_until: '2026-11-10T10:00:00.000Z' });

  await assert.rejects(w.svc.finish({ attemptId: s.attempt_id, deviceId: DEVICE, resumeToken: held.resume_token }), e => e.code === 'hold_not_over');
  clock.t = new Date('2026-11-10T10:00:01Z');
  await assert.rejects(w.svc.finish({ attemptId: s.attempt_id, deviceId: DEVICE, resumeToken: 'wrong-token-value-xxxxxxxxxxxxxxxx' }), e => e.code === 'recovery_failed');
  const done = await w.svc.finish({ attemptId: s.attempt_id, deviceId: DEVICE, resumeToken: held.resume_token });
  assert.equal(done.pending, false);
  assert.equal((await pool.query('SELECT email FROM users WHERE id = $1', [a.id])).rows[0].email, 'weak.new@yahoo.com');
  assert.deepEqual(await w.svc.pendingForUser(a.id), { pending: false, hold_until: null });
});

test('a waiting recovery can be cancelled from a signed-in device or the email link, and then cannot finish', async () => {
  for (const how of ['device', 'link']) {
    const clock = { t: new Date('2026-11-09T10:00:00Z') };
    const w = world({ clock });
    const a = await account({ email: `cancel.${how}@gmail.com`, createdAt: '2026-10-15T05:00:00Z' });
    const s = await start(w, { email: `cancel.${how}@gmail.com`, fact: month('2026-10-15T05:00:00Z') });
    await w.svc.noRecoveryEmail({ attemptId: s.attempt_id, deviceId: DEVICE });
    await w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: `thief.${how}@yahoo.com` });
    const held = await w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE, newEmailCode: lastMail(w, 'recovery-new-email').code });
    if (how === 'device') assert.deepEqual(await w.svc.cancelForUser(a.id), { ok: true, cancelled: 1 });
    else assert.deepEqual(await w.svc.stopByToken({ token: w.notices.find(n => /stop\?token=/.test(n.text)).text.match(/token=([A-Za-z0-9_-]+)/)[1] }), { outcome: 'cancelled' });
    clock.t = new Date('2026-11-11T10:00:00Z');
    await assert.rejects(w.svc.finish({ attemptId: s.attempt_id, deviceId: DEVICE, resumeToken: held.resume_token }), e => e.code === 'recovery_failed', how);
    assert.equal((await pool.query('SELECT email, is_active FROM users WHERE id = $1', [a.id])).rows[0].email, `cancel.${how}@gmail.com`);
    await assert.rejects(w.svc.cancelForUser(a.id), e => e instanceof RecoveryError && e.code === 'nothing_pending');
  }
});

test('the fact rule: with cards it must be a card, without cards it must be the sign-up month', async () => {
  const w = world({ budgetLimits: { 'recovery-start-mailbox': 99, 'recovery-start-ip': 999, 'recovery-start-device': 999 } });
  const withCard = await account({ email: 'has.cards@gmail.com', createdAt: '2026-10-20T05:00:00Z' });
  w.cardsByUser.set(withCard.id, ['9999', '4821']);
  const noCard = await account({ email: 'no.cards@gmail.com', createdAt: '2026-10-20T05:00:00Z' });
  const attempt = async (email, fact) => (await pool.query('SELECT matched FROM recovery_attempts WHERE id = $1', [(await start(w, { email, fact })).attempt_id])).rows[0].matched;
  assert.equal(await attempt('has.cards@gmail.com', '4821'), true);
  assert.equal(await attempt('has.cards@gmail.com', '9999'), true, 'any of their cards');
  assert.equal(await attempt('has.cards@gmail.com', '0000'), false);
  assert.equal(await attempt('has.cards@gmail.com', '2026-10'), false, 'a month is not enough when there are cards');
  assert.equal(await attempt('no.cards@gmail.com', '2026-10'), true);
  assert.equal(await attempt('no.cards@gmail.com', '10/2026'), true);
  assert.equal(await attempt('no.cards@gmail.com', '2026-09'), false);
  assert.equal(await attempt('no.cards@gmail.com', '4821'), false, 'a card is not an answer when there are no cards');
  w.cardFactDown = true;
  assert.equal(await attempt('has.cards@gmail.com', '4821'), false, 'if the cards cannot be checked it fails closed');
  assert.ok(noCard && withCard);
});

test('the sign-up month is read in India time', async () => {
  // 20:00 UTC on 31 October is 01:30 IST on 1 November.
  assert.deepEqual(signUpMonthIst('2026-10-31T20:00:00Z'), { year: 2026, month: 11 });
  assert.deepEqual(signUpMonthIst('2026-10-31T17:00:00Z'), { year: 2026, month: 10 });
});

test('the phone must be the saved one, however it is typed', async () => {
  const w = world({ budgetLimits: { 'recovery-start-mailbox': 99, 'recovery-start-ip': 999, 'recovery-start-device': 999 } });
  await account({ email: 'phone.check@gmail.com', phone: '9876501234', createdAt: '2026-10-20T05:00:00Z' });
  const matched = async phone => (await pool.query('SELECT matched FROM recovery_attempts WHERE id = $1',
    [(await start(w, { email: 'phone.check@gmail.com', phone, fact: '2026-10' })).attempt_id])).rows[0].matched;
  for (const typed of ['9876501234', '98765 01234', '+91-98765-01234', '09876501234']) assert.equal(await matched(typed), true, typed);
  for (const typed of ['9876501235', '', 'abc', '+44 7911 123456']) assert.equal(await matched(typed), false, typed);
});

test('three starts a day per mailbox, counted for every start', async () => {
  const w = world();
  const results = [];
  for (let i = 0; i < 4; i++) {
    try { await start(w, { email: 'count.me@gmail.com', fact: '4821', device: `dev-count-${i}` }); results.push('ok'); }
    catch (e) { results.push(e instanceof RateLimitExceededError ? 'limited' : 'other'); }
  }
  assert.deepEqual(results, ['ok', 'ok', 'ok', 'limited'], 'the same mailbox, matched or not, runs out the same way');
  // Aliases of one mailbox share the budget.
  const w2 = world();
  const out = [];
  for (const typed of ['a.l.i.a.s@gmail.com', 'alias+1@gmail.com', 'ALIAS@googlemail.com', 'alias+2@gmail.com']) {
    try { await start(w2, { email: typed, fact: '4821', device: `dev-${out.length}-alias` }); out.push('ok'); } catch (_) { out.push('limited'); }
  }
  assert.deepEqual(out, ['ok', 'ok', 'ok', 'limited']);
});

test('five wrong codes close the attempt, even for the right code afterwards', async () => {
  const w = world();
  const a = await account({ email: 'five.wrong@gmail.com', recoveryEmail: 'five.rec@outlook.com' });
  w.cardsByUser.set(a.id, ['4821']);
  const s = await start(w, { email: 'five.wrong@gmail.com', fact: '4821' });
  const code = lastMail(w, 'recovery-code').code;
  for (let i = 0; i < 5; i++) await assert.rejects(w.svc.verifyCode({ attemptId: s.attempt_id, code: '000000', deviceId: DEVICE }), e => e.code === 'recovery_failed');
  assert.equal((await stateOf(s.attempt_id)).state, 'failed');
  await assert.rejects(w.svc.verifyCode({ attemptId: s.attempt_id, code, deviceId: DEVICE }), e => e.code === 'recovery_failed');
});

test('a new email taken by someone else in between is refused at the end and closes the attempt', async () => {
  const w = world();
  const a = await account({ email: 'race.old@gmail.com', recoveryEmail: 'race.rec@outlook.com' });
  w.cardsByUser.set(a.id, ['4821']);
  const s = await start(w, { email: 'race.old@gmail.com', fact: '4821' });
  await w.svc.verifyCode({ attemptId: s.attempt_id, code: lastMail(w, 'recovery-code').code, deviceId: DEVICE });
  await w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: 'race.new@yahoo.com' });
  await account({ email: 'Race.New@yahoo.com' });
  await assert.rejects(w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE, newEmailCode: lastMail(w, 'recovery-new-email').code }), e => e.code === 'email_unavailable');
  assert.equal((await stateOf(s.attempt_id)).state, 'failed');
  assert.equal((await pool.query('SELECT email FROM users WHERE id = $1', [a.id])).rows[0].email, 'race.old@gmail.com');
});

test('a failed code delivery to the recovery email still gives the same reply and never grants anything', async () => {
  const w = world();
  w.mailFails = true;
  const a = await account({ email: 'nomail.old@gmail.com', recoveryEmail: 'nomail.rec@outlook.com' });
  w.cardsByUser.set(a.id, ['4821']);
  const r = await start(w, { email: 'nomail.old@gmail.com', fact: '4821' });
  assert.equal(r.ok, true);
  assert.equal((await stateOf(r.attempt_id)).state, 'failed');
});

// ------------------------------------------------------------------ support CLI

const support = require('../scripts/recovery_support');
const runSupport = async (...argv) => {
  const out = [];
  await support.run({ pool, argv, write: v => out.push(v) });
  return { text: out.join('\n'), json: JSON.parse(out.join('\n')) };
};
const WHO = ['--actor', 'asha@pandapay', '--reason', 'Verified the owner on a video call'];
const auditFor = async (userId, action) => (await pool.query('SELECT meta FROM auth_audit WHERE user_id = $1 AND action = $2', [userId, action])).rows;

async function frozenAccount(tag) {
  const w = world();
  const a = await account({ email: `${tag}.old@gmail.com`, recoveryEmail: `${tag}.rec@outlook.com` });
  w.cardsByUser.set(a.id, ['4821']);
  const s = await start(w, { email: `${tag}.old@gmail.com`, fact: '4821' });
  await w.svc.verifyCode({ attemptId: s.attempt_id, code: lastMail(w, 'recovery-code').code, deviceId: DEVICE });
  await w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: `${tag}.new@yahoo.com`, useRecoveryEmail: false });
  await w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE, newEmailCode: lastMail(w, 'recovery-new-email').code });
  const token = w.notices.find(n => /stop\?token=/.test(n.text)).text.match(/token=([A-Za-z0-9_-]+)/)[1];
  assert.deepEqual(await w.svc.stopByToken({ token }), { outcome: 'frozen' });
  return { a, attemptId: s.attempt_id };
}

test('support: list and show print masked emails and never a token, hash or code', async () => {
  const clock = { t: new Date('2026-11-09T10:00:00Z') };
  const w = world({ clock });
  const a = await account({ email: 'sup.list@gmail.com', createdAt: '2026-10-15T05:00:00Z' });
  const s = await start(w, { email: 'sup.list@gmail.com', fact: month('2026-10-15T05:00:00Z') });
  await w.svc.noRecoveryEmail({ attemptId: s.attempt_id, deviceId: DEVICE });
  await w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: 'sup.thief@yahoo.com' });
  await w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE, newEmailCode: lastMail(w, 'recovery-new-email').code });

  const list = await runSupport('list', '--state', 'pending_hold');
  const mine = list.json.find(r => r.attempt_id === s.attempt_id);
  assert.equal(mine.account, 's•••@gmail.com');
  assert.equal(mine.new_email, 's•••@yahoo.com');
  assert.equal(mine.state, 'pending_hold');
  assert.doesNotMatch(list.text, /sup\.list|sup\.thief|hash|token|device/i);

  const byEmail = await runSupport('show', '--email', 'Sup.List@gmail.com');
  assert.equal(byEmail.json.user_id, a.id);
  assert.equal(byEmail.json.has_recovery_email, false);
  assert.equal(byEmail.json.attempts[0].attempt_id, s.attempt_id);
  assert.doesNotMatch(byEmail.text, /sup\.list@|hash|token/i);
  assert.deepEqual((await runSupport('show', '--email', 'nobody@gmail.com')).json, { found: false });
  await assert.rejects(runSupport('list', '--state', 'bogus'), /--state must be one of/);
  await assert.rejects(runSupport('list', '--limit', '0'), /--limit/);
  await assert.rejects(runSupport('show'), /needs --user-id or --email/);
});

test('support: cancel stops a waiting recovery, needs an actor and a reason, and is audited', async () => {
  const clock = { t: new Date('2026-11-09T10:00:00Z') };
  const w = world({ clock });
  const a = await account({ email: 'sup.cancel@gmail.com', createdAt: '2026-10-15T05:00:00Z' });
  const s = await start(w, { email: 'sup.cancel@gmail.com', fact: month('2026-10-15T05:00:00Z') });
  await w.svc.noRecoveryEmail({ attemptId: s.attempt_id, deviceId: DEVICE });
  await w.svc.setNewEmail({ attemptId: s.attempt_id, deviceId: DEVICE, newEmail: 'sup.cancel.thief@yahoo.com' });
  const held = await w.svc.complete({ attemptId: s.attempt_id, deviceId: DEVICE, newEmailCode: lastMail(w, 'recovery-new-email').code });

  await assert.rejects(runSupport('cancel', '--attempt-id', s.attempt_id), /--actor/);
  await assert.rejects(runSupport('cancel', '--attempt-id', s.attempt_id, '--actor', 'a', '--reason', 'long enough reason'), /--actor/);
  await assert.rejects(runSupport('cancel', '--attempt-id', s.attempt_id, '--actor', 'asha', '--reason', 'short'), /--reason/);
  await assert.rejects(runSupport('cancel', '--attempt-id', 'not-a-uuid', ...WHO), /UUID/);
  assert.equal((await stateOf(s.attempt_id)).state, 'pending_hold', 'refused calls changed nothing');

  assert.deepEqual((await runSupport('cancel', '--attempt-id', s.attempt_id, ...WHO)).json, { cancelled: true });
  assert.equal((await stateOf(s.attempt_id)).state, 'cancelled');
  assert.deepEqual((await runSupport('cancel', '--attempt-id', s.attempt_id, ...WHO)).json, { cancelled: false });
  const rows = await auditFor(a.id, 'recovery_cancelled_by_support');
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].meta, { actor: 'asha@pandapay', reason: 'Verified the owner on a video call', attempt_id: s.attempt_id });
  clock.t = new Date('2026-11-11T10:00:00Z');
  await assert.rejects(w.svc.finish({ attemptId: s.attempt_id, deviceId: DEVICE, resumeToken: held.resume_token }), e => e.code === 'recovery_failed');
});

test('support: restore lifts only a recovery freeze, bumps the token version, and is audited', async () => {
  const { a } = await frozenAccount('sup.restore');
  const before = (await pool.query('SELECT token_version, is_active FROM users WHERE id = $1', [a.id])).rows[0];
  assert.equal(before.is_active, false);

  assert.deepEqual((await runSupport('restore', '--user-id', a.id, ...WHO)).json, { restored: true });
  const after = (await pool.query('SELECT token_version, is_active FROM users WHERE id = $1', [a.id])).rows[0];
  assert.equal(after.is_active, true);
  assert.equal(after.token_version, before.token_version + 1);
  assert.equal((await auditFor(a.id, 'recovery_freeze_lifted')).length, 1);
  assert.deepEqual((await runSupport('restore', '--user-id', a.id, ...WHO)).json, { restored: false, reason: 'not_frozen' });
  assert.equal((await auditFor(a.id, 'recovery_freeze_lifted')).length, 1, 'a refused restore leaves no audit row');
});

test('support: restore refuses an account that was never frozen by a recovery', async () => {
  const closed = await account({ email: 'sup.closed@gmail.com' });
  await pool.query('UPDATE users SET is_active = FALSE WHERE id = $1', [closed.id]);
  assert.deepEqual((await runSupport('restore', '--user-id', closed.id, ...WHO)).json, { restored: false, reason: 'no_recovery_freeze' });
  assert.equal((await pool.query('SELECT is_active FROM users WHERE id = $1', [closed.id])).rows[0].is_active, false, 'it stays closed');
  const open = await account({ email: 'sup.open@gmail.com' });
  assert.deepEqual((await runSupport('restore', '--user-id', open.id, ...WHO)).json, { restored: false, reason: 'no_recovery_freeze' });
});

test('support: release-phone frees the number through the audited release', async () => {
  const a = await account({ email: 'sup.phone@gmail.com' });
  assert.deepEqual((await runSupport('release-phone', '--user-id', a.id, ...WHO)).json, { released: true });
  assert.equal((await pool.query('SELECT claimed_phone_hash FROM users WHERE id = $1', [a.id])).rows[0].claimed_phone_hash, null);
  assert.equal((await auditFor(a.id, 'phone_claim_released')).length, 1);
  assert.deepEqual((await runSupport('release-phone', '--user-id', a.id, ...WHO)).json, { released: false });
  await assert.rejects(runSupport('release-phone', '--user-id', a.id, '--actor', 'asha'), /--reason/);
});

test('support: option parsing rejects stray words and unknown commands', async () => {
  assert.throws(() => support.parseArgs(['list', 'state']), /Bad option/);
  assert.throws(() => support.parseArgs(['list', '--state']), /Bad option/);
  assert.throws(() => support.parseArgs(['list', '--state', '--limit']), /Bad option/);
  await assert.rejects(runSupport('wipe'), /Usage/);
});
