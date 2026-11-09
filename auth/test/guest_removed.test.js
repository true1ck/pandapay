const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');
const jwt = require('jsonwebtoken');

process.env.PHONE_LOOKUP_HMAC_KEY ||= 'test-phone-lookup-hmac-key-0123456789abcdef';
process.env.NODE_ENV = 'test';
process.env.JWT_ACCESS_SECRET ||= 'test-access-secret-0123456789abcdef0123456789';
process.env.JWT_REFRESH_SECRET ||= 'test-refresh-secret-0123456789abcdef0123456789';

// Load the real route file with isolated storage and token doubles.
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

async function harness(t, { user = null } = {}) {
  const noop = async () => {};
  const calls = { revoked: [], queries: [], accessIssued: 0, rotated: 0 };
  const db = {
    async query(sql, args) {
      calls.queries.push({ sql, args });
      if (sql.includes('FROM users u')) return { rows: user ? [{ ...user }] : [] };
      if (sql.includes('FROM auth_audit')) return { rows: [] };
      if (sql.startsWith('UPDATE user_devices')) return { rows: [] };
      throw new Error(`Unexpected database operation: ${sql.slice(0, 60)}`);
    },
  };
  const router = load('../src/routes/authRoutes.js', {
    '../db': db,
    '../config': { isProduction: true, enableEmailOtp: true, enablePhoneOtp: true },
    '../middleware/authMiddleware': (req, res, next) => next(),
    // Everything below is stubbed so no timers, sockets or providers start.
    '../services/smsService': { sendOtpSms: async () => ({ success: true }) },
    '../services/emailService': { sendOtpEmail: async () => ({ success: true }) },
    '../services/googleAuthService': { verifyGoogleToken: async () => null },
    '../services/googleIdentity': { GoogleIdentityError: class extends Error {}, resolveGoogleAccount: async () => { throw new Error('unused'); } },
    '../services/accessTokenVerification': { verifyAccessToken: () => { throw new Error('invalid_token'); } },
    '../services/currentSessionVerification': { verifyCurrentSession: async () => { throw new Error('invalid_token'); } },
    '../services/otpService': {
      createOtp: async () => ({}), verifyOtp: async () => ({ ok: false }), discardUndeliveredOtp: async () => {},
      createOtpV2: async () => ({}), verifyOtpV2: async () => ({ ok: false }), discardUndeliveredOtpV2: async () => {},
    },
    '../middleware/rateLimitMiddleware': {
      checkActiveOtpForPhone: (req, res, next) => next(), rateLimitRequestOtpByPhone: (req, res, next) => next(),
      checkActiveOtpForEmail: (req, res, next) => next(), rateLimitRequestOtpByEmail: (req, res, next) => next(),
      rateLimitRequestOtpByIp: (req, res, next) => next(), rateLimitVerifyOtpByPhone: (req, res, next) => next(),
      rateLimitVerifyOtpByEmail: (req, res, next) => next(), incrementFailedVerify: noop,
      checkEnumerationRateLimit: async () => ({ allowed: true }), blockIpForEnumeration: noop,
      isIpBlockedForEnumeration: async () => false, RateLimitStorageError: class extends Error {}, ActiveOtpError: class extends Error {},
    },
    '../utils/fieldEncryption': { encryptPhoneNumber: v => v, decryptPhoneNumber: v => v },
    '../utils/encryptedPhoneSearch': { preparePhoneSearchParams: v => [v], phoneLookupHash: v => v },
    '../utils/timingProtection': {
      executeOtpRequestWithTiming: op => op(), otpRequestDelay: noop,
      executeOtpVerifyWithTiming: op => op(), otpVerifyDelay: noop,
    },
    '../utils/enumerationDetection': { detectAndLogEnumeration: async () => ({}) },
    '../services/tokenService': {
      signAccessToken: () => { calls.accessIssued++; return 'new-access-token'; },
      issueRefreshToken: async () => 'unused',
      verifyRefreshToken: async () => ({
        userId: 'user-1', deviceId: 'device-1', row: { ip_address: null, user_agent: null },
      }),
      rotateRefreshToken: async () => { calls.rotated++; return 'new-refresh-token'; },
      revokeRefreshToken: async (userId, deviceId) => { calls.revoked.push([userId, deviceId]); },
    },
    '../services/riskScoring': {
      isIpBlocked: () => false,
      getPreviousAuthInfo: async () => ({}),
      calculateRiskScore: async () => ({ score: 0, reasons: [], isSuspicious: false }),
    },
    '../services/auditLogger': {
      logAuthEvent: noop, logBlockedIpLogin: noop, logSuspiciousOtpAttempt: noop,
      logSuspiciousRefresh: noop, checkAnomalies: noop, RISK_LEVELS: { INFO: 'info' },
    },
  });
  const app = express();
  app.use(express.json());
  app.use('/auth', router);
  const server = await new Promise(resolve => {
    const listener = app.listen(0, '127.0.0.1', () => resolve(listener));
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  return {
    calls,
    async post(route, body) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/auth/${route}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      let parsed = null;
      try { parsed = await response.json(); } catch (_) { /* HTML 404 body */ }
      return { status: response.status, body: parsed };
    },
  };
}

test('guest sign-in no longer exists', async t => {
  const h = await harness(t);
  for (const body of [{}, { device_id: 'some-device-1234' }]) {
    const response = await h.post('guest-login', body);
    assert.equal(response.status, 404);
  }
  assert.equal(h.calls.accessIssued, 0);
});

test('refresh continues a live account on a signed-in device', async t => {
  const h = await harness(t, { user: { id: 'user-1', phone_number: null, name: 'A', role: 'user', token_version: 1 } });
  const response = await h.post('refresh', { refresh_token: 'any-refresh-token' });
  assert.equal(response.status, 200);
  assert.equal(response.body.access_token, 'new-access-token');
  assert.equal(response.body.refresh_token, 'new-refresh-token');
  assert.deepEqual(h.calls.revoked, []);
});

test('refresh refuses a missing, deleted or disabled account and a signed-out device, and revokes the device chain', async t => {
  // The account query itself requires deleted = FALSE, is_active = TRUE and an
  // active device row, so any of those failing returns no row.
  const h = await harness(t, { user: null });
  const response = await h.post('refresh', { refresh_token: 'any-refresh-token' });
  assert.equal(response.status, 401);
  assert.equal(response.body.access_token, undefined);
  assert.equal(h.calls.accessIssued, 0);
  assert.equal(h.calls.rotated, 0);
  assert.deepEqual(h.calls.revoked, [['user-1', 'device-1']]);
  const sql = h.calls.queries.find(q => q.sql.includes('FROM users u')).sql;
  assert.match(sql, /u\.deleted = FALSE/);
  assert.match(sql, /u\.is_active = TRUE/);
  assert.match(sql, /d\.is_active = TRUE/);
});

test('a leftover guest access token is rejected by the shared verifier', () => {
  const { verifyAccessToken } = require('../src/services/accessTokenVerification');
  const { getActiveKey, getIssuer, getAudience } = require('../src/services/jwtKeys');
  const key = getActiveKey();
  const sign = claims => jwt.sign(claims, key.secret, {
    algorithm: 'HS256', expiresIn: '5m', issuer: getIssuer(), audience: getAudience(), keyid: key.keyId,
  });
  assert.equal(verifyAccessToken(sign({ sub: 'user-1', is_guest: false })).sub, 'user-1');
  assert.throws(() => verifyAccessToken(sign({ sub: 'guest-1', is_guest: true })), /invalid_token/);
});
