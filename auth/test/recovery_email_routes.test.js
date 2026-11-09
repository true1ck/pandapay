const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');
const { RateLimitStorageError, RateLimitExceededError } = require('../src/services/authAbuseStore');
const { RecoveryEmailError } = require('../src/services/recoveryEmail');

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

async function harness(t, { user = { id: 'user-1', device_id: 'device-1' }, service = {}, budget, stepUp = (_q, _r, n) => n() } = {}) {
  const audits = []; const budgets = []; const calls = {};
  const record = (name, impl) => async args => { (calls[name] ||= []).push(args); return impl ? impl(args) : {}; };
  const router = load('../src/routes/recoveryEmailRoutes.js', {
    '../db': { async query(sql, args) { if (sql.includes('INSERT INTO auth_audit')) { audits.push({ action: args[1], status: args[2], outcome: JSON.parse(args[6]).outcome }); return { rows: [] }; } throw new Error('unexpected query'); } },
    '../middleware/authMiddleware': (req, _res, next) => { req.user = user; next(); },
    '../middleware/userRateLimit': { userRateLimitRead: (_q, _r, n) => n(), userRateLimitSensitive: (_q, _r, n) => n() },
    '../middleware/stepUpAuth': { requireRecentOtpOrReauth: stepUp },
    '../middleware/rateLimitMiddleware': {
      RateLimitStorageError, RateLimitExceededError,
      async consumeBudget(name, subject, limit, ttl) { budgets.push([name, subject, limit, ttl]); if (budget) return budget(name); return 1; },
    },
    '../services/jwtKeys': { getActiveKey: () => ({ keyId: 'k', secret: 's' }), getKeySecret: () => 's', getIssuer: () => 'i', getAudience: () => 'a' },
    '../services/otpService': { createOtpV2() {}, verifyOtpV2() {}, discardUndeliveredOtpV2() {}, V2_TTL_SECONDS: 60 },
    '../services/emailService': { sendOtpEmail() {}, sendSecurityNotice() {} },
    '../services/otpWorkAdmission': { OtpCapacityError: class extends Error {}, respondOtpCapacityUnavailable: res => res.status(503).json({ error: 'busy' }) },
    '../services/recoveryEmail': {
      RecoveryEmailError,
      getStatus: record('getStatus', service.getStatus || (() => ({ has_recovery_email: false, recovery_email_hint: null, added_at: null }))),
      startChange: record('startChange', service.startChange || (() => ({ challenge: 'signed', contact_hint: 'b•••@outlook.com', expires_in: 60 }))),
      finishChange: record('finishChange', service.finishChange || (() => ({ recovery_email_hint: 'b•••@outlook.com' }))),
      removeRecoveryEmail: record('removeRecoveryEmail', service.removeRecoveryEmail || (() => ({ removed: true }))),
    },
  });
  const app = express(); app.use(express.json()); app.use('/users/me/recovery-email', router);
  const server = await new Promise(resolve => { const l = app.listen(0, '127.0.0.1', () => resolve(l)); });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}/users/me/recovery-email`;
  const send = async (method, suffix, body) => {
    const r = await fetch(base + suffix, { method, headers: { 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: r.status, body: await r.json(), cache: r.headers.get('cache-control') };
  };
  return { audits, budgets, calls, get: () => send('GET', ''), request: b => send('POST', '/request', b), verify: b => send('POST', '/verify', b), remove: () => send('DELETE', '') };
}

const goodRequest = { email: 'backup@outlook.com', device_id: 'device-1' };
const goodVerify = { challenge: 'signed', signin_code: '123456', recovery_code: '654321', device_id: 'device-1' };

test('requesting sends the typed email and the signed-in device, counts the limits and audits without the address', async t => {
  const h = await harness(t);
  const r = await h.request(goodRequest);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { challenge: 'signed', contact_hint: 'b•••@outlook.com', expires_in: 60, version: 2, code_length: 6 });
  assert.equal(r.cache, 'no-store');
  assert.equal(h.calls.startChange[0].email, 'backup@outlook.com');
  assert.equal(h.calls.startChange[0].deviceId, 'device-1');
  assert.deepEqual(h.budgets.map(b => [b[0], b[2]]), [['recovery-email-start-user', 5], ['recovery-email-start-ip', 20]]);
  assert.deepEqual(h.audits, [{ action: 'recovery_email_request', status: 'success', outcome: 'codes_sent' }]);
  assert.doesNotMatch(JSON.stringify(h.audits), /outlook/);
});

test('a recovery session, a missing device or a different device cannot change the recovery email', async t => {
  const recovery = await harness(t, { user: { id: 'u', device_id: 'device-1', recovery_channel: 'email' } });
  assert.equal((await recovery.request(goodRequest)).status, 403);
  assert.equal((await recovery.verify(goodVerify)).status, 403);
  assert.equal((await recovery.remove()).status, 403);
  const noDevice = await harness(t, { user: { id: 'u' } });
  assert.equal((await noDevice.request(goodRequest)).status, 403);
  const other = await harness(t);
  assert.equal((await other.request({ ...goodRequest, device_id: 'device-2' })).status, 400);
  assert.equal((await other.verify({ ...goodVerify, device_id: 'device-2' })).status, 400);
  assert.equal(other.calls.startChange, undefined);
});

test('body shape is strict: only the expected strings, six-digit codes', async t => {
  const h = await harness(t);
  for (const body of [{}, { email: 'a@b.co' }, { ...goodRequest, extra: 1 }, { ...goodRequest, email: 5 }, []]) {
    assert.equal((await h.request(body)).status, 400, JSON.stringify(body));
  }
  for (const body of [{}, { ...goodVerify, signin_code: '12345' }, { ...goodVerify, recovery_code: 'abcdef' }, { ...goodVerify, extra: 'x' }, { ...goodVerify, challenge: 7 }]) {
    assert.equal((await h.verify(body)).status, 400, JSON.stringify(body));
  }
  assert.equal(h.calls.startChange, undefined);
  assert.equal(h.calls.finishChange, undefined);
});

test('each refusal has the right status and plain wording', async t => {
  const cases = [
    ['email_invalid', 400, /valid email/], ['email_not_allowed', 400, /regular email address/], ['same_as_sign_in', 400, /already your sign-in email/],
    ['email_unavailable', 409, /can't be used as a recovery email/], ['sign_in_email_required', 409, /verified sign-in email/],
    ['delivery_failed', 503, /could not send/], ['challenge_invalid', 400, /expired/], ['code_invalid', 400, /wrong or has expired/], ['account_unavailable', 401, /sign in again/i],
  ];
  for (const [code, status, wording] of cases) {
    const h = await harness(t, { service: { startChange: () => { throw new RecoveryEmailError(code); } } });
    const r = await h.request(goodRequest);
    assert.equal(r.status, status, code);
    assert.equal(r.body.error, code);
    assert.match(r.body.message, wording, code);
    assert.deepEqual(h.audits.map(a => [a.status, a.outcome]), [['failed', code]], code);
  }
});

test('too many tries gives 429 before anything is sent, and a down limit store fails closed', async t => {
  const limited = await harness(t, { budget: name => { if (name === 'recovery-email-start-ip') throw new RateLimitExceededError(); return 1; } });
  assert.equal((await limited.request(goodRequest)).status, 429);
  assert.equal(limited.calls.startChange, undefined);
  const down = await harness(t, { budget: () => { throw new RateLimitStorageError('storage_unavailable'); } });
  assert.equal((await down.request(goodRequest)).status, 503);
  assert.equal((await down.verify(goodVerify)).status, 503);
});

test('verifying passes both codes and the challenge to the service and reports the masked address', async t => {
  const h = await harness(t);
  const r = await h.verify(goodVerify);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true, recovery_email_hint: 'b•••@outlook.com' });
  assert.deepEqual([h.calls.finishChange[0].signInCode, h.calls.finishChange[0].newCode, h.calls.finishChange[0].challenge], ['123456', '654321', 'signed']);
  assert.deepEqual(h.budgets.map(b => [b[0], b[2], b[3]]), [['recovery-email-finish-user', 10, 3600]]);
  assert.deepEqual(h.audits, [{ action: 'recovery_email_set', status: 'success', outcome: 'saved' }]);
});

test('removing needs the recent sign-in proof, and works once it is given', async t => {
  const blocked = await harness(t, { stepUp: (_q, res) => res.status(403).json({ error: 'step_up_required' }) });
  assert.equal((await blocked.remove()).status, 403);
  assert.equal(blocked.calls.removeRecoveryEmail, undefined);
  const ok = await harness(t);
  const r = await ok.remove();
  assert.deepEqual([r.status, r.body], [200, { ok: true, removed: true }]);
  assert.deepEqual(ok.audits, [{ action: 'recovery_email_removed', status: 'success', outcome: 'removed' }]);
});

test('GET reports whether there is a recovery email', async t => {
  const h = await harness(t, { service: { getStatus: () => ({ has_recovery_email: true, recovery_email_hint: 'b•••@outlook.com', added_at: '2026-11-09T10:00:00.000Z' }) } });
  const r = await h.get();
  assert.equal(r.status, 200);
  assert.equal(r.body.has_recovery_email, true);
  assert.equal(r.body.recovery_email_hint, 'b•••@outlook.com');
});
