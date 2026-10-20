// Read-only reproductions against current source using synthetic data and mocks.
// A PASS means the described audit condition was reproduced, not that it is safe.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const root = path.resolve(__dirname, '../..');
const jwt = require(path.join(root, 'api/node_modules/jsonwebtoken'));
const quiet = { log() {}, warn() {}, error() {} };
const originalConsole = global.console;
const results = [];
const noop = async () => {};
const next = (_req, _res, callback) => callback();
const subject = '00000000-0000-4000-8000-000000000001';
const syntheticPhone = '+15555550101';
const secret = 'audit-only-secret-not-used-by-any-service';

function load(relative, dependencies = {}) {
  const filename = path.join(root, relative);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request)
    ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

function response() {
  return { statusCode: 200, body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; }, end() { return this; } };
}

function authHarness(user = null) {
  const registered = new Map();
  const state = { user, signedSubject: null, otpCalls: [], emailLinked: false, queryCount: 0 };
  const fakeRouter = { post(route, ...handlers) { registered.set(route, handlers); } };
  const db = { async query(sql, values = []) {
    state.queryCount++;
    if (sql.includes('SELECT COUNT(*)')) return { rows: [{ count: '1' }] };
    if (/SELECT .*FROM users/s.test(sql)) {
      if (sql.includes('WHERE email =')) return { rows: [] };
      return { rows: state.user ? [state.user] : [] };
    }
    if (sql.includes('UPDATE users') && sql.includes('RETURNING')) {
      state.user = { ...state.user, name: values[0] };
      return { rows: [state.user] };
    }
    if (sql.includes('UPDATE users') && sql.includes('email = $2')) state.emailLinked = true;
    if (sql.includes('INSERT INTO users')) {
      state.user = { id: subject, phone_number: syntheticPhone, name: 'Synthetic', role: 'user', token_version: 1 };
      return { rows: [state.user] };
    }
    return { rows: [] };
  } };
  const tokenService = {
    signAccessToken(user, options = {}) {
      state.signedSubject = user.id;
      return jwt.sign({ sub: user.id, role: user.role, is_guest: user.is_guest === true,
        token_version: 1, high_assurance: options.highAssurance === true }, secret,
      { issuer: 'pandapay-auth', audience: 'mobile-app', expiresIn: options.expiresIn || '15m', keyid: 'audit' });
    },
    issueRefreshToken: async () => 'synthetic-refresh-placeholder',
  };
  load('auth/src/routes/authRoutes.js', {
    express: { Router: () => fakeRouter }, '../db': db,
    '../config': { isProduction: true, enablePhoneOtp: false, enableEmailOtp: true },
    '../middleware/authMiddleware': next,
    '../services/smsService': { sendOtpSms: async () => ({ success: true }) },
    '../services/emailService': { sendOtpEmail: async () => ({ success: true }) },
    '../services/googleAuthService': {},
    '../services/otpService': {
      createOtp: async () => ({ code: '4826', requestId: 'synthetic' }),
      verifyOtp: async (...args) => { state.otpCalls.push(args); return { ok: true }; },
      discardUndeliveredOtp: noop,
    },
    '../utils/testOtp': { isTestOtpIdentifier: () => false },
    '../services/tokenService': tokenService,
    '../middleware/rateLimitMiddleware': new Proxy({}, { get: (_target, key) => {
      if (key === 'isIpBlockedForEnumeration') return async () => false;
      if (key === 'checkEnumerationRateLimit') return async () => ({ allowed: true });
      if (key.startsWith('increment') || key.startsWith('block')) return noop;
      return next;
    } }),
    '../services/riskScoring': { isIpBlocked: () => false,
      getPreviousAuthInfo: async () => ({}), calculateRiskScore: async () => ({ score: 0, reasons: [], isSuspicious: false }) },
    '../services/auditLogger': new Proxy({ RISK_LEVELS: { INFO: 'INFO' } }, { get: (target, key) => target[key] || noop }),
    '../utils/fieldEncryption': { encryptPhoneNumber: value => value, decryptPhoneNumber: value => value },
    '../utils/encryptedPhoneSearch': { preparePhoneSearchParams: value => [value, value] },
    '../utils/timingProtection': { executeOtpRequestWithTiming: operation => operation(),
      executeOtpVerifyWithTiming: operation => operation(), otpRequestDelay: noop, otpVerifyDelay: noop },
    '../utils/enumerationDetection': { detectAndLogEnumeration: async () => ({}) },
  });
  return { state, async post(route, body) {
    const req = { body, ip: '192.0.2.1', connection: {}, headers: {}, get() {} };
    const res = response();
    const handlers = registered.get(route);
    for (let i = 0; i < handlers.length; i++) {
      let proceed = false;
      await handlers[i](req, res, () => { proceed = true; });
      if (!proceed) break;
    }
    return res;
  } };
}

