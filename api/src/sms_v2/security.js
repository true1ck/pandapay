'use strict';

const crypto = require('node:crypto');
const jwt = require('jsonwebtoken');

const HOUR = 3600;
const DAY = 86400;
const JWKS_URL = 'https://firebaseappcheck.googleapis.com/v1/jwks';
const ROUTES = Object.freeze({
  'facts:batch': [
    { bucket: 'facts:requests', seconds: 60, limit: 60, env: 'SMS_V2_FACTS_REQUESTS_PER_MINUTE', items: false },
    { bucket: 'facts:items', seconds: DAY, limit: 20000, env: 'SMS_V2_FACTS_ITEMS_PER_DAY', items: true },
  ],
  rules: [{ bucket: 'rules', seconds: HOUR, limit: 30, env: 'SMS_V2_RULES_PER_HOUR' }],
  sync: [{ bucket: 'sync', seconds: HOUR, limit: 120, env: 'SMS_V2_SYNC_PER_HOUR' }],
  'unknown-templates': [{ bucket: 'unknown-templates', seconds: DAY, limit: 50, env: 'SMS_V2_UNKNOWN_TEMPLATES_PER_DAY', items: true }],
  corrections: [{ bucket: 'corrections', seconds: DAY, limit: 200, env: 'SMS_V2_CORRECTIONS_PER_DAY', items: true }],
  'rule-stats': [{ bucket: 'rule-stats', seconds: DAY, limit: 24, env: 'SMS_V2_RULE_STATS_PER_DAY' }],
});

