const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');
const { maskEmail, maskPhone } = require('../src/utils/recoveryContacts');

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

async function harness(t) {
  const user = { id: 'user-a', email: 'old@example.com', phone_number: '+919876541234',
    is_phone_verified: true, is_email_verified: true };
  let proof = { id: user.id, recovery_channel: 'phone', recovery_verified_at: Math.floor(Date.now() / 1000) };
  let conflict = false, delivery = true, validCode = false, consumed = false;
  const config = { enableEmailOtp: true, enablePhoneOtp: true };
  let sends = 0, updates = 0, discarded = 0;
  const challenges = [];
  const router = load('../src/routes/recoveryContactRoutes.js', {
    '../db': { async query(sql, args) {
      if (sql.startsWith('SELECT id, email')) return { rows: [{ ...user }] };
      if (sql.startsWith('SELECT id FROM')) return { rows: conflict ? [{ id: 'someone-else' }] : [] };
      if (sql.startsWith('UPDATE users')) {
        const column = sql.includes('SET email') ? 'email' : 'phone_number';
        if (column === 'email') {
          assert.equal(args[1], user.id);
          assert.equal(args[2], user[column]);
          user[column] = args[0];
        } else {
          assert.equal(args[2], user.id);
          assert.equal(args[3], user[column]);
          user[column] = args[0];
          user.phone_lookup_hash = args[1];
        }
        updates++;
        return { rows: [{ id: user.id }] };
      }
      throw new Error('Unexpected SQL');
    } },
    '../config': config,
    '../middleware/authMiddleware': (req, _res, next) => { req.user = proof; next(); },
    '../middleware/userRateLimit': { userRateLimitSensitive: (_req, _res, next) => next() },
    '../services/jwtKeys': {
      getActiveKey: () => ({ keyId: 'test', secret: 'test-secret' }),
      getKeySecret: key => key === 'test' ? 'test-secret' : null,
      getIssuer: () => 'auth-test', getAudience: () => 'app-test',
    },
    '../services/otpService': {
      async createOtp(identifier) { challenges.push(identifier); return { code: '5678', requestId: 'request-id' }; },
      async verifyOtp(identifier) {
        assert.ok(challenges.includes(identifier));
        const ok = validCode && !consumed;
        if (ok) consumed = true;
        return { ok };
      },
      async discardUndeliveredOtp() { discarded++; },
    },
    '../services/emailService': { async sendOtpEmail(value) {
      assert.equal(value, 'new@example.com'); sends++; return { success: delivery };
    } },
    '../services/smsService': { async sendOtpSms() { sends++; return { success: delivery }; } },
    '../utils/fieldEncryption': { encryptPhoneNumber: value => value, decryptPhoneNumber: value => value },
    '../utils/encryptedPhoneSearch': { preparePhoneSearchParams: value => [value], phoneLookupHash: value => value },
  });
  const app = express(); app.use(express.json()); app.use('/recovery', router);
  const server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  t.after(() => { server.closeAllConnections(); server.close(); });
  return {
    user, config,
    setProof(value) { proof = value; },
    get proof() { return proof; },
    conflict() { conflict = true; }, failDelivery() { delivery = false; },
    allowCode() { validCode = true; },
    get sends() { return sends; }, get updates() { return updates; }, get discarded() { return discarded; },
    async post(action, body) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/recovery/${action}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      return { status: response.status, body: await response.json() };
    },
  };
}

test('linked contacts are masked in recognisable form', () => {
  assert.equal(maskEmail('chandresh@gmail.com'), 'c•••@gmail.com');
  assert.equal(maskPhone('+919876541234'), '+91 •••• 1234');
});

test('a normal session or expired recovery proof cannot replace a contact', async t => {
  const h = await harness(t);
  for (const proof of [{ id: 'user-a' }, { id: 'user-a', recovery_channel: 'phone', recovery_verified_at: 1 }]) {
    h.setProof(proof);
    assert.equal((await h.post('request', { identifier: 'new@example.com' })).status, 403);
  }
  assert.equal(h.sends, 0); assert.equal(h.updates, 0);
});

test('the old linked email is kept until the new email code is verified', async t => {
  const h = await harness(t);
  const requested = await h.post('request', { identifier: 'new@example.com' });
  assert.equal(requested.status, 200);
  assert.equal(h.user.email, 'old@example.com');
  assert.equal(h.updates, 0);
  const body = { challenge: requested.body.challenge, code: '5678' };
  assert.equal((await h.post('verify', body)).status, 400);
  assert.equal(h.updates, 0);
  h.allowCode();
  const saved = await h.post('verify', body);
  assert.equal(saved.status, 200);
  assert.equal(saved.body.email_hint, 'n•••@example.com');
  assert.equal(h.user.email, 'new@example.com');
  assert.equal(h.user.phone_number, '+919876541234');
  assert.equal(h.updates, 1);
  assert.equal((await h.post('verify', body)).status, 409);
});

test('replacement challenges cannot be used on another account', async t => {
  const h = await harness(t);
  const requested = await h.post('request', { identifier: 'new@example.com' });
  h.setProof({ ...h.proof, id: 'user-b' });
  h.allowCode();
  assert.equal((await h.post('verify', { challenge: requested.body.challenge, code: '5678' })).status, 403);
  assert.equal(h.updates, 0);
});

test('phone contact replacement requires the existing email proof and stores a searchable hash', async t => {
  const h = await harness(t);
  h.setProof({ id: 'user-a', recovery_channel: 'email', recovery_verified_at: Math.floor(Date.now() / 1000) });
  const requested = await h.post('request', { identifier: '+919999998888' });
  assert.equal(requested.status, 200);
  assert.equal(h.user.phone_number, '+919876541234');
  h.allowCode();
  const saved = await h.post('verify', { challenge: requested.body.challenge, code: '5678' });
  assert.equal(saved.status, 200);
  assert.equal(h.user.phone_number, '+919999998888');
  assert.equal(h.user.phone_lookup_hash, '+919999998888');
  assert.equal(h.user.is_phone_verified, true);
});

test('conflicting contact and failed delivery leave the linked contact unchanged', async t => {
  const h = await harness(t);
  h.failDelivery();
  assert.equal((await h.post('request', { identifier: 'new@example.com' })).status, 503);
  assert.equal(h.discarded, 1);
  h.conflict();
  assert.equal((await h.post('request', { identifier: 'new@example.com' })).status, 409);
  assert.equal(h.updates, 0);
});

test('email proof permits only phone replacement and honours disabled SMS', async t => {
  const h = await harness(t);
  h.setProof({ ...h.proof, recovery_channel: 'email' });
  assert.equal((await h.post('request', { identifier: 'new@example.com', channel: 'email' })).status, 400);
  h.config.enablePhoneOtp = false;
  const result = await h.post('request', { identifier: '+919876549999' });
  assert.equal(result.status, 403);
  assert.match(result.body.error, /SMS verification is currently unavailable/);
  assert.equal(h.sends, 0); assert.equal(h.updates, 0);
});
