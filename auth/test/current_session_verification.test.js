const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');

process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET = 'session-verification-access-secret';
process.env.JWT_KEYS_JSON = JSON.stringify({ current: process.env.JWT_ACCESS_SECRET });
process.env.JWT_ACTIVE_KEY_ID = 'current';
process.env.JWT_ISSUER = 'pandapay-auth';
process.env.JWT_AUDIENCE = 'mobile-app';

function load(relativePath, dependencies) {
  const filename = path.resolve(__dirname, relativePath);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request)
    ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

function token(claims = {}) {
  return jwt.sign({ sub: 'user-1', token_version: 2, ...claims }, process.env.JWT_ACCESS_SECRET, {
    issuer: process.env.JWT_ISSUER, audience: process.env.JWT_AUDIENCE,
    expiresIn: '5m', keyid: 'current',
  });
}

function sessionService() {
  return load('../src/services/currentSessionVerification.js', {
    '../db': {},
    '../utils/fieldEncryption': { decryptPhoneNumber: value => value.replace('enc:', '') },
  });
}

test('current-session proof returns only verified contacts and rejects revoked subjects', async () => {
  const { verifyCurrentSession } = sessionService();
  const executor = {
    async query(sql) {
      if (sql.includes('FROM users')) return { rows: [{
        id: 'user-1', email: 'verified@example.com', phone_number: 'enc:+919876543210',
        is_email_verified: true, is_phone_verified: false, is_active: true, deleted: false,
        token_version: 2,
      }] };
      if (sql.includes('FROM user_devices')) return { rows: [{ id: 'device-1' }] };
      throw new Error('Unexpected SQL');
    },
  };
  const active = await verifyCurrentSession(token({
    device_id: 'device-a', verified_channel: 'email', factor_verified_at: 123,
  }), executor);
  assert.equal(active.subject, 'user-1');
  assert.equal(active.valid, true);
  assert.equal(active.session.active, true);
  assert.equal(active.session.revoked, false);
  assert.deepEqual(active.auth_proof, { channel: 'email', verified_at: 123 });
  assert.deepEqual(active.verified_contacts, {
    email: { verified: true, value: 'verified@example.com' },
    phone: { verified: false, value: null },
  });

  executor.query = async () => ({ rows: [{
    id: 'user-1', email: 'verified@example.com', phone_number: null,
    is_email_verified: true, is_phone_verified: false, is_active: false, deleted: false,
    token_version: 2,
  }] });
  const revoked = await verifyCurrentSession(token(), executor);
  assert.equal(revoked.token_valid, true);
  assert.equal(revoked.valid, false);
  assert.equal(revoked.session.active, false);
  assert.equal(revoked.session.revoked, true);
  assert.equal(revoked.session.revocation, 'account_inactive');
  assert.equal(revoked.verified_contacts.email.verified, true);
  assert.equal(revoked.verified_contacts.email.value, null);
});

test('a leftover guest token is refused without touching the database', async () => {
  const { verifyCurrentSession } = sessionService();
  let calls = 0;
  await assert.rejects(
    verifyCurrentSession(token({ sub: 'guest-1', is_guest: true }), {
      async query() { calls++; throw new Error('guest tokens must never reach the user table'); },
    }),
    /invalid_token/,
  );
  assert.equal(calls, 0);
});