const apiConfig = { jwtKeys: { audit: secret }, jwtIssuer: 'pandapay-auth', jwtAudience: 'mobile-app' };
const apiAuth = load('api/src/auth.js', { './config': apiConfig });
function apiAccepts(token) {
  const req = { headers: { authorization: `Bearer ${token}` } };
  const res = response();
  let accepted = false;
  apiAuth.optionalAuth(req, res, () => {});
  apiAuth.requireAuth(req, res, () => { accepted = true; });
  return accepted;
}

async function probe(name, work) {
  try { await work(); results.push({ name, reproduced: true }); }
  catch (error) { results.push({ name, reproduced: false, error: error.message }); }
}

(async () => {
  global.console = quiet;
  await probe('Email OTP for a new email can authenticate a legacy phone-only account without phone OTP', async () => {
    const h = authHarness({ id: subject, email: null, phone_number: syntheticPhone, name: 'Victim fixture', role: 'user', token_version: 1 });
    const request = await h.post('/request-email-otp', { email: 'audit-attacker@example.invalid' });
    assert.equal(request.statusCode, 200);
    const verified = await h.post('/verify-email-otp', { email: 'audit-attacker@example.invalid', phone_number: syntheticPhone, code: '4826', device_id: 'audit-device' });
    assert.equal(verified.statusCode, 200);
    assert.equal(h.state.signedSubject, subject);
    assert.equal(h.state.emailLinked, true);
    assert.equal(h.state.otpCalls.length, 1);
    assert.equal(h.state.otpCalls[0][2], 'email');
  });
  await probe('Public signup authenticates an incomplete account without OTP even when phone OTP is disabled', async () => {
    const h = authHarness({ id: subject, email: null, phone_number: syntheticPhone, name: null, role: 'user', token_version: 1 });
    const res = await h.post('/signup', { name: 'Synthetic profile', phone_number: syntheticPhone, device_id: 'audit-device' });
    assert.equal(res.statusCode, 200);
    assert.equal(h.state.signedSubject, subject);
    assert.equal(h.state.otpCalls.length, 0);
  });
  await probe('Random-IV encrypted phone cannot match the equality lookup parameters', async () => {
    process.env.ENCRYPTION_ENABLED = 'true';
    process.env.ENCRYPTION_KEY = Buffer.alloc(32, 7).toString('base64');
    const fields = load('auth/src/utils/fieldEncryption.js');
    const search = load('auth/src/utils/encryptedPhoneSearch.js', { './fieldEncryption': fields });
    const stored = fields.encryptPhoneNumber(syntheticPhone);
    const candidates = search.preparePhoneSearchParams(syntheticPhone);
    assert.equal(fields.decryptPhoneNumber(stored), syntheticPhone);
    assert(!candidates.includes(stored));
  });
  await probe('A token revoked by auth token_version checks is still accepted by the product API guard', async () => {
    const token = jwt.sign({ sub: subject, token_version: 1 }, secret,
      { issuer: 'pandapay-auth', audience: 'mobile-app', expiresIn: '15m', keyid: 'audit' });
    const authGuard = load('auth/src/middleware/authMiddleware.js', {
      '../services/jwtKeys': { getKeySecret: () => secret, getAllKeys: () => ({ audit: secret }),
        getIssuer: () => 'pandapay-auth', getAudience: () => 'mobile-app', validateTokenClaims: () => ({ valid: true }) },
      '../db': { query: async () => ({ rows: [{ token_version: 2 }] }) },
    });
    const res = response();
    await authGuard({ headers: { authorization: `Bearer ${token}` } }, res, () => assert.fail('revoked auth token accepted'));
    assert.equal(res.statusCode, 401);
    assert.equal(apiAccepts(token), true);
  });
  await probe('Public guest-login can mint a JWT accepted by private product API guards', async () => {
    const h = authHarness();
    const res = await h.post('/guest-login', { device_id: 'audit-device' });
    assert.equal(res.statusCode, 200);
    assert.equal(res.body.is_guest, true);
    assert.equal(apiAccepts(res.body.access_token), true);
  });
  await probe('Production OTP verification logging includes the supplied OTP', async () => {
    process.env.NODE_ENV = 'production';
    const captured = [];
    global.console = { ...quiet, log(...parts) { captured.push(parts.map(String).join(' ')); } };
    const otp = load('auth/src/services/otpService.js', {
      '../db': { query: async () => ({ rows: [] }) }, '../config': {},
      bcrypt: { hash: async () => 'synthetic-hash', compare: async () => false },
      '../utils/fieldEncryption': { encryptPhoneNumber: value => value },
      '../utils/testOtp': { TEST_OTP_CODE: '0000', isTestOtpIdentifier: () => false },
      '../middleware/rateLimitMiddleware': { markActiveOtp: noop },
    });
    await otp.verifyOtp('audit-user@example.invalid', '4826', 'email');
    assert(captured.some(line => line.includes('4826')));
    global.console = quiet;
  });
  await probe('Concurrent verification can consume the same email OTP successfully twice', async () => {
    let comparisons = 0;
    let releaseComparisons;
    const bothComparing = new Promise(resolve => { releaseComparisons = resolve; });
    const record = { id: subject, otp_hash: 'synthetic-hash', expires_at: new Date(Date.now() + 60000),
      attempt_count: 0, email: 'audit-user@example.invalid', consumed_at: null, deleted: false, type: 'email' };
    let consumes = 0;
    const otp = load('auth/src/services/otpService.js', {
      '../db': { query: async sql => {
        if (sql.includes('SELECT id, otp_hash')) return { rows: [{ ...record }] };
        if (sql.includes('UPDATE otp_requests SET consumed_at')) { consumes++; return { rowCount: 1, rows: [] }; }
        throw new Error('Unexpected synthetic query');
      } }, '../config': {},
      bcrypt: { hash: async () => 'synthetic-hash', compare: async () => {
        comparisons++;
        if (comparisons === 2) releaseComparisons();
        await bothComparing;
        return true;
      } },
      '../utils/fieldEncryption': { encryptPhoneNumber: value => value },
      '../utils/testOtp': { TEST_OTP_CODE: '0000', isTestOtpIdentifier: () => false },
      '../middleware/rateLimitMiddleware': { markActiveOtp: noop },
    });
    const verified = await Promise.all([
      otp.verifyOtp(record.email, '4826', 'email'), otp.verifyOtp(record.email, '4826', 'email'),
    ]);
    assert(verified.every(result => result.ok));
    assert.equal(consumes, 2);
  });
  await probe('Enabling database access logging breaks queries through the db/logger circular dependency', async () => {
    process.env.NODE_ENV = 'test';
    process.env.DB_ACCESS_LOGGING_ENABLED = 'true';
    const modules = new Map();
    function loadCycle(relative) {
      const filename = path.join(root, relative);
      if (modules.has(filename)) return modules.get(filename).exports;
      const loaded = new Module(filename, module);
      loaded.filename = filename;
      loaded.paths = Module._nodeModulePaths(path.dirname(filename));
      modules.set(filename, loaded);
      loaded.require = request => {
        if (request === '../db') return loadCycle('auth/src/db.js');
        if (request === './middleware/dbAccessLogger') return loadCycle('auth/src/middleware/dbAccessLogger.js');
        if (request === './config' || request === './utils/awsSsm') return {};
        if (request === 'pg') return { Pool: class {} };
        return Module.prototype.require.call(loaded, request);
      };
      loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
      return loaded.exports;
    }
    const db = loadCycle('auth/src/db.js');
    await assert.rejects(() => db.query('SELECT 1'), /db.query is not a function/);
  });
  global.console = originalConsole;
  const output = { date: '2026-10-20', scope: 'isolated actual-source probes, synthetic records, no network or database',
    meaning: 'reproduced=true confirms the audit condition exists; it does not mean the application is secure', results };
  fs.writeFileSync(path.join(__dirname, 'security-probe-results.json'), JSON.stringify(output, null, 2) + '\n');
  console.log(JSON.stringify(output, null, 2));
  if (results.some(row => !row.reproduced)) process.exitCode = 1;
})().catch(error => { global.console = originalConsole; console.error(error.message); process.exitCode = 1; });
