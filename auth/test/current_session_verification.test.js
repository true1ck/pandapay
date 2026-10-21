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

test('guest session is explicit and does not query a user row', async () => {
  const { verifyCurrentSession } = sessionService();
  let calls = 0;
  const result = await verifyCurrentSession(token({ sub: 'guest-1', is_guest: true }), {
    async query() { calls++; throw new Error('guest must not query users'); },
  });
  assert.equal(result.subject, 'guest-1');
  assert.equal(result.guest, true);
  assert.equal(result.session.active, true);
  assert.equal(result.session.revoked, false);
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
