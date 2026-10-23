const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');
const {
  RateLimitStorageError,
  RateLimitExceededError,
  ActiveOtpError,
  createMemoryRateLimitStore,
} = require('../src/services/authAbuseStore');

process.env.PHONE_LOOKUP_HMAC_KEY ||= 'test-phone-lookup-hmac-key-0123456789abcdef';
process.env.NODE_ENV = 'test';

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

async function harness(t, {
  phoneUser = null, identityUser = null, signupUpdateError = null,
  tokenClaims = { sub: 'user-1', role: 'user', user_type: null, token_version: 2, high_assurance: true },
  currentSession = { valid: true, subject: 'user-1', session: { active: true, revoked: false } },
  currentSessionError = null,
  abuseStore = null, failEnumerationStorage = false, verifyOtpResult = { ok: true },
  markActiveError = null, synchronizeActiveChecks = false,
} = {}) {
  const rows = [];
  abuseStore ||= createMemoryRateLimitStore();
  const userWrites = [];
  const userQueries = [];
  const limiter = load('../src/middleware/rateLimitMiddleware.js', {
    '../services/authAbuseStore': {
      RateLimitStorageError,
      RateLimitExceededError,
      ActiveOtpError,
      createRateLimitStore: () => abuseStore,
    },
  });
  if (markActiveError) {
    limiter.markActiveOtp = async () => {
      throw markActiveError === true ? new limiter.ActiveOtpError() : markActiveError;
    };
  }
  if (synchronizeActiveChecks) {
    const originalExists = abuseStore.exists.bind(abuseStore);
    let waiting = 0;
    let release;
    const bothChecked = new Promise(resolve => { release = resolve; });
    abuseStore.exists = async key => {
      if (!key.startsWith('otp_active:')) return originalExists(key);
      waiting++;
      if (waiting === 2) release();
      await bothChecked;
      return originalExists(key);
    };
  }
  if (failEnumerationStorage) {
    limiter.isIpBlockedForEnumeration = async () => {
      throw new RateLimitStorageError('storage_unavailable');
    };
  }
  const db = {
    async query(sql, args) {
      if (sql.includes('INSERT INTO otp_requests')) {
        const row = {
          id: args[8],
          identifier: args[3] === 'phone' ? args[0] : args[2],
          lookupHash: args[1],
          type: args[3],
          purpose: args[7],
          deleted: false,
        };
        rows.push(row);
        return { rows: [{ id: row.id }] };
      }
      if (sql.includes('UPDATE otp_requests')) {
        const purpose = ['signin', 'recovery', 'replacement'].includes(args[1]) ? args[1]
          : ['signin', 'recovery', 'replacement'].includes(args[2]) ? args[2] : null;
        for (const row of rows) {
          const matches = sql.includes('WHERE id =')
            ? row.id === args[0] && (sql.includes('AND type = $2') || row.identifier === args[1] || row.identifier === args[2] || row.lookupHash === args[1])
            : row.identifier === args[0] || row.lookupHash === args[0];
          const samePurpose = purpose === null || (purpose === 'signin'
            ? row.purpose === 'signin' || row.purpose === null
            : row.purpose === purpose);
          if (matches && samePurpose) {
            row.deleted = true;
          }
        }
        return { rows: [] };
      }
      if (sql.includes('FROM users')) {
        userQueries.push({ sql, args });
        if (sql.includes('WHERE lower(email) = $1')) return { rows: [] };
        if (identityUser && sql.includes('WHERE id = $1')) {
          return { rows: identityUser.id === args[0] ? [{ ...identityUser }] : [] };
        }
        if (phoneUser && sql.includes('phone_lookup_hash = $2')) {
          return { rows: phoneUser.phone_lookup_hash === args[1] ? [{ ...phoneUser }] : [] };
        }
        if (phoneUser && sql.includes('WHERE phone_lookup_hash = $1')) {
          return { rows: phoneUser.phone_lookup_hash === args[0] ? [{ ...phoneUser }] : [] };
        }
        return { rows: [] };
      }
      if (sql.startsWith('UPDATE users') || sql.startsWith('INSERT INTO users')) {
        if (sql.startsWith('UPDATE users') && signupUpdateError) throw signupUpdateError;
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
    '../services/accessTokenVerification': { verifyAccessToken: token => {
      if (token === 'invalid-token') throw new Error('invalid_token');
      return tokenClaims;
    } },
    '../services/currentSessionVerification': { verifyCurrentSession: async token => {
      assert.equal(token, 'synthetic-access-token');
      if (currentSessionError) throw currentSessionError;
      return currentSession;
    } },
    '../services/otpService': { ...otp, verifyOtp: async () => verifyOtpResult },
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
    rows, otp, limiter, abuseStore, userWrites, userQueries,
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

test('failed email returns 503, discards its code, and permits retry', async t => {
    const h = await harness(t);
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

test('late failure cannot discard a newer code', async t => {
    const h = await harness(t);
    const first = await h.otp.createOtp('recovery@example.com', 'email');
  await h.limiter.clearActiveOtp('recovery@example.com', first.requestId, 'signin');
    await h.otp.createOtp('recovery@example.com', 'email');
    await h.otp.discardUndeliveredOtp('recovery@example.com', 'email', first.requestId);
    assert.equal(h.rows[1].deleted, false);
    assert.equal((await h.request('recovery@example.com')).status, 429);
    assert.equal(h.mailCount, 0);
});

test('delivery failures do not bypass the existing request quota', async t => {
  const h = await harness(t);
  h.failDelivery();
  for (let attempt = 0; attempt < 3; attempt++) {
    assert.equal((await h.request('quota@example.com')).status, 503);
  }
  assert.equal((await h.request('quota@example.com')).status, 429);
  assert.equal(h.mailCount, 3);
});

test('abuse-store active-claim failures happen before OTP writes and never call providers', async t => {
  for (const channel of ['phone', 'email']) {
    const abuseStore = createMemoryRateLimitStore();
    abuseStore.claimMarker = async () => { throw new RateLimitStorageError('storage_unavailable'); };
    const h = await harness(t, { abuseStore });
    const response = channel === 'phone'
      ? await h.requestPhone('+919876543210')
      : await h.request('outage@example.com');
    assert.equal(response.status, 503);
    assert.match(response.body.error, /temporarily unavailable/);
    assert.equal(h.rows.length, 0);
    assert.equal(h.smsCount, 0);
    assert.equal(h.mailCount, 0);
  }
});

test('a losing active OTP claim returns 429 without changing OTP rows or sending', async t => {
  const h = await harness(t, { markActiveError: true });
  const response = await h.request('claim@example.com');
  assert.equal(response.status, 429);
  assert.equal(h.rows.length, 0);
  assert.equal(h.mailCount, 0);
  assert.equal(h.smsCount, 0);
});

test('concurrent requests for one identifier create and deliver only one OTP', async t => {
  const h = await harness(t, { synchronizeActiveChecks: true });
  const results = await Promise.all([
    h.request('concurrent@example.com'),
    h.request('concurrent@example.com'),
  ]);
  assert.deepEqual(results.map(result => result.status).sort(), [200, 429]);
  assert.equal(h.mailCount, 1);
  assert.equal(h.rows.length, 1);
  assert.equal(h.rows.filter(row => !row.deleted).length, 1);
});

test('enumeration storage outage inside request handler returns controlled 503', async t => {
  const h = await harness(t, { failEnumerationStorage: true });
  for (const response of [
    await h.request('outage@example.com'),
    await h.requestPhone('+919876543210'),
  ]) {
    assert.equal(response.status, 503);
    assert.match(response.body.error, /temporarily unavailable/);
  }
  assert.equal(h.mailCount, 0);
  assert.equal(h.smsCount, 0);
});

test('failed verification counter storage outage returns controlled 503', async t => {
  const abuseStore = createMemoryRateLimitStore();
  const increment = abuseStore.increment.bind(abuseStore);
  abuseStore.increment = async (key, ttl, saturation) => {
    if (key.startsWith('otp_verify_failed:')) throw new RateLimitStorageError('storage_unavailable');
    return increment(key, ttl, saturation);
  };
  const h = await harness(t, { abuseStore, verifyOtpResult: { ok: false, reason: 'invalid' } });
  const response = await h.post('verify-email-otp', { email: 'verify@example.com', code: '0000' });
  assert.equal(response.status, 503);
  assert.match(response.body.error, /temporarily unavailable/);
  assert.deepEqual(h.userWrites, []);
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

test('email signup contact preflight ignores soft-deleted identities and compares normalized email', async t => {
  const h = await harness(t);
  const response = await h.post('request-email-otp', {
    email: '  User@Example.com  ', phone_number: '+919876543210', is_signup: true,
  });
  assert.equal(response.status, 200);
  const lookup = h.userQueries.find(({ sql }) => sql.includes('phone_lookup_hash = $2'));
  assert.ok(lookup);
  assert.match(lookup.sql, /deleted\s*=\s*FALSE/i);
  assert.deepEqual(lookup.args, ['user@example.com', '+919876543210']);
});

test('legacy validate-token preserves the active-user payload after authoritative session verification', async t => {
  const h = await harness(t);
  const response = await h.post('validate-token', { token: 'synthetic-access-token' });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body, {
    valid: true,
    payload: {
      sub: 'user-1', role: 'user', user_type: null,
      token_version: 2, high_assurance: true, is_guest: false,
    },
  });
});

test('legacy validate-token rejects guest and inactive, deleted, revoked, wrong-device sessions', async t => {
  const cases = [
    { name: 'guest token', tokenClaims: { sub: 'guest-1', is_guest: true }, currentSession: { valid: true, subject: 'guest-1', guest: true, session: { active: true, revoked: false } } },
    { name: 'inactive account', currentSession: { valid: false, subject: 'user-1', session: { active: false, revoked: true, revocation: 'account_inactive' } } },
    { name: 'deleted account', currentSession: { valid: false, subject: 'user-1', session: { active: false, revoked: true, revocation: 'account_deleted' } } },
    { name: 'revoked token', currentSession: { valid: false, subject: 'user-1', session: { active: false, revoked: true, revocation: 'token_version_changed' } } },
    { name: 'wrong device', currentSession: { valid: false, subject: 'user-1', session: { active: false, revoked: true, revocation: 'device_inactive' } } },
    { name: 'subject mismatch', currentSession: { valid: true, subject: 'another-user', session: { active: true, revoked: false } } },
  ];
  for (const item of cases) {
    const h = await harness(t, item);
    const response = await h.post('validate-token', { token: 'synthetic-access-token' });
    assert.equal(response.status, 200, item.name);
    assert.deepEqual(response.body, { valid: false, error: 'Invalid or expired token' }, item.name);
  }
});

test('legacy validate-token distinguishes invalid credentials from unavailable session storage', async t => {
  const invalid = await harness(t);
  assert.deepEqual(await invalid.post('validate-token', { token: 'invalid-token' }), {
    status: 200, body: { valid: false, error: 'Invalid or expired token' },
  });
  assert.deepEqual(await invalid.post('validate-token', {}), {
    status: 400, body: { valid: false, error: 'Token is required' },
  });

  const unavailable = await harness(t, {
    currentSessionError: Object.assign(new Error('database message must not be returned'), { code: '08006' }),
  });
  const response = await unavailable.post('validate-token', { token: 'synthetic-access-token' });
  assert.equal(response.status, 503);
  assert.deepEqual(response.body, {
    valid: false, error: 'Session verification is temporarily unavailable',
  });
});

test('email and phone conflict preflight normalizes a stored email before comparison', async t => {
  const h = await harness(t, { phoneUser: {
    id: 'phone-owner', phone_number: 'encrypted-phone', phone_lookup_hash: '+919876543210',
    email: ' User@Example.com ', is_phone_verified: true, is_email_verified: true,
  } });
  const response = await h.post('request-email-otp', {
    email: 'user@example.com', phone_number: '+919876543210',
  });
  assert.equal(response.status, 200);
});

test('same identifier keeps separate durable purpose challenges and same-purpose resend replaces only its own', async t => {
  const h = await harness(t);
  const signin1 = await h.otp.createOtp('purpose@example.com', 'email', 'signin');
  const recovery = await h.otp.createOtp('purpose@example.com', 'email', 'recovery');
  await h.limiter.clearActiveOtp('purpose@example.com', signin1.requestId, 'signin');
  const signin2 = await h.otp.createOtp('purpose@example.com', 'email', 'signin');
  const rows = [...h.rows];
  assert.deepEqual(rows.map(row => [row.id, row.purpose, row.deleted]), [
    [signin1.requestId, 'signin', true],
    [recovery.requestId, 'recovery', false],
    [signin2.requestId, 'signin', false],
  ]);
});

test('delivery cleanup is scoped to the request purpose', async t => {
  const h = await harness(t);
  const signin = await h.otp.createOtp('purpose@example.com', 'email', 'signin');
  const recovery = await h.otp.createOtp('purpose@example.com', 'email', 'recovery');
  await h.otp.discardUndeliveredOtp('purpose@example.com', 'email', signin.requestId, 'recovery');
  assert.equal(h.rows.find(row => row.id === signin.requestId).deleted, false);
  await h.otp.discardUndeliveredOtp('purpose@example.com', 'email', recovery.requestId, 'recovery');
  assert.equal(h.rows.find(row => row.id === recovery.requestId).deleted, true);
});

test('email OTP cannot attach an unverified phone to an existing phone account', async t => {
  const phone = '+919876543210';
  const owner = {
    id: 'phone-owner', phone_number: `enc:${phone}`, phone_lookup_hash: phone,
    email: null, is_phone_verified: true, is_email_verified: false,
    name: null, role: 'user', token_version: 1,
  };
  const h = await harness(t, { phoneUser: owner });
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
  assert.match(signupSource, /\r?\n\s*auth,\r?\n\s*validateSignupBody/);
  assert.doesNotMatch(signupSource, /INSERT INTO users/i);
  const legacyValidation = routeSource.slice(routeSource.indexOf("router.post('/validate-token'"));
  assert.doesNotMatch(legacyValidation, /phone_number:\s*payload\.phone_number/);
});

test('signup cannot replace the verified phone factor with a body-supplied number', async t => {
  const originalPhone = '+919876543210';
  const h = await harness(t, { identityUser: {
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

test('signup constraint errors keep status and shape without returning database details', async t => {
  const sensitiveDetail = 'duplicate key for phone +919876543210 token=secret-token-value';
  const h = await harness(t, {
    identityUser: {
      id: 'authenticated-user', phone_number: 'enc:+919876543210',
      phone_lookup_hash: '+919876543210', is_phone_verified: true,
      is_email_verified: false, country_code: '+91', name: null, role: 'user', token_version: 1,
    },
    signupUpdateError: Object.assign(new Error(sensitiveDetail), {
      code: '23505', constraint: 'users_secondary_identity_key', detail: sensitiveDetail,
    }),
  });
  const response = await h.post('signup', {
    name: 'Profile Name', phone_number: '+919876543210',
  }, 'Bearer existing-session');
  assert.equal(response.status, 400);
  assert.deepEqual(Object.keys(response.body).sort(), ['message', 'success']);
  assert.equal(response.body.success, false);
  assert.equal(response.body.message, 'Unable to complete signup. Please try again.');
  assert.doesNotMatch(JSON.stringify(response.body), /919876543210|secret-token-value|duplicate key/i);
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

test('SMTP error details are not returned from email delivery', async () => {
  const service = load('../src/services/emailService.js', {
    '../config': { isProduction: true, emailHost: 'smtp.invalid', emailUser: 'user', emailPass: 'unused' },
    nodemailer: { createTransport: () => ({
      async sendMail() { throw new Error('contact secret-token SMTP diagnostic'); },
    }) },
  });
  const result = await service.sendOtpEmail('recovery@example.com', '5678');
  assert.deepEqual(result, { success: false, error: 'Email delivery failed' });
});

for (const port of [465, 587]) {
  test(`hosted SMTP port ${port} keeps certificate validation and the appropriate TLS mode`, async () => {
    let transportOptions;
    let messageOptions;
    const service = load('../src/services/emailService.js', {
      '../config': {
        isProduction: true, emailHost: 'smtp.example.test', emailPort: String(port),
        emailUser: 'user', emailPass: 'unused',
      },
      nodemailer: { createTransport: options => {
        transportOptions = options;
        return { async sendMail(options) {
          messageOptions = options;
          return { accepted: ['recovery@example.com'], messageId: 'test-id' };
        } };
      } },
    });
    assert.equal(transportOptions.secure, port === 465);
    assert.equal(transportOptions.requireTLS, port === 587);
    assert.equal(transportOptions.tls.rejectUnauthorized, true);
    assert.equal(transportOptions.tls.servername, 'smtp.example.test');
    assert.equal(transportOptions.connectionTimeout, 10000);
    assert.equal(transportOptions.greetingTimeout, 10000);
    assert.equal(transportOptions.socketTimeout, 15000);
    assert.equal((await service.sendOtpEmail('recovery@example.com', '5678')).success, true);
    assert.equal(messageOptions.disableFileAccess, true);
    assert.equal(messageOptions.disableUrlAccess, true);
    assert.ok(service);
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