async function fetchAppCheckJwks() {
  const response = await fetch(JWKS_URL, { signal: AbortSignal.timeout(3000), redirect: 'error' });
  if (!response.ok) throw new Error('sms_v2_jwks_unavailable');
  // Read a bounded key document even if Content-Length is absent.
  let length = 0;
  const chunks = [];
  for await (const chunk of response.body) {
    length += chunk.length;
    if (length > 65536) {
      await response.body.cancel().catch(() => {});
      throw new Error('sms_v2_jwks_too_large');
    }
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function createAppCheckVerifier({
  projectNumber,
  appIds = [],
  fetchJwks = fetchAppCheckJwks,
  now = () => Date.now(),
} = {}) {
  let keys = new Map();
  let expiresAt = 0;
  let inFlight;
  const allowedApps = new Set(appIds);
  return async function verifyToken(token) {
    if (!/^[0-9]+$/.test(projectNumber || '') || typeof token !== 'string' || token.length > 8192) return null;
    const decoded = jwt.decode(token, { complete: true });
    if (!decoded || decoded.header.alg !== 'RS256' || decoded.header.typ !== 'JWT' ||
        typeof decoded.header.kid !== 'string' || decoded.header.kid.length > 256) return null;
    if (now() >= expiresAt) {
      if (!inFlight) {
        inFlight = (async () => {
          const document = await fetchJwks();
          if (!Array.isArray(document?.keys) || document.keys.length > 32) throw new Error('sms_v2_jwks_invalid');
          const next = new Map();
          for (const key of document.keys) {
            if (key.kty !== 'RSA' || key.alg !== 'RS256' || key.use !== 'sig' || typeof key.kid !== 'string') continue;
            next.set(key.kid, crypto.createPublicKey({ key, format: 'jwk' }));
          }
          if (!next.size) throw new Error('sms_v2_jwks_invalid');
          keys = next;
          expiresAt = now() + 6 * HOUR * 1000;
        })().finally(() => { inFlight = null; });
      }
      try { await inFlight; } catch { return null; }
    }
    const key = keys.get(decoded.header.kid);
    if (!key) return null;
    try {
      const claims = jwt.verify(token, key, {
        algorithms: ['RS256'],
        issuer: `https://firebaseappcheck.googleapis.com/${projectNumber}`,
        audience: `projects/${projectNumber}`,
        clockTimestamp: Math.floor(now() / 1000),
      });
      if (typeof claims.sub !== 'string' || !claims.sub ||
          !Number.isSafeInteger(claims.exp) || !Number.isSafeInteger(claims.iat) ||
          claims.iat > Math.floor(now() / 1000) ||
          (allowedApps.size && !allowedApps.has(claims.sub))) return null;
      return { appId: claims.sub, expiresAt: claims.exp * 1000 };
    } catch {
      return null;
    }
  };
}

function createPgRateStore({ withUserClient }) {
  if (typeof withUserClient !== 'function') throw new TypeError('withUserClient is required');
  return async (profileId, deviceDigest, checks) => withUserClient(profileId, async client => {
    const result = await client.query(
      'SELECT * FROM pandapay.sms_v2_consume_rate($1, $2::jsonb)',
      [deviceDigest, JSON.stringify(checks)],
    );
    const row = result.rows?.[0];
    if (typeof row?.allowed !== 'boolean' || !Number.isInteger(row.retry_after_seconds) ||
        row.retry_after_seconds < 0 || row.retry_after_seconds > DAY ||
        (!row.allowed && row.retry_after_seconds < 1)) throw new Error('sms_v2_rate_invalid_result');
    return { allowed: row.allowed, retryAfterSeconds: row.retry_after_seconds };
  });
}

function configuredLimit(env, spec) {
  const value = env[spec.env] === undefined ? spec.limit : Number(env[spec.env]);
  if (!Number.isSafeInteger(value) || value < 1 || value > 1000000) throw new Error('sms_v2_rate_config_invalid');
  return value;
}

function createSecurity({
  env = process.env,
  withUserClient,
  consume = createPgRateStore({ withUserClient }),
  verifyToken = createAppCheckVerifier({
    projectNumber: env.SMS_V2_FIREBASE_PROJECT_NUMBER,
    appIds: (env.SMS_V2_FIREBASE_APP_IDS || '').split(',').map(s => s.trim()).filter(Boolean),
  }),
  hasEntitlement = async () => false,
  log = entry => console.info(JSON.stringify(entry)),
} = {}) {
  const mode = env.SMS_V2_ATTESTATION_MODE || 'monitor';
  if (!['monitor', 'enforce'].includes(mode)) throw new Error('sms_v2_attestation_mode_invalid');
  const limits = Object.fromEntries(Object.entries(ROUTES).map(([route, specs]) =>
    [route, specs.map(spec => ({ ...spec, limit: configuredLimit(env, spec) }))]));
  const results = new WeakMap();
  const security = {
    async verifyAttestation(req) {
      if (results.has(req)) return results.get(req);
      const raw = req.headers?.['x-device-attestation'];
      const claims = typeof raw === 'string' && raw ? await verifyToken(raw) : null;
      const verified = !!claims;
      const state = Object.freeze({ verified, sharedLearningEligible: verified, appId: claims?.appId || null });
      Object.defineProperty(req, 'smsV2Security', { value: state, configurable: true });
      const allowed = verified || mode === 'monitor';
      results.set(req, allowed);
      if (!verified) log({ event: 'sms_v2_attestation', mode, outcome: raw ? 'invalid' : 'missing' });
      return allowed;
    },
    async checkRate(req, route, units = 1) {
      if (!await security.verifyAttestation(req)) return false;
      const specs = limits[route];
      if (!specs || !Number.isSafeInteger(units) || units < 1 || units > 20000) throw new Error('sms_v2_rate_request_invalid');
      const multiplier = req.smsV2Security.verified ? 1 : 0.5;
      const checks = specs.map(spec => ({
        bucket: spec.bucket, seconds: spec.seconds,
        limit: Math.max(1, Math.floor(spec.limit * multiplier)),
        units: spec.items ? units : 1,
      }));
      const rawDevice = req.headers?.['x-sms-device-id'];
      const device = typeof rawDevice === 'string' && /^[A-Za-z0-9_-]{8,128}$/.test(rawDevice) ? rawDevice : 'missing';
      const deviceDigest = crypto.createHash('sha256').update(device).digest('hex');
      const result = await consume(req.userId, deviceDigest, checks);
      if (!result.allowed) req.res?.set('Retry-After', String(result.retryAfterSeconds));
      return result.allowed;
    },
    async checkEntitlement(req) {
      return env.SMS_V2_REQUIRE_ENTITLEMENT !== 'true' || await hasEntitlement(req.userId) === true;
    },
  };
  return security;
}

function installSecurity(hooks, deps) {
  hooks.security = {
    ...createSecurity({ withUserClient: deps.withUserClient, env: deps.securityEnv || process.env,
      ...(deps.securityOptions || {}) }),
    ...(deps.hooks?.security || {}),
  };
}

module.exports = { createAppCheckVerifier, createSecurity, createPgRateStore, installSecurity };
