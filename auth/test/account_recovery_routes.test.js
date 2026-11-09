const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');
const { RateLimitStorageError, RateLimitExceededError } = require('../src/services/authAbuseStore');
const { RecoveryError } = require('../src/services/accountRecovery');

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

async function harness(t, { methods = {}, budget, user = { id: 'user-1' } } = {}) {
  const calls = []; const budgets = [];
  const stub = name => async args => { calls.push([name, args]); return methods[name] ? methods[name](args) : { ok: true }; };
  const routes = load('../src/routes/accountRecoveryRoutes.js', {
    '../db': { query() {}, pool: Promise.resolve({}) },
    '../config': { authPublicBaseUrl: 'https://auth.test' },
    '../middleware/rateLimitMiddleware': {
      RateLimitStorageError, RateLimitExceededError,
      async consumeBudget(name, subject, limit, ttl) { budgets.push([name, subject, limit, ttl]); if (budget) return budget(name); return 1; },
    },
    '../middleware/authMiddleware': (req, _res, next) => { req.user = user; next(); },
    '../middleware/userRateLimit': { userRateLimitRead: (_q, _r, n) => n(), userRateLimitSensitive: (_q, _r, n) => n() },
    '../services/otpService': { createOtpV2() {}, verifyOtpV2() {}, discardUndeliveredOtpV2() {} },
    '../services/emailService': { sendOtpEmail() {}, sendSecurityNotice() {} },
    '../services/otpWorkAdmission': { OtpCapacityError: class extends Error {}, respondOtpCapacityUnavailable: r => r.status(503).json({ error: 'busy' }) },
    '../services/tokenService': { signAccessToken() {}, issueRefreshToken() {} },
    '../services/productApiClient': { cardFact() {} },
    '../services/accountRecovery': {
      RecoveryError,
      createAccountRecovery: () => ({
        start: stub('start'), verifyCode: stub('verifyCode'), noRecoveryEmail: stub('noRecoveryEmail'), setNewEmail: stub('setNewEmail'),
        complete: stub('complete'), finish: stub('finish'), stopByToken: stub('stopByToken'),
        pendingForUser: stub('pendingForUser'), cancelForUser: stub('cancelForUser'),
      }),
    },
  });
  const app = express(); app.use(express.json());
  app.use('/auth/recovery', routes.publicRouter);
  app.use('/users/me/recovery-pending', routes.pendingRouter);
  const server = await new Promise(resolve => { const l = app.listen(0, '127.0.0.1', () => resolve(l)); });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const json = async (method, p, body) => {
    const r = await fetch(base + p, { method, headers: { 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: r.status, body: await r.json(), cache: r.headers.get('cache-control') };
  };
  const page = async (method, p, form) => {
    const r = await fetch(base + p, { method, headers: form ? { 'content-type': 'application/x-www-form-urlencoded' } : {}, body: form });
    return { status: r.status, text: await r.text(), type: r.headers.get('content-type') };
  };
  return { calls, budgets, json, page };
}

const startBody = { lost_email: 'a@gmail.com', phone: '9876543210', fact: '4821', device_id: 'device-1' };

test('start passes exactly the four details to the service and is never cached', async t => {
  const h = await harness(t, { methods: { start: () => ({ ok: true, attempt_id: 'id', version: 2, code_length: 6, expires_in: 60 }) } });
  const r = await h.json('POST', '/auth/recovery/start', startBody);
  assert.equal(r.status, 200);
  assert.equal(r.cache, 'no-store');
  assert.deepEqual(h.calls[0][1], { lostEmail: 'a@gmail.com', phone: '9876543210', fact: '4821', deviceId: 'device-1', ip: '127.0.0.1' });
});

test('every step refuses a body with missing, extra or wrongly typed fields', async t => {
  const h = await harness(t);
  const steps = {
    '/start': startBody,
    '/verify-code': { attempt_id: 'x', code: '123456', device_id: 'device-1' },
    '/no-recovery-email': { attempt_id: 'x', device_id: 'device-1' },
    '/new-email': { attempt_id: 'x', device_id: 'device-1', new_email: 'n@y.com' },
    '/complete': { attempt_id: 'x', device_id: 'device-1', code: '123456' },
    '/finish': { attempt_id: 'x', device_id: 'device-1', resume_token: 'tok' },
  };
  for (const [step, good] of Object.entries(steps)) {
    for (const bad of [{}, { ...good, extra: 'x' }, { ...good, device_id: 5 }, []]) {
      const r = await h.json('POST', `/auth/recovery${step}`, bad);
      assert.equal(r.status, 400, `${step} ${JSON.stringify(bad)}`);
      assert.equal(r.body.error, 'invalid_request');
    }
  }
  assert.equal(h.calls.length, 0);
});

test('later steps are counted per attempt and per address; start is counted inside the service', async t => {
  const h = await harness(t);
  await h.json('POST', '/auth/recovery/verify-code', { attempt_id: 'abc-123', code: '123456', device_id: 'device-1' });
  assert.deepEqual(h.budgets.map(b => [b[0], b[1], b[2]]), [['recovery-step-attempt', 'abc-123', 30], ['recovery-step-ip', '127.0.0.1', 120]]);
  h.budgets.length = 0;
  await h.json('POST', '/auth/recovery/start', startBody);
  assert.deepEqual(h.budgets, [], 'the route adds no budget of its own to start');
});

test('refusals map to the right status and wording; a hold that is not over says when it ends', async t => {
  const cases = [
    ['recovery_failed', 400, /did not match/], ['email_invalid', 400, /valid email/], ['email_not_allowed', 400, /regular email/],
    ['same_as_old_email', 400, /different address/], ['email_unavailable', 409, /can't be used/], ['code_invalid', 400, /wrong or has expired/],
    ['account_unavailable', 409, /not available/], ['delivery_failed', 503, /could not send/],
  ];
  for (const [code, status, wording] of cases) {
    const h = await harness(t, { methods: { complete: () => { throw new RecoveryError(code); } } });
    const r = await h.json('POST', '/auth/recovery/complete', { attempt_id: 'x', device_id: 'device-1' });
    assert.equal(r.status, status, code);
    assert.equal(r.body.error, code);
    assert.match(r.body.message, wording, code);
  }
  const held = await harness(t, { methods: { finish: () => { throw new RecoveryError('hold_not_over', { hold_until: '2026-11-10T10:00:00.000Z' }); } } });
  const r = await held.json('POST', '/auth/recovery/finish', { attempt_id: 'x', device_id: 'device-1', resume_token: 'tok' });
  assert.deepEqual([r.status, r.body.hold_until], [409, '2026-11-10T10:00:00.000Z']);
});

test('over the limit is 429 and a down limit store fails closed with 503', async t => {
  const limited = await harness(t, { methods: { start: () => { throw new RateLimitExceededError(); } } });
  assert.equal((await limited.json('POST', '/auth/recovery/start', startBody)).status, 429);
  const down = await harness(t, { budget: () => { throw new RateLimitStorageError('storage_unavailable'); } });
  assert.equal((await down.json('POST', '/auth/recovery/verify-code', { attempt_id: 'x', code: '123456', device_id: 'device-1' })).status, 503);
});

test('opening the stop link changes nothing, shows a button, and escapes the token', async t => {
  const h = await harness(t);
  const evil = '"><script>alert(1)</script>';
  const r = await h.page('GET', `/auth/recovery/stop?token=${encodeURIComponent(evil)}`);
  assert.equal(r.status, 200);
  assert.match(r.type, /text\/html/);
  assert.match(r.text, /<form method="post" action="\/auth\/recovery\/stop">/);
  assert.doesNotMatch(r.text, /<script>alert/);
  assert.match(r.text, /&quot;&gt;&lt;script&gt;/);
  assert.equal(h.calls.length, 0, 'a link scanner opening it cannot cancel or freeze anything');
  assert.match((await h.page('GET', '/auth/recovery/stop')).text, /not valid/);
});

test('pressing the button performs the stop and says plainly what happened', async t => {
  const outcomes = {
    cancelled: /cancelled/i, frozen: /frozen/i, expired: /expired/i, unknown: /not valid/i,
  };
  for (const [outcome, wording] of Object.entries(outcomes)) {
    const h = await harness(t, { methods: { stopByToken: () => ({ outcome }) } });
    const r = await h.page('POST', '/auth/recovery/stop', 'token=abcdefghijklmnopqrstuvwxyz');
    assert.equal(r.status, 200, outcome);
    assert.match(r.text, wording, outcome);
    assert.deepEqual(h.calls[0][1], { token: 'abcdefghijklmnopqrstuvwxyz' });
  }
  const tooMany = await harness(t, { budget: () => { throw new RateLimitExceededError(); } });
  assert.equal((await tooMany.page('POST', '/auth/recovery/stop', 'token=abcdefghijklmnopqrstuvwxyz')).status, 429);
});

test('a signed-in device can see and cancel a waiting recovery, a recovery session cannot', async t => {
  const h = await harness(t, { methods: { pendingForUser: () => ({ pending: true, hold_until: '2026-11-10T10:00:00.000Z' }), cancelForUser: () => ({ ok: true, cancelled: 1 }) } });
  assert.deepEqual((await h.json('GET', '/users/me/recovery-pending')).body, { pending: true, hold_until: '2026-11-10T10:00:00.000Z' });
  assert.deepEqual((await h.json('POST', '/users/me/recovery-pending/cancel')).body, { ok: true, cancelled: 1 });
  assert.deepEqual(h.calls.map(c => c[1]), ['user-1', 'user-1']);
  const recovery = await harness(t, { user: { id: 'u', recovery_channel: 'email' } });
  assert.equal((await recovery.json('POST', '/users/me/recovery-pending/cancel')).status, 403);
  const nothing = await harness(t, { methods: { cancelForUser: () => { throw new RecoveryError('nothing_pending'); } } });
  assert.equal((await nothing.json('POST', '/users/me/recovery-pending/cancel')).status, 404);
});
