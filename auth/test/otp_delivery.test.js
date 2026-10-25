const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');
const { GoogleIdentityError } = require('../src/services/googleIdentity');
const { OtpCapacityError, BUSY_CODE } = require('../src/services/otpWorkAdmission');
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
  enumerationAdmission = null, failEnumerationAdmission = false,
  googleVerificationError = null, googleResolve = null,
  otpCapacityError = false, providerBusy = false,
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
  if (enumerationAdmission) {
    limiter.checkEnumerationRateLimit = async () => enumerationAdmission;
  }
  if (failEnumerationAdmission) {
    limiter.checkEnumerationRateLimit = async () => {
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
        if (sql.startsWith('UPDATE users') && sql.includes('SET name =')) {
          return { rows: [{
            ...identityUser,
            name: args[0],
            country_code: args[1],
            created_at: identityUser?.created_at || '2026-01-01T00:00:00.000Z',
          }] };
        }
        return { rows: [] };
      }
      if (sql.includes('SELECT COUNT(*) as count FROM user_devices')) return { rows: [{ count: '1' }] };
      if (sql.includes('SELECT id FROM user_devices')) return { rows: [] };
      if (sql.includes('INSERT INTO user_devices')) return { rows: [] };
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
  if (otpCapacityError) for (const name of ['createOtp', 'createOtpV2', 'verifyOtp', 'verifyOtpV2']) otp[name] = async () => { throw new OtpCapacityError(); };
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
      sendOtpSms: async () => { smsCount++; return providerBusy ? { success: false, code: BUSY_CODE } : { success: delivered }; },
    },
    '../services/emailService': {
      sendOtpEmail: async () => { mailCount++; return providerBusy ? { success: false, code: BUSY_CODE } : { success: delivered }; },
    },
    '../services/googleAuthService': { verifyGoogleToken: async () => {
      if (googleVerificationError) throw googleVerificationError;
      return { googleId: '123456789', email: 'synthetic@gmail.com', emailVerified: true, emailAuthoritative: true };
    } },
    '../services/googleIdentity': {
      GoogleIdentityError,
      resolveGoogleAccount: async options => {
        assert.ok(googleResolve, 'Google test must explicitly provide an identity resolver');
        return googleResolve(options);
      },
    },
    '../services/accessTokenVerification': { verifyAccessToken: token => {
      if (token === 'invalid-token') throw new Error('invalid_token');
      return tokenClaims;
    } },
    '../services/currentSessionVerification': { verifyCurrentSession: async token => {
      assert.equal(token, 'synthetic-access-token');
      if (currentSessionError) throw currentSessionError;
      return currentSession;
    } },
    '../services/otpService': { ...otp, verifyOtp: async () => { if (otpCapacityError) throw new OtpCapacityError(); return verifyOtpResult; } },
    '../services/tokenService': {
      signAccessToken: () => 'synthetic-access-token',
      issueRefreshToken: async () => 'synthetic-refresh-token',
    },
    '../middleware/rateLimitMiddleware': limiter,
    '../services/riskScoring': {
      isIpBlocked: () => false,
      getPreviousAuthInfo: async () => ({}),
      calculateRiskScore: async () => ({ score: 0, reasons: [], isSuspicious: false }),
    },
    '../services/auditLogger': {
      logAuthEvent: noop, logBlockedIpLogin: noop, logSuspiciousOtpAttempt: noop,
      checkAnomalies: noop,
      RISK_LEVELS: { INFO: 'info' },
    },
    '../utils/fieldEncryption': {
      encryptPhoneNumber: value => value,
      decryptPhoneNumber: value => value,
    },
    '../utils/encryptedPhoneSearch': { preparePhoneSearchParams: value => [value], phoneLookupHash: value => value },
    '../utils/timingProtection': {
      executeOtpRequestWithTiming: operation => operation(), otpRequestDelay: noop,
      executeOtpVerifyWithTiming: operation => operation(), otpVerifyDelay: noop,
    },
    '../utils/enumerationDetection': { detectAndLogEnumeration: async () => ({}) },
  });
  const app = express();
  app.use(express.json());
  app.use('/auth/v2',require('../src/routes/versionedOtpRoutes').createVersionedOtpRouter({legacyRouter:router}));
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
      const result = { status: response.status, body: await response.json() };
      Object.defineProperties(result, { retryAfter: { value: response.headers.get('retry-after') }, cacheControl: { value: response.headers.get('cache-control') } });
      return result;
    },
    request(email, recovery_only = false) { return this.post('request-email-otp', { email, ...(recovery_only ? { recovery_only } : {}) }); },
    requestPhone(phone_number, recovery_only = false) { return this.post('request-otp', { phone_number, ...(recovery_only ? { recovery_only } : {}) }); },
  };
}

