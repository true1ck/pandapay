const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');

process.env.NODE_ENV = 'test';
process.env.PHONE_LOOKUP_HMAC_KEY ||= 'test-phone-lookup-hmac-key-0123456789abcdef';

const { phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');
const svc = require('../src/services/phoneChange');
const { PhoneChangeError } = svc;

const SECRET = 'phone-change-test-secret-0123456789';
const jwtApi = { sign: (claims, ttl) => jwt.sign(claims, SECRET, { expiresIn: ttl }), verify: token => jwt.verify(token, SECRET) };

// In-memory users table that answers the queries phoneChange and phoneClaim make.
function world(users = {}) {
  const db = new Map(Object.entries({
    me: { id: 'me', email: 'me@gmail.com', is_email_verified: true, claimed_phone_hash: null, claimed_phone_enc: null,
      phone_lookup_hash: null, phone_number: null, is_phone_verified: false },
    ...users,
  }));
  for (const u of db.values()) { u.deleted ??= false; u.is_active ??= true; }
  const state = { codes: [], mail: [], notices: [], discarded: 0 };
  let counter = 0;
  const live = u => u && !u.deleted && u.is_active;
  const run = async (sql, args = []) => {
    if (sql === 'BEGIN' || sql === 'COMMIT' || sql === 'ROLLBACK' || sql.startsWith('SET LOCAL') || sql.includes('pg_advisory_xact_lock')) return { rows: [] };
    if (sql.includes('FROM users WHERE id = $1 AND deleted = FALSE AND is_active = TRUE')) {
      const u = db.get(args[0]); return { rows: live(u) ? [{ ...u }] : [] };
    }
    if (sql.includes('WHERE id <> $1')) {
      const hit = [...db.values()].find(u => u.id !== args[0] && !u.deleted && (u.claimed_phone_hash === args[1] || u.phone_lookup_hash === args[1]));
      return { rows: hit ? [{ x: 1 }] : [] };
    }
    if (sql.includes('SET claimed_phone_enc = $2')) {
      Object.assign(db.get(args[0]), { claimed_phone_enc: args[1], claimed_phone_hash: args[2] }); return { rows: [] };
    }
    throw new Error(`Unexpected SQL: ${sql.slice(0, 80)}`);
  };
  const pool = { async connect() { return { query: run, release() {} }; } };
  const otp = {
    async createOtpV2(identifier, type, purpose, deviceId) {
      counter++; const code = String(100000 + counter); const requestId = `req-${counter}`;
      state.codes.push({ identifier, code, requestId, purpose, deviceId }); return { code, requestId };
    },
    async discardUndeliveredOtpV2() { state.discarded++; },
    async verifyOtpV2(identifier, code, type, purpose, deviceId, requestId) {
      const row = state.codes.find(c => c.identifier === identifier);
      return { ok: Boolean(row) && row.code === code && row.requestId === requestId && row.deviceId === deviceId && !row.used && (row.used = true) };
    },
  };
  const mail = {
    async sendOtpEmail(to, code, options) { state.mail.push({ to, code, purpose: options.purpose }); return state.mailResult ? state.mailResult() : { success: true }; },
    async sendSecurityNotice(n) { state.notices.push(n); return { success: true }; },
  };
  return { db, state, query: run, pool, otp, mail };
}

const base = (w, extra = {}) => ({ query: w.query, pool: w.pool, userId: 'me', deviceId: 'device-1', otp: w.otp, mail: w.mail, jwtApi, ttlSeconds: 60, ...extra });
const start = (w, phone = '98765 43210', extra) => svc.startChange({ ...base(w, extra), phone });

test('step one emails one code to the sign-in email and returns a signed challenge without the code', async () => {
  const w = world();
  const r = await start(w);
  assert.equal(w.state.mail.length, 1);
  assert.equal(w.state.mail[0].to, 'me@gmail.com');
  assert.equal(w.state.mail[0].purpose, 'phone-change');
  assert.equal(r.phone_hint, '+91 •••• 3210');
  assert.equal(r.expires_in, 60);
  const claims = jwt.verify(r.challenge, SECRET);
  assert.equal(claims.sub, 'me');
  assert.equal(claims.value, '+919876543210');
  assert.doesNotMatch(JSON.stringify(claims), /10000\d/);
  assert.equal(w.state.codes[0].purpose, 'replacement');
});

test('adding a first number: the right code saves it, never marks it verified, and notifies the email', async () => {
  const w = world();
  const r = await start(w);
  const out = await svc.finishChange({ ...base(w), challenge: r.challenge, code: w.state.mail[0].code });
  assert.equal(out.phone_hint, '+91 •••• 3210');
  assert.equal(out.had_phone, false);
  const row = w.db.get('me');
  assert.equal(row.claimed_phone_hash, phoneLookupHash('+919876543210'));
  assert.equal(row.is_phone_verified, false);
  assert.equal(w.state.notices.length, 1);
  assert.equal(w.state.notices[0].to, 'me@gmail.com');
});

test('changing an existing number replaces it, and the old number is free for another account at once', async () => {
  const old = phoneLookupHash('+919111122222');
  const w = world({ me: { id: 'me', email: 'me@gmail.com', is_email_verified: true, claimed_phone_hash: old, claimed_phone_enc: 'enc', phone_lookup_hash: null, phone_number: null, is_phone_verified: false } });
  const r = await start(w);
  const out = await svc.finishChange({ ...base(w), challenge: r.challenge, code: w.state.mail[0].code });
  assert.equal(out.had_phone, true);
  assert.equal(w.db.get('me').claimed_phone_hash, phoneLookupHash('+919876543210'));
  assert.notEqual(w.db.get('me').claimed_phone_hash, old);
});

test('a wrong code saves nothing', async () => {
  const w = world();
  const r = await start(w);
  await assert.rejects(svc.finishChange({ ...base(w), challenge: r.challenge, code: '000000' }), e => e instanceof PhoneChangeError && e.code === 'code_invalid');
  assert.equal(w.db.get('me').claimed_phone_hash, null);
  assert.equal(w.state.notices.length, 0);
});

test('a code cannot be used twice', async () => {
  const w = world();
  const r = await start(w);
  const code = w.state.mail[0].code;
  await svc.finishChange({ ...base(w), challenge: r.challenge, code });
  const again = world(); // different state; replay against the same world:
  await assert.rejects(svc.finishChange({ ...base(w), challenge: r.challenge, code }), e => ['code_invalid', 'same_phone'].includes(e.code));
  assert.ok(again);
});

test('a challenge from another user or device is rejected', async () => {
  const w = world({ other: { id: 'other', email: 'o@gmail.com', is_email_verified: true, claimed_phone_hash: null, phone_lookup_hash: null, phone_number: null, is_phone_verified: false } });
  const r = await start(w);
  const code = w.state.mail[0].code;
  await assert.rejects(svc.finishChange({ ...base(w, { userId: 'other' }), challenge: r.challenge, code }), e => e.code === 'challenge_invalid');
  await assert.rejects(svc.finishChange({ ...base(w, { deviceId: 'device-2' }), challenge: r.challenge, code }), e => e.code === 'challenge_invalid');
  await assert.rejects(svc.finishChange({ ...base(w), challenge: 'garbage', code }), e => e.code === 'challenge_invalid');
});

test('a number held by another live account is refused before any email is sent', async () => {
  const w = world({ x: { id: 'x', email: 'x@gmail.com', is_email_verified: true, claimed_phone_hash: phoneLookupHash('+919876543210'), phone_lookup_hash: null, phone_number: null, is_phone_verified: false } });
  await assert.rejects(start(w), e => e.code === 'phone_unavailable');
  assert.equal(w.state.mail.length, 0);
});

test('the number is taken by someone else between the two steps: the save is refused', async () => {
  const w = world();
  const r = await start(w);
  w.db.set('x', { id: 'x', deleted: false, is_active: true, claimed_phone_hash: phoneLookupHash('+919876543210') });
  await assert.rejects(svc.finishChange({ ...base(w), challenge: r.challenge, code: w.state.mail[0].code }), e => e.code === 'phone_unavailable');
  assert.equal(w.db.get('me').claimed_phone_hash, null);
});

test('the same number, bad numbers and unsupported countries are refused up front', async () => {
  const same = world({ me: { id: 'me', email: 'me@gmail.com', is_email_verified: true, claimed_phone_hash: phoneLookupHash('+919876543210'), phone_lookup_hash: null, phone_number: null, is_phone_verified: false } });
  await assert.rejects(start(same), e => e.code === 'same_phone');
  const w = world();
  await assert.rejects(start(w, '12345'), e => e.code === 'phone_invalid');
  await assert.rejects(start(w, '+14155550123'), e => e.code === 'phone_country_unsupported');
  assert.equal(w.state.mail.length, 0);
});

test('an account whose sign-in phone is verified cannot change it here; support does', async () => {
  const w = world({ me: { id: 'me', email: 'me@gmail.com', is_email_verified: true, claimed_phone_hash: null, phone_lookup_hash: phoneLookupHash('+919111122222'), phone_number: 'enc', is_phone_verified: true } });
  await assert.rejects(start(w), e => e.code === 'phone_already_set');
});

test('an account without a verified sign-in email cannot start', async () => {
  const w = world({ me: { id: 'me', email: null, is_email_verified: false, claimed_phone_hash: null, phone_lookup_hash: null, phone_number: null, is_phone_verified: false } });
  await assert.rejects(start(w), e => e.code === 'sign_in_email_required');
});

test('a failed email send discards the code and reports delivery_failed', async () => {
  const w = world();
  w.state.mailResult = () => ({ success: false });
  await assert.rejects(start(w), e => e.code === 'delivery_failed');
  assert.equal(w.state.discarded, 1);
});
