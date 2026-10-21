const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');

process.env.PHONE_LOOKUP_HMAC_KEY ||= 'test-phone-lookup-hmac-key-0123456789abcdef';

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

async function harness(t, useRedis = false, { phoneUser = null, identityUser = null } = {}) {
  const rows = [];
  const keys = new Map();
  const userWrites = [];
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
        const row = {
          id: String(rows.length + 1),
          identifier: args[3] === 'phone' ? args[0] : args[2],
          lookupHash: args[1],
          type: args[3],
          deleted: false,
        };
        rows.push(row);
        return { rows: [{ id: row.id }] };
      }
      if (sql.includes('UPDATE otp_requests')) {
        for (const row of rows) {
          const matches = sql.includes('WHERE id =')
            ? row.id === args[0] && (row.identifier === args[1] || row.identifier === args[2] || row.lookupHash === args[1])
            : row.identifier === args[0] || row.lookupHash === args[0];
          if (matches) {
            row.deleted = true;
          }
        }
        return { rows: [] };
      }
      if (sql.includes('FROM users')) {
        if (sql.includes('WHERE lower(email) = $1')) return { rows: [] };
        if (identityUser && sql.includes('WHERE id = $1')) {
          return { rows: identityUser.id === args[0] ? [{ ...identityUser }] : [] };
        }
        if (phoneUser && sql.includes('WHERE phone_lookup_hash = $1')) {
          return { rows: phoneUser.phone_lookup_hash === args[0] ? [{ ...phoneUser }] : [] };
        }
        return { rows: [] };
      }
      if (sql.startsWith('UPDATE users') || sql.startsWith('INSERT INTO users')) {
        userWrites.push({ sql, args });
        return { rows: [] };
      }
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
  let smsCount = 0;
  const noop = async () => {};
  const router = load('../src/routes/authRoutes.js', {
    '../db': db,
    '../config': config,
    '../middleware/authMiddleware': (req, res, next) => {
      if (req.path === '/signup' && !req.headers.authorization) {
        return res.status(401).json({ error: 'Missing Authorization header' });
      }
      req.user = { id: 'authenticated-user' };
      return next();
    },
    '../services/smsService': {
      sendOtpSms: async () => { smsCount++; return { success: delivered }; },
    },
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
    '../utils/encryptedPhoneSearch': { preparePhoneSearchParams: value => [value], phoneLookupHash: value => value },
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
    rows, otp, limiter, userWrites,
    failDelivery() { delivered = false; },
    restoreDelivery() { delivered = true; },
    get mailCount() { return mailCount; },
    get smsCount() { return smsCount; },
    async post(route, body, authorization) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/auth/${route}`, {
        method: 'POST', headers: {
          'Content-Type': 'application/json', ...(authorization ? { Authorization: authorization } : {}),
        }, body: JSON.stringify(body),
      });
      return { status: response.status, body: await response.json() };
    },
    request(email, recovery_only = false) { return this.post('request-email-otp', { email, ...(recovery_only ? { recovery_only } : {}) }); },
    requestPhone(phone_number, recovery_only = false) { return this.post('request-otp', { phone_number, ...(recovery_only ? { recovery_only } : {}) }); },
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

test('recovery and normal sign-in have independent OTP resend windows', async t => {
  const h = await harness(t);
  assert.equal((await h.request('recovery@example.com', true)).status, 200);
  assert.equal((await h.request('recovery@example.com')).status, 200);
  assert.equal(h.mailCount, 2);
  assert.equal((await h.request('recovery@example.com', true)).status, 429);
  assert.equal((await h.request('recovery@example.com')).status, 429);
  assert.equal(h.mailCount, 2);
});

test('email OTP cannot attach an unverified phone to an existing phone account', async t => {
  const phone = '+919876543210';
  const owner = {
    id: 'phone-owner', phone_number: `enc:${phone}`, phone_lookup_hash: phone,
    email: null, is_phone_verified: true, is_email_verified: false,
    name: null, role: 'user', token_version: 1,
  };
  const h = await harness(t, false, { phoneUser: owner });
  const response = await h.post('verify-email-otp', {
    email: 'new@example.com', phone_number: phone, code: '1234', device_id: 'device-a',
  });
  assert.equal(response.status, 400);
  assert.deepEqual(h.userWrites, []);
});

test('signup cannot create an account without an authenticated OTP session', async t => {
  const h = await harness(t);
  const response = await h.post('signup', { name: 'New User', phone_number: '+919876543210' });
  assert.equal(response.status, 401);
  assert.deepEqual(h.userWrites, []);
  const routeSource = fs.readFileSync(path.resolve(__dirname, '../src/routes/authRoutes.js'), 'utf8');
  const signupSource = routeSource.slice(routeSource.indexOf("  '/signup',"), routeSource.indexOf("// POST /auth/validate-token"));
  assert.match(signupSource, /\n\s*auth,\n\s*validateSignupBody/);
  assert.doesNotMatch(signupSource, /INSERT INTO users/i);
  const legacyValidation = routeSource.slice(routeSource.indexOf("router.post('/validate-token'"));
  assert.doesNotMatch(legacyValidation, /phone_number:\s*payload\.phone_number/);
});

test('signup cannot replace the verified phone factor with a body-supplied number', async t => {
  const originalPhone = '+919876543210';
  const h = await harness(t, false, { identityUser: {
    id: 'authenticated-user', phone_number: `enc:${originalPhone}`,
    phone_lookup_hash: originalPhone, is_phone_verified: true,
    is_email_verified: false, country_code: '+91', name: null, role: 'user', token_version: 1,
  } });
  const response = await h.post('signup', {
    name: 'Profile Name', phone_number: '+919999998888',
  }, 'Bearer existing-session');
  assert.equal(response.status, 409);
  assert.equal(response.body.code, 'existing_factor_required');
  assert.deepEqual(h.userWrites, []);
});

test('failed SMS returns an error, discards the code, and allows retry', async t => {
  const h = await harness(t);
  h.failDelivery();
  const failed = await h.requestPhone('+919876543210');
  assert.equal(failed.status, 503);
  assert.match(failed.body.error, /Unable to send a sign-in code/);
  assert.equal(h.rows[0].deleted, true);
  h.restoreDelivery();
  assert.equal((await h.requestPhone('+919876543210')).status, 200);
  assert.equal(h.rows[1].deleted, false);
  assert.equal(h.smsCount, 2);
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

test('email delivery logs neither the full address nor the OTP value', async () => {
  const service = load('../src/services/emailService.js', {
    '../config': { isProduction: true, emailHost: 'smtp.invalid', emailUser: 'user', emailPass: 'unused' },
    nodemailer: { createTransport: () => ({
      async sendMail() { return { accepted: ['recovery@example.com'], messageId: 'test-id' }; },
    }) },
  });
  const original = { log: console.log, warn: console.warn, error: console.error };
  const output = [];
  console.log = (...args) => output.push(args.join(' '));
  console.warn = (...args) => output.push(args.join(' '));
  console.error = (...args) => output.push(args.join(' '));
  try {
    assert.equal((await service.sendOtpEmail('recovery@example.com', '4826')).success, true);
  } finally {
    console.log = original.log; console.warn = original.warn; console.error = original.error;
  }
  assert.equal(output.some(line => line.includes('recovery@example.com')), false);
  assert.equal(output.some(line => line.includes('4826')), false);
});