test('Google route preserves successful token/device response without requiring a legacy google_id column', async t => {
  const h = await harness(t, { googleResolve: async options => {
    assert.equal(options.googleUser.googleId, '123456789');
    assert.equal(options.linkingToken, null);
    return { user: { id: 'google-user', email: 'synthetic@gmail.com', name: 'Synthetic', role: 'user', token_version: 1 }, isNewAccount: true };
  } });
  const response = await h.post('google', { id_token: 'synthetic-google-id-token', device_id: 'google-test-device' });
  assert.equal(response.status, 200);
  assert.equal(response.body.user.id, 'google-user');
  assert.equal(response.body.access_token, 'synthetic-access-token');
  assert.equal(response.body.refresh_token, 'synthetic-refresh-token');
  assert.equal(response.body.is_new_account, true);
  assert.equal(response.body.active_devices_count, 1);
  assert.equal(h.userQueries.length, 0);
  assert.equal(h.userWrites.length, 0);
});

test('Google route returns explicit account-link error without issuing tokens', async t => {
  const h = await harness(t, { googleResolve: async () => {
    throw new GoogleIdentityError('GOOGLE_ACCOUNT_LINK_REQUIRED', 409, 'Sign in with your existing OTP account.');
  } });
  const response = await h.post('google', { id_token: 'synthetic-google-id-token', device_id: 'google-test-device' });
  assert.equal(response.status, 409);
  assert.equal(response.body.code, 'GOOGLE_ACCOUNT_LINK_REQUIRED');
  assert.equal(response.body.access_token, undefined);
});

test('Google explicit linking requires a bearer session and passes it to the checked account resolver', async t => {
  const h = await harness(t, { googleResolve: async options => {
    assert.equal(options.linkingToken, 'signed-existing-session');
    assert.equal(typeof options.verifySession, 'function');
    return { user: { id: 'existing-user', name: 'Existing', role: 'user' }, isNewAccount: false };
  } });
  const body = { id_token: 'synthetic-google-id-token', device_id: 'google-test-device', link_account: true };
  assert.equal((await h.post('google', body)).status, 401);
  const response = await h.post('google', body, 'Bearer signed-existing-session');
  assert.equal(response.status, 200);
  assert.equal(response.body.is_new_account, false);
});

