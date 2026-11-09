const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');
const { RateLimitStorageError, RateLimitExceededError } = require('../src/services/authAbuseStore');
const { PhoneClaimError } = require('../src/services/phoneClaim');

process.env.NODE_ENV = 'test';

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

async function harness(t, { user = { id: 'user-1', device_id: 'device-1' }, claim, status, budget } = {}) {
  const audits = [];
  const budgets = [];
  const claimCalls = [];
  const router = load('../src/routes/phoneClaimRoutes.js', {
    '../db': {
      pool: Promise.resolve({ marker: 'pool' }),
      async query(sql, args) { if (sql.includes('INSERT INTO auth_audit')) { audits.push({ status: args[1], meta: JSON.parse(args[5]), userId: args[0] }); return { rows: [] }; } throw new Error('unexpected query'); },
    },
    '../config': { allowedPhoneCountries: ['IN'] },
    '../middleware/authMiddleware': (req, _res, next) => { req.user = user; next(); },
    '../middleware/userRateLimit': { userRateLimitRead: (_q, _r, n) => n(), userRateLimitSensitive: (_q, _r, n) => n() },
    '../middleware/rateLimitMiddleware': {
      RateLimitStorageError, RateLimitExceededError,
      async consumeBudget(name, subject, limit, ttl) { budgets.push([name, subject, limit, ttl]); if (budget) return budget(name, subject); return 1; },
    },
    '../services/phoneClaim': {
      PhoneClaimError,
      async claimPhone(args) { claimCalls.push(args); return claim ? claim(args) : { phone_hint: '+91 •••• 3210', already: false }; },
      async getPhoneClaimStatus() { return status ? status() : { claimed: false, verified: false, required: true, needs_phone: true, phone_hint: null }; },
    },
  });
  const app = express();
  app.use(express.json());
  app.use('/users/me/phone', router);
  const server = await new Promise(resolve => { const listener = app.listen(0, '127.0.0.1', () => resolve(listener)); });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}/users/me/phone`;
  return {
    audits, budgets, claimCalls,
    async post(body) {
      const response = await fetch(base, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
      return { status: response.status, body: await response.json(), cache: response.headers.get('cache-control') };
    },
    async get() { const response = await fetch(base); return { status: response.status, body: await response.json() }; },
  };
}

test('a good number is saved, counted against the limits and audited without the number', async t => {
  const h = await harness(t);
  const r = await h.post({ phone_number: '98765 43210' });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true, phone_hint: '+91 •••• 3210' });
  assert.equal(r.cache, 'no-store');
  assert.deepEqual(h.budgets.map(b => b.slice(0, 2)), [['phone-claim-user', 'user-1'], ['phone-claim-ip', '127.0.0.1']]);
  assert.deepEqual(h.budgets.map(b => b[2]), [5, 30]);
  assert.deepEqual(h.claimCalls[0], { pool: { marker: 'pool' }, userId: 'user-1', phone: '98765 43210', countries: ['IN'] });
  assert.deepEqual(h.audits, [{ status: 'success', meta: { outcome: 'claimed' }, userId: 'user-1' }]);
  assert.doesNotMatch(JSON.stringify(h.audits), /9876543210|98765/);
});

test('each refusal has the right status and plain wording, and never names the other account', async t => {
  const cases = [
    ['phone_invalid', 400, /valid 10-digit mobile/],
    ['phone_country_unsupported', 400, /Indian mobile numbers/],
    ['phone_unavailable', 409, /can't be used.*sign in with the email you first used/],
    ['phone_already_set', 409, /already saved.*contact support/i],
    ['account_unavailable', 401, /sign in again/i],
  ];
  for (const [code, status, wording] of cases) {
    const h = await harness(t, { claim: () => { throw new PhoneClaimError(code); } });
    const r = await h.post({ phone_number: '9876543210' });
    assert.equal(r.status, status, code);
    assert.equal(r.body.error, code);
    assert.match(r.body.message, wording, code);
    assert.deepEqual(h.audits.map(a => [a.status, a.meta.outcome]), [['failed', code]], code);
  }
});

test('body shape is checked: only phone_number, as a string', async t => {
  const h = await harness(t);
  for (const body of [{}, { phone_number: 9876543210 }, { phone_number: '9876543210', email: 'a@b.co' }, [], { phone_number: null }]) {
    const r = await h.post(body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.equal(r.body.error, 'phone_invalid');
  }
  assert.equal(h.claimCalls.length, 0);
});

test('too many tries gives 429 and never reaches the claim', async t => {
  const h = await harness(t, { budget: name => { if (name === 'phone-claim-ip') throw new RateLimitExceededError(); return 1; } });
  const r = await h.post({ phone_number: '9876543210' });
  assert.equal(r.status, 429);
  assert.equal(r.body.error, 'too_many_attempts');
  assert.equal(h.claimCalls.length, 0);
});

test('if the limit store is down the request fails closed with 503', async t => {
  const h = await harness(t, { budget: () => { throw new RateLimitStorageError('storage_unavailable'); } });
  const r = await h.post({ phone_number: '9876543210' });
  assert.equal(r.status, 503);
  assert.equal(h.claimCalls.length, 0);
});

test('a recovery session cannot set a phone', async t => {
  const h = await harness(t, { user: { id: 'user-1', recovery_channel: 'email' } });
  const r = await h.post({ phone_number: '9876543210' });
  assert.equal(r.status, 403);
  assert.equal(h.claimCalls.length, 0);
});

test('GET reports whether the lock needs a phone', async t => {
  const h = await harness(t);
  const r = await h.get();
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { claimed: false, verified: false, required: true, needs_phone: true, phone_hint: null });
});
