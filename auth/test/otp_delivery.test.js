const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');

// Load the real route/service code with isolated provider and storage doubles.
// No database, SMTP server, production secrets, or test OTP bypass is used.
function load(relativePath, dependencies) {
  const filename = path.resolve(__dirname, relativePath);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request)
    ? dependencies[request]
    : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

async function harness(t, useRedis = false) {
  const rows = [];
  const keys = new Map();
  const redis = {
    async exists(key) { return keys.has(key) ? 1 : 0; },
    async incr(key) { const value = Number(keys.get(key) || 0) + 1; keys.set(key, value); return value; },
    async expire() {},
    async setEx(key, _ttl, value) { keys.set(key, value); },
    async eval(_script, { keys: [key], arguments: [expected] }) {
      if (keys.get(key) === expected) { keys.delete(key); return 1; }
      return 0;
    },
  };
  const limiter = load('../src/middleware/rateLimitMiddleware.js', {
    '../services/redisClient': {
      getRedisClient: async () => useRedis ? redis : null,
      isRedisReady: () => useRedis,
    },
  });
  const db = {
    async query(sql, args) {
      if (sql.includes('INSERT INTO otp_requests')) {
        const row = { id: String(rows.length + 1), email: args[1], deleted: false };
        rows.push(row);
        return { rows: [{ id: row.id }] };
      }
      if (sql.includes('UPDATE otp_requests')) {
        for (const row of rows) {
          if (sql.includes('WHERE id =') ? row.id === args[0] && row.email === args[1] : row.email === args[0]) {
            row.deleted = true;
          }
        }
        return { rows: [] };
      }
      if (sql.includes('FROM users')) return { rows: [] };
      throw new Error('Unexpected database operation in email delivery test');
    },
  };
  const config = { isProduction: true, enableEmailOtp: true, enablePhoneOtp: true };
  const otp = load('../src/services/otpService.js', {
    '../db': db,
    '../config': config,
    '../middleware/rateLimitMiddleware': limiter,
    '../utils/fieldEncryption': { encryptPhoneNumber: value => value },
  });
  let delivered = true;
  let mailCount = 0;
  const noop = async () => {};
  const router = load('../src/routes/authRoutes.js', {
    '../db': db,
    '../config': config,
    '../middleware/authMiddleware': (_req, _res, next) => next(),
    '../services/smsService': {},
    '../services/emailService': {
      sendOtpEmail: async () => { mailCount++; return { success: delivered }; },
    },
    '../services/googleAuthService': {},
    '../services/otpService': { ...otp, verifyOtp: async () => ({ ok: true }) },
    '../services/tokenService': {},
    '../middleware/rateLimitMiddleware': limiter,
    '../services/riskScoring': { isIpBlocked: () => false },
    '../services/auditLogger': {
      logAuthEvent: noop, logBlockedIpLogin: noop, logSuspiciousOtpAttempt: noop,
      RISK_LEVELS: { INFO: 'info' },
    },
    '../utils/fieldEncryption': { encryptPhoneNumber: value => value },
    '../utils/encryptedPhoneSearch': { preparePhoneSearchParams: value => [value, value] },
    '../utils/timingProtection': {
      executeOtpRequestWithTiming: operation => operation(), otpRequestDelay: noop,
      executeOtpVerifyWithTiming: operation => operation(), otpVerifyDelay: noop,
    },
    '../utils/enumerationDetection': { detectAndLogEnumeration: async () => ({}) },
  });
  const app = express();
  app.use(express.json());
  app.use('/auth', router);
  const server = await new Promise(resolve => {
    const listener = app.listen(0, '127.0.0.1', () => resolve(listener));
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  return {
    rows, otp, limiter,
    failDelivery() { delivered = false; },
    restoreDelivery() { delivered = true; },
    get mailCount() { return mailCount; },
    async post(route, body) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/auth/${route}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      return { status: response.status, body: await response.json() };
    },
    request(email) { return this.post('request-email-otp', { email }); },
  };
}

for (const useRedis of [false, true]) {
  test(`failed email returns 503, discards its code, and permits retry (${useRedis ? 'Redis' : 'memory'})`, async t => {
    const h = await harness(t, useRedis);
    h.failDelivery();
    const failed = await h.request('recovery@example.com');
    assert.equal(failed.status, 503);
    assert.match(failed.body.error, /Unable to send/);
    assert.equal(h.rows[0].deleted, true);
    h.restoreDelivery();
    assert.equal((await h.request('recovery@example.com')).status, 200);
    assert.equal(h.rows[1].deleted, false);
    assert.equal(h.mailCount, 2);
    // A delivered code still enforces the existing no-resend window.
    const blocked = await h.request('recovery@example.com');
    assert.equal(blocked.status, 429);
    assert.match(blocked.body.message, /already active/);
    assert.equal(h.mailCount, 2);
  });

  test(`late failure cannot discard a newer code (${useRedis ? 'Redis' : 'memory'})`, async t => {
    const h = await harness(t, useRedis);
    const first = await h.otp.createOtp('recovery@example.com', 'email');
    await h.otp.createOtp('recovery@example.com', 'email');
    await h.otp.discardUndeliveredOtp('recovery@example.com', 'email', first.requestId);
    assert.equal(h.rows[1].deleted, false);
    assert.equal((await h.request('recovery@example.com')).status, 429);
    assert.equal(h.mailCount, 0);
  });
}

test('delivery failures do not bypass the existing request quota', async t => {
  const h = await harness(t);
  h.failDelivery();
  for (let attempt = 0; attempt < 3; attempt++) {
    assert.equal((await h.request('quota@example.com')).status, 503);
  }
  assert.equal((await h.request('quota@example.com')).status, 429);
  assert.equal(h.mailCount, 3);
});

for (const type of ['email', 'phone']) {
  test(`${type} recovery cannot create an account even after a valid OTP`, async t => {
    const h = await harness(t);
    const identifier = type === 'email'
      ? { email: 'unknown@example.com' }
      : { phone_number: '+919876543210' };
    const result = await h.post(type === 'email' ? 'verify-email-otp' : 'verify-otp', {
      ...identifier, code: '5678', device_id: 'test-device', recovery_only: true,
    });
    assert.equal(result.status, 400);
    assert.match(result.body.error || result.body.message, /invalid or expired/i);
  });
}

test('production without SMTP cannot report a mock email as delivered', async () => {
  const service = load('../src/services/emailService.js', {
    '../config': { isProduction: true },
  });
  const result = await service.sendOtpEmail('recovery@example.com', '5678');
  assert.equal(result.success, false);
  assert.match(result.error, /not configured/);
});

for (const outcome of ['accepted', 'rejected', 'error']) {
  test(`SMTP ${outcome} result is reported accurately`, async () => {
    const service = load('../src/services/emailService.js', {
      '../config': { isProduction: true, emailHost: 'smtp.invalid', emailUser: 'user', emailPass: 'unused' },
      nodemailer: { createTransport: () => ({
        async sendMail() {
          if (outcome === 'error') throw new Error('SMTP unavailable');
          return { accepted: outcome === 'accepted' ? ['recovery@example.com'] : [], messageId: 'test-id' };
        },
      }) },
    });
    assert.equal((await service.sendOtpEmail('recovery@example.com', '5678')).success, outcome === 'accepted');
  });
}