for (const [code, status] of [['GOOGLE_TOKEN_INVALID', 400], ['GOOGLE_AUTH_UNAVAILABLE', 503]]) {
  test(`Google route maps ${code} to ${status} without provider details`, async t => {
    const h = await harness(t, { googleVerificationError: Object.assign(new Error('sensitive provider response'), { code }) });
    const response = await h.post('google', { id_token: 'synthetic-google-id-token', device_id: 'google-test-device' });
    assert.equal(response.status, status);
    assert.equal(response.body.code, code);
    assert.equal(JSON.stringify(response.body).includes('sensitive'), false);
  });
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

test('check-user keeps its response contract and applies shared enumeration admission', async t => {
  const phone = '+919876543210';
  const h = await harness(t, {
    phoneUser: { id: 'known-user', name: 'Known', phone_lookup_hash: phone },
  });
  const known = await h.post('check-user', { phone_number: '9876543210' });
  assert.equal(known.status, 200);
  assert.equal(known.body.user_exists, true);
  assert.deepEqual(h.userQueries.at(-1).args, [phone]);

  const limited = await harness(t, { enumerationAdmission: { allowed: false } });
  const throttled = await limited.post('check-user', { phone_number: phone });
  assert.equal(throttled.status, 429);
  assert.equal(throttled.body.success, false);
  assert.equal(limited.userQueries.length, 0);
});

test('check-user fails closed with controlled 503 when shared enumeration storage is unavailable', async t => {
  const h = await harness(t, { failEnumerationAdmission: true });
  const response = await h.post('check-user', { phone_number: '+919876543210' });
  assert.equal(response.status, 503);
  assert.equal(response.body.error, 'Authentication is temporarily unavailable. Please try again shortly.');
  assert.equal(h.userQueries.length, 0);
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

test('legacy signup address fields do not query removed locations and retain null response field', async t => {
  const h = await harness(t, { identityUser: {
    id: 'authenticated-user', phone_number: '+919876543210',
    phone_lookup_hash: '+919876543210', is_phone_verified: true,
    is_email_verified: false, country_code: '+91', name: null, role: 'user', token_version: 1,
  } });
  const response = await h.post('signup', {
    name: 'Profile Name', phone_number: '+919876543210',
    state: 'Maharashtra', district: 'Pune', city_village: 'Pune',
  }, 'Bearer existing-session');
  assert.equal(response.status, 200);
  assert.equal(response.body.success, true);
  assert.equal(response.body.location_id, null);
  assert.equal(h.userWrites.some(({ sql }) => /INSERT INTO locations/i.test(sql)), false);
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
    assert.match(messageOptions.subject, /PandaPay/);
    assert.match(messageOptions.text, /PandaPay verification code/);
    assert.match(messageOptions.html, /PandaPay Verification Code/);
    assert.doesNotMatch(JSON.stringify(messageOptions), /PandaPal/);
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


test('v2 OTP request requires stable device and returns only six-digit challenge metadata',async t=>{
  const h=await harness(t);
  const bad=await h.post('v2/request-email-otp',{email:'version2@example.com'});assert.equal(bad.status,400);
  const response=await h.post('v2/request-email-otp',{email:'version2@example.com',device_id:'device-v2'});
  assert.equal(response.status,200);assert.deepEqual(Object.keys(response.body).sort(),['challenge_id','code_length','expires_in','ok','version']);
  assert.equal(response.body.code_length,6);assert.equal(response.body.expires_in,120);assert.match(response.body.challenge_id,/^[a-f0-9-]{36}$/);
  assert.equal(h.userQueries.length,0,'request cannot expose pre-proof account state');
  assert.equal(h.mailCount,1);
  const duplicate=await h.request('version2@example.com');assert.equal(duplicate.status,429,'legacy shares the same active identifier claim');
});
test('v2 refuses contact selectors and forged protocol fields before queries or provider work',async t=>{
  const h=await harness(t);
  for(const extra of [{phone_number:'+919876543210'},{is_signup:true},{protocol_version:1},{version:2}]){
    assert.equal((await h.post('v2/request-email-otp',{email:'v2-selectors@example.com',device_id:'v2-device',...extra})).status,400);
  }
  for(const code of ['1234',123456,'1234567',' 123456'])assert.equal((await h.post('v2/verify-email-otp',{email:'v2-selectors@example.com',device_id:'v2-device',challenge_id:'00000000-0000-4000-8000-000000000001',code})).status,400);
  assert.equal(h.mailCount,0);assert.equal(h.userQueries.length,0);assert.equal(h.rows.length,0);
});
test('v2 delivery failure discards its exact challenge and permits retry with unchanged legacy response',async t=>{
  const h=await harness(t);h.failDelivery();
  assert.equal((await h.post('v2/request-email-otp',{email:'v2-failure@example.com',device_id:'v2-device'})).status,503);
  assert.equal(h.rows[0].deleted,true);h.restoreDelivery();
  assert.equal((await h.request('v2-failure@example.com')).status,200);
  const v1=await h.request('v1-unchanged@example.com');assert.deepEqual(v1.body,{ok:true});
});
test('unversioned endpoints cannot select six digits with header/body protocol claims',async t=>{
  const h=await harness(t);
  const response=await h.post('verify-email-otp',{email:'legacy@example.com',code:'123456',protocol_version:2,device_id:'v2-device',challenge_id:'00000000-0000-4000-8000-000000000001'});
  assert.equal(response.status,400);assert.match(response.body.error,/4 digits/);
});

for (const versioned of [false, true]) for (const channel of ['email', 'phone']) {
  const prefix = versioned ? 'v2/' : '', suffix = channel === 'email' ? 'email-otp' : 'otp';
  const identity = channel === 'email' ? { email: 'capacity@example.com' } : { phone_number: '+919876543210' };
  const protocol = versioned ? { device_id: 'capacity-device', challenge_id: '11111111-1111-4111-8111-111111111111' } : {};
  test(`${prefix}${channel} issuance and verification saturation return safe retryable 503 with no OTP/account writes`, async t => {
    const h = await harness(t, { otpCapacityError: true });
    const requestBody = { ...identity, ...(versioned ? { device_id: protocol.device_id } : {}) };
    const verifyBody = { ...identity, ...protocol, code: versioned ? '123456' : '5678', device_id: 'capacity-device' };
    for (const [action, body] of [[`request-${suffix}`, requestBody], [`verify-${suffix}`, verifyBody]]) {
      const response = await h.post(prefix + action, body);
      assert.equal(response.status, 503); assert.equal(response.retryAfter, '2');
      assert.equal(response.cacheControl, 'no-store'); assert.equal(response.body.code, BUSY_CODE);
      assert.equal(JSON.stringify(response.body).includes('capacity@example.com'), false);
    }
    assert.equal(h.rows.length, 0); assert.equal(h.userWrites.length, 0); assert.equal(h.mailCount + h.smsCount, 0);
  });
  test(`${prefix}${channel} provider saturation discards the issued challenge and its active marker`, async t => {
    const h = await harness(t, { providerBusy: true });
    const response = await h.post(prefix + `request-${suffix}`, { ...identity, ...(versioned ? { device_id: protocol.device_id } : {}) });
    assert.equal(response.status, 503); assert.equal(response.retryAfter, '2'); assert.equal(response.body.code, BUSY_CODE);
    assert.equal(h.rows.length, 1); assert.equal(h.rows[0].deleted, true);
    // A second attempt reaches issuance again rather than a stale OTP_ACTIVE response.
    const retry = await h.post(prefix + `request-${suffix}`, { ...identity, ...(versioned ? { device_id: protocol.device_id } : {}) });
    assert.equal(retry.status, 503); assert.equal(retry.body.code, BUSY_CODE); assert.equal(h.rows.length, 2);
  });
}