test('internal session response requires the backend secret and bearer access token', async t => {
  const secret = 'test-internal-service-secret-at-least-32-bytes';
  const router = load('../src/routes/internalRoutes.js', {
    '../config': { authInternalServiceSecret: secret },
    '../services/currentSessionVerification': {
      async verifyCurrentSession(value) {
        assert.equal(value, 'user-access-token');
        return { subject: 'user-1', verified_contacts: { email: { verified: true, value: 'private@example.com' } } };
      },
    },
  });
  const app = express(); app.use(express.json()); app.use('/internal', router);
  const server = await new Promise(resolve => {
    const listener = app.listen(0, '127.0.0.1', () => resolve(listener));
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = `http://127.0.0.1:${server.address().port}/internal/session/verify`;
  const denied = await fetch(url, { method: 'POST', headers: { Authorization: 'Bearer user-access-token' } });
  assert.equal(denied.status, 401);
  const allowed = await fetch(url, { method: 'POST', headers: {
    Authorization: 'Bearer user-access-token', 'x-auth-service-secret': secret,
  } });
  assert.equal(allowed.status, 200);
  assert.equal((await allowed.json()).verified_contacts.email.value, 'private@example.com');
});

test('internal session route fails closed when its service secret is not configured', async t => {
  const router = load('../src/routes/internalRoutes.js', {
    '../config': { authInternalServiceSecret: null },
    '../services/currentSessionVerification': {
      async verifyCurrentSession() { assert.fail('must not verify without service authentication'); },
    },
  });
  const app = express(); app.use('/internal', router);
  const server = await new Promise(resolve => {
    const listener = app.listen(0, '127.0.0.1', () => resolve(listener));
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const response = await fetch(`http://127.0.0.1:${server.address().port}/internal/session/verify`, {
    method: 'POST', headers: {
      Authorization: 'Bearer user-access-token',
      'x-auth-service-secret': 'not-a-valid-configured-secret',
    },
  });
  assert.equal(response.status, 503);
});

function userRow(changes = {}) {
  return {
    id: 'user-1', email: 'person@example.com', phone_number: null, claimed_phone_enc: null,
    is_email_verified: true, is_phone_verified: false, is_active: true, deleted: false, token_version: 2,
    ...changes,
  };
}

async function sessionFor(row, { gate } = {}) {
  const prior = process.env.REQUIRE_PHONE_AT_SIGNUP;
  if (gate === undefined) delete process.env.REQUIRE_PHONE_AT_SIGNUP; else process.env.REQUIRE_PHONE_AT_SIGNUP = gate;
  try {
    return await sessionService().verifyCurrentSession(token(), { async query() { return { rows: [row] }; } });
  } finally {
    if (prior === undefined) delete process.env.REQUIRE_PHONE_AT_SIGNUP; else process.env.REQUIRE_PHONE_AT_SIGNUP = prior;
  }
}

test('a typed phone is reported as claimed, never as a verified contact', async () => {
  const result = await sessionFor(userRow({ claimed_phone_enc: 'enc:+919876543210' }), { gate: 'true' });
  assert.deepEqual(result.claimed_contacts, { phone: { claimed: true, value: '+919876543210' } });
  assert.deepEqual(result.verified_contacts.phone, { verified: false, value: null });
  assert.deepEqual(result.phone_gate, { required: true, satisfied: true });
});

test('with the lock on, an account with no phone is not satisfied; with it off nothing is required', async () => {
  assert.deepEqual((await sessionFor(userRow(), { gate: 'true' })).phone_gate, { required: true, satisfied: false });
  assert.deepEqual((await sessionFor(userRow())).phone_gate, { required: false, satisfied: false });
  assert.deepEqual((await sessionFor(userRow(), { gate: 'false' })).phone_gate, { required: false, satisfied: false });
});

test('a verified phone from before the lock also satisfies it', async () => {
  const result = await sessionFor(userRow({ phone_number: 'enc:+919876543210', is_phone_verified: true }), { gate: 'true' });
  assert.deepEqual(result.phone_gate, { required: true, satisfied: true });
  assert.deepEqual(result.claimed_contacts, { phone: { claimed: false, value: null } });
});

test('a disabled account exposes no claimed number and is not satisfied', async () => {
  const result = await sessionFor(userRow({ claimed_phone_enc: 'enc:+919876543210', is_active: false }), { gate: 'true' });
  assert.deepEqual(result.claimed_contacts, { phone: { claimed: false, value: null } });
  assert.deepEqual(result.phone_gate, { required: true, satisfied: false });
});

test('the number held for an account is reported for Split even when it was never verified', async () => {
  const { verifyCurrentSession } = sessionService();
  const row = (extra) => ({
    id: 'user-1', email: 'friend@example.com', phone_number: null, is_email_verified: true,
    is_phone_verified: false, is_active: true, deleted: false, token_version: 2, ...extra,
  });
  const run = (extra) => verifyCurrentSession(token(), {
    async query(sql) {
      if (sql.includes('FROM users')) return { rows: [row(extra)] };
      throw new Error('Unexpected SQL');
    },
  });
  const unverified = await run({ phone_number: 'enc:+917030445936' });
  assert.deepEqual(unverified.phone_on_file, { present: true, value: '+917030445936' });
  assert.equal(unverified.verified_contacts.phone.verified, false, 'it is still not reported as verified');
  assert.equal(unverified.verified_contacts.phone.value, null);
  const typedOnly = await run({ claimed_phone_enc: 'enc:+919876543210' });
  assert.deepEqual(typedOnly.phone_on_file, { present: true, value: '+919876543210' });
  assert.deepEqual(await run({}).then((r) => r.phone_on_file), { present: false, value: null });
  const inactive = await run({ phone_number: 'enc:+917030445936', is_active: false });
  assert.deepEqual(inactive.phone_on_file, { present: false, value: null }, 'no number for a revoked session');
});

test('with a start date, only accounts created on or after it must add a phone', async () => {
  const { phoneGateRequiredFor } = require('../src/utils/phoneGate');
  const on = { REQUIRE_PHONE_AT_SIGNUP: 'true', PHONE_GATE_NEW_ACCOUNTS_FROM: '2026-11-11T00:00:00Z' };
  assert.equal(phoneGateRequiredFor('2026-10-20T00:00:00Z', on), false, 'an older account is never locked out');
  assert.equal(phoneGateRequiredFor('2026-11-10T23:59:59Z', on), false);
  assert.equal(phoneGateRequiredFor('2026-11-11T00:00:00Z', on), true, 'the start moment itself is included');
  assert.equal(phoneGateRequiredFor(new Date('2026-12-01T10:00:00Z'), on), true, 'a Date from the database works');
  assert.equal(phoneGateRequiredFor(undefined, on), false, 'an account of unknown age is not locked');
  assert.equal(phoneGateRequiredFor('2026-12-01T00:00:00Z', { PHONE_GATE_NEW_ACCOUNTS_FROM: '2026-11-11T00:00:00Z' }), false, 'nothing is required while the lock itself is off');
  const all = { REQUIRE_PHONE_AT_SIGNUP: 'true' };
  assert.equal(phoneGateRequiredFor('2020-01-01T00:00:00Z', all), true, 'no start date keeps the old every-account behaviour');
  assert.equal(phoneGateRequiredFor('2020-01-01T00:00:00Z', { ...all, PHONE_GATE_NEW_ACCOUNTS_FROM: '' }), true);
  assert.throws(() => phoneGateRequiredFor('2026-12-01T00:00:00Z', { ...all, PHONE_GATE_NEW_ACCOUNTS_FROM: 'soon' }), /ISO date/);
});

test('the session tells an old account no phone is needed and a new one that it is', async () => {
  const prior = { gate: process.env.REQUIRE_PHONE_AT_SIGNUP, from: process.env.PHONE_GATE_NEW_ACCOUNTS_FROM };
  process.env.REQUIRE_PHONE_AT_SIGNUP = 'true';
  process.env.PHONE_GATE_NEW_ACCOUNTS_FROM = '2026-11-11T00:00:00Z';
  try {
    const old = await sessionService().verifyCurrentSession(token(), { async query() { return { rows: [userRow({ created_at: new Date('2026-10-20T00:00:00Z') })] }; } });
    assert.deepEqual(old.phone_gate, { required: false, satisfied: false });
    const fresh = await sessionService().verifyCurrentSession(token(), { async query() { return { rows: [userRow({ created_at: new Date('2026-11-12T09:00:00Z') })] }; } });
    assert.deepEqual(fresh.phone_gate, { required: true, satisfied: false });
    const withPhone = await sessionService().verifyCurrentSession(token(), { async query() { return { rows: [userRow({ created_at: new Date('2026-11-12T09:00:00Z'), claimed_phone_enc: 'enc:+917030445936' })] }; } });
    assert.deepEqual(withPhone.phone_gate, { required: true, satisfied: true });
  } finally {
    if (prior.gate === undefined) delete process.env.REQUIRE_PHONE_AT_SIGNUP; else process.env.REQUIRE_PHONE_AT_SIGNUP = prior.gate;
    if (prior.from === undefined) delete process.env.PHONE_GATE_NEW_ACCOUNTS_FROM; else process.env.PHONE_GATE_NEW_ACCOUNTS_FROM = prior.from;
  }
});
