const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');
const { maskEmail, maskPhone } = require('../src/utils/recoveryContacts');
const {
  RateLimitStorageError,
  RateLimitExceededError,
  ActiveOtpError,
} = require('../src/services/authAbuseStore');

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

async function harness(t, { requestBudgetLimit = Infinity, verifyBudgetLimit = Infinity } = {}) {
  const user = { id: 'user-a', email: 'old@example.com', phone_number: '+919876541234',
    is_phone_verified: true, is_email_verified: true };
  let proof = { id: user.id, recovery_channel: 'phone', recovery_verified_at: Math.floor(Date.now() / 1000) };
  let conflict = false, delivery = true, validCode = false, consumed = false, otpStorageError = null;
  const config = { enableEmailOtp: true, enablePhoneOtp: true };
  let sends = 0, updates = 0, discarded = 0, verifyAttempts = 0;
  let budgetStorageFailure = false;
  const challenges = [];
  const availabilityQueries = [];
  const budgetCalls = [];
  const budgetCounts = new Map();
  const router = load('../src/routes/recoveryContactRoutes.js', {
    '../db': { async query(sql, args) {
      if (sql.startsWith('SELECT id, email')) return { rows: [{ ...user }] };
      if (sql.startsWith('SELECT id FROM')) {
        availabilityQueries.push(sql);
        return { rows: conflict ? [{ id: 'someone-else' }] : [] };
      }
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
      async createOtp(identifier) {
        if (otpStorageError) throw otpStorageError;
        challenges.push(identifier); return { code: '5678', requestId: 'request-id' };
      },
      async verifyOtp(identifier) {
        if (otpStorageError) throw otpStorageError;
        assert.ok(challenges.includes(identifier));
        verifyAttempts++;
        const ok = validCode && !consumed;
        if (ok) consumed = true;
        return { ok };
      },
      async discardUndeliveredOtp() { discarded++; },
    },
    '../middleware/rateLimitMiddleware': {
      RateLimitStorageError, RateLimitExceededError, ActiveOtpError,
      async consumeReplacementBudget(userId, channel, action) {
        budgetCalls.push({ userId, channel, action });
        if (budgetStorageFailure) throw new RateLimitStorageError('storage_unavailable');
        const key = `${userId}:${channel}:${action}`;
        const count = (budgetCounts.get(key) || 0) + 1;
        budgetCounts.set(key, count);
        const limit = action === 'request' ? requestBudgetLimit : verifyBudgetLimit;
        if (count > limit) throw new RateLimitExceededError();
        return count;
      },
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
    failOtpStorage() { otpStorageError = new RateLimitStorageError('storage_unavailable'); },
    failBudgetStorage() { budgetStorageFailure = true; },
    get sends() { return sends; }, get updates() { return updates; }, get discarded() { return discarded; },
    get verifyAttempts() { return verifyAttempts; }, budgetCalls, challenges,
    availabilityQueries,
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

test('recovery contact availability follows active-only reuse policy for email and phone', async t => {
  const h = await harness(t);
  assert.equal((await h.post('request', { identifier: 'new@example.com' })).status, 200);
  h.setProof({ id: 'user-a', recovery_channel: 'email', recovery_verified_at: Math.floor(Date.now() / 1000) });
  assert.equal((await h.post('request', { identifier: '+919876549999' })).status, 200);
  assert.equal(h.availabilityQueries.length, 2);
  assert.ok(h.availabilityQueries.every(sql => /deleted\s*=\s*FALSE/.test(sql)));
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

test('abuse-store failures during recovery request and verification return 503', async t => {
  const requestFailure = await harness(t);
  requestFailure.failOtpStorage();
  const blocked = await requestFailure.post('request', { identifier: 'new@example.com' });
  assert.equal(blocked.status, 503);
  assert.equal(requestFailure.sends, 0);

  const verifyFailure = await harness(t);
  const requested = await verifyFailure.post('request', { identifier: 'new@example.com' });
  assert.equal(requested.status, 200);
  verifyFailure.failOtpStorage();
  const blockedVerify = await verifyFailure.post('verify', { challenge: requested.body.challenge, code: '5678' });
  assert.equal(blockedVerify.status, 503);
  assert.equal(verifyFailure.updates, 0);
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

test('concurrent replacement requests consume one stable account budget across random challenges', async t => {
  const h = await harness(t, { requestBudgetLimit: 2 });
  const responses = await Promise.all([
    h.post('request', { identifier: 'new@example.com' }),
    h.post('request', { identifier: 'new@example.com' }),
    h.post('request', { identifier: 'new@example.com' }),
  ]);
  assert.deepEqual(responses.map(response => response.status).sort((a, b) => a - b), [200, 200, 429]);
  assert.equal(h.sends, 2);
  assert.equal(h.challenges.length, 2);
  assert.notEqual(h.challenges[0], h.challenges[1]);
  assert.deepEqual(h.budgetCalls.map(({ userId, channel, action }) => [userId, channel, action]), [
    ['user-a', 'email', 'request'], ['user-a', 'email', 'request'], ['user-a', 'email', 'request'],
  ]);
});

test('every valid replacement challenge verification attempt consumes the account attempt cap', async t => {
  const h = await harness(t, { verifyBudgetLimit: 3 });
  const requested = await h.post('request', { identifier: 'new@example.com' });
  const body = { challenge: requested.body.challenge, code: '5678' };
  for (let attempt = 0; attempt < 3; attempt++) {
    assert.equal((await h.post('verify', body)).status, 400);
  }
  const blocked = await h.post('verify', body);
  assert.equal(blocked.status, 429);
  assert.match(blocked.body.error, /Too many contact replacement attempts/);
  assert.equal(h.verifyAttempts, 3);
  assert.equal(h.updates, 0);
  assert.equal(h.budgetCalls.filter(({ action }) => action === 'verify').length, 4);
});

test('replacement budget storage outages fail closed before delivery or OTP verification', async t => {
  const requestFailure = await harness(t);
  requestFailure.failBudgetStorage();
  const blockedRequest = await requestFailure.post('request', { identifier: 'new@example.com' });
  assert.equal(blockedRequest.status, 503);
  assert.equal(requestFailure.sends, 0);

  const verifyFailure = await harness(t);
  const requested = await verifyFailure.post('request', { identifier: 'new@example.com' });
  verifyFailure.failBudgetStorage();
  const blockedVerify = await verifyFailure.post('verify', {
    challenge: requested.body.challenge, code: '5678',
  });
  assert.equal(blockedVerify.status, 503);
  assert.equal(verifyFailure.verifyAttempts, 0);
  assert.equal(verifyFailure.updates, 0);
});
