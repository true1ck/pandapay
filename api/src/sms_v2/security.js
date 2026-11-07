'use strict';

const crypto = require('node:crypto');
const jwt = require('jsonwebtoken');
const { SETTINGS, readPublicSettings } = require('./settings');

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
  // `setting` names the console setting that may lower or raise this limit; the
  // environment value, when set, is its hard ceiling (see settings.js).
  'unknown-templates': [{ bucket: 'unknown-templates', seconds: DAY, limit: 50, env: 'SMS_V2_UNKNOWN_TEMPLATES_PER_DAY', items: true, setting: 'templates_per_user_per_day' }],
  corrections: [{ bucket: 'corrections', seconds: DAY, limit: 200, env: 'SMS_V2_CORRECTIONS_PER_DAY', items: true, setting: 'corrections_per_user_per_day' }],
  'learning-signals': [{ bucket: 'learning-signals', seconds: DAY, limit: 500, env: 'SMS_V2_LEARNING_SIGNALS_PER_DAY', items: true, setting: 'signals_per_user_per_day' }],
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

// LO-15: a token minted through a debug provider must not reach production. Firebase does not
// document a stable claim for this, so the check is best effort: any provider-style claim that
// names a debug provider, or a subject listed in SMS_V2_DEBUG_APP_IDS (debug builds registered
// under their own Firebase app id, which is the dependable control; see signing-keys.md).
function isDebugToken(claims, debugAppIds) {
  const hints = [claims.provider, claims.attestation_provider, claims.firebase?.provider, claims.firebase?.app_check_provider];
  return debugAppIds.has(claims.sub) || hints.some(value => typeof value === 'string' && /debug/i.test(value));
}

function createAppCheckVerifier({
  projectNumber,
  appIds = [],
  fetchJwks = fetchAppCheckJwks,
  now = () => Date.now(),
  rejectDebug = false,
  debugAppIds = [],
} = {}) {
  let keys = new Map();
  let expiresAt = 0;
  let inFlight;
  const allowedApps = new Set(appIds);
  const debugApps = new Set(debugAppIds);
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
      if (rejectDebug && isDebugToken(claims, debugApps)) return null;
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

// ---- LO-10: binding and limited-use tokens ----------------------------------------------

const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');
const MAX_BINDINGS = 10000;

// Remembers which (profile, installation digest) first presented a token. A token first seen
// for one account is not verified for another. `db` mode also records the first sighting in
// Postgres (sms_v2_attestation_bindings) so every API replica agrees; the process cache only
// avoids repeat queries. Returns true when the token belongs to this profile and installation.
function createAttestationBinder({ mode, withUserClient, now = () => Date.now() }) {
  const seen = new Map();
  const remember = (digest, entry) => {
    seen.delete(digest);
    seen.set(digest, entry);
    for (const [key, value] of seen) {
      if (seen.size <= MAX_BINDINGS && value.expiresAt > now()) break;
      seen.delete(key);
    }
  };
  return async function bind(profileId, tokenDigest, deviceDigest, expiresAt) {
    if (typeof profileId !== 'string' || !profileId) return false;
    const known = seen.get(tokenDigest);
    if (known && known.expiresAt > now()) return known.profileId === profileId && known.deviceDigest === deviceDigest;
    let bound = true;
    if (mode === 'db') {
      const result = await withUserClient(profileId, client =>
        client.query('SELECT pandapay.sms_v2_bind_attestation($1, $2, $3::timestamptz) AS bound',
          [tokenDigest, deviceDigest, new Date(expiresAt).toISOString()]));
      if (typeof result.rows?.[0]?.bound !== 'boolean') throw new Error('sms_v2_binding_invalid_result');
      bound = result.rows[0].bound;
    }
    // A conflict is not cached: the database knows the owner, this process may not.
    if (bound) remember(tokenDigest, { profileId, deviceDigest, expiresAt });
    return bound;
  };
}

// Firebase App Check replay protection: verifyAppCheckToken consumes a limited-use token and
// reports alreadyConsumed on a second presentation. Needs credentials, so it is off by default
// (SMS_V2_APPCHECK_REPLAY_PROTECTION=on). Fails closed: any error counts as not fresh.
function createLimitedUseConsumer({ projectNumber, getAccessToken, fetchImpl = fetch }) {
  return async function consume(token) {
    try {
      const response = await fetchImpl(`https://firebaseappcheck.googleapis.com/v1/projects/${projectNumber}:verifyAppCheckToken`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${await getAccessToken()}` },
        body: JSON.stringify({ appCheckToken: token }),
        signal: AbortSignal.timeout(3000), redirect: 'error',
      });
      if (!response.ok) return false;
      const body = await response.json();
      return body?.alreadyConsumed !== true;
    } catch {
      return false;
    }
  };
}

function defaultAccessTokenProvider() {
  let lib;
  try { lib = require('google-auth-library'); } catch { return null; }
  const auth = new lib.GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] });
  return async () => auth.getAccessToken();
}

const DEFAULT_LIMITED_USE_ROUTES = 'unknown-templates,corrections,rule-stats,learning-signals';

function deviceDigestOf(req) {
  const rawDevice = req.headers?.['x-sms-device-id'];
  const device = typeof rawDevice === 'string' && /^[A-Za-z0-9_-]{8,128}$/.test(rawDevice) ? rawDevice : 'missing';
  return sha256(device);
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
  fetchJwks,
  now = () => Date.now(),
  verifyToken = createAppCheckVerifier({
    now,
    ...(fetchJwks ? { fetchJwks } : {}),
    projectNumber: env.SMS_V2_FIREBASE_PROJECT_NUMBER,
    appIds: (env.SMS_V2_FIREBASE_APP_IDS || '').split(',').map(s => s.trim()).filter(Boolean),
    rejectDebug: env.NODE_ENV === 'production' && env.SMS_V2_ALLOW_DEBUG_APP_CHECK !== 'true',
    debugAppIds: (env.SMS_V2_DEBUG_APP_IDS || '').split(',').map(s => s.trim()).filter(Boolean),
  }),
  hasEntitlement = async () => false,
  log = entry => console.info(JSON.stringify(entry)),
  getAccessToken,
  fetchImpl,
  bindAttestation,
  consumeLimitedUse,
  // Console-set values for the public keys (settings.js). Failing open to the
  // built-in defaults keeps phones working if the settings table is unreadable.
  readStoredSettings = req => withUserClient
    ? withUserClient(req.userId, client => readPublicSettings(client))
    : Promise.resolve({}),
} = {}) {
  const mode = env.SMS_V2_ATTESTATION_MODE || 'monitor';
  if (!['monitor', 'enforce'].includes(mode)) throw new Error('sms_v2_attestation_mode_invalid');
  // Token binding (LO-10). Production defaults to the durable `db` mode (needs migration
  // 20261114110000); elsewhere the per-process `memory` mode. `off` disables it.
  const bindingMode = env.SMS_V2_ATTESTATION_BINDING || (env.NODE_ENV === 'production' && withUserClient ? 'db' : 'memory');
  if (!['off', 'memory', 'db'].includes(bindingMode) || (bindingMode === 'db' && typeof withUserClient !== 'function')) {
    throw new Error('sms_v2_attestation_binding_invalid');
  }
  const bind = bindAttestation || createAttestationBinder({ mode: bindingMode, withUserClient, now });
  // Limited-use token replay protection (LO-10), default off. Only meaningful once the app
  // sends getLimitedUseToken() tokens on these routes; see signing-keys.md.
  const replay = env.SMS_V2_APPCHECK_REPLAY_PROTECTION || 'off';
  if (!['off', 'on'].includes(replay)) throw new Error('sms_v2_appcheck_replay_invalid');
  const limitedUseRoutes = new Set((env.SMS_V2_APPCHECK_LIMITED_USE_ROUTES || DEFAULT_LIMITED_USE_ROUTES)
    .split(',').map(s => s.trim()).filter(Boolean));
  let consumeToken = consumeLimitedUse;
  if (replay === 'on' && !consumeToken) {
    const provider = getAccessToken || defaultAccessTokenProvider();
    if (!provider || !/^[0-9]+$/.test(env.SMS_V2_FIREBASE_PROJECT_NUMBER || '')) throw new Error('sms_v2_appcheck_replay_unconfigured');
    consumeToken = createLimitedUseConsumer({ projectNumber: env.SMS_V2_FIREBASE_PROJECT_NUMBER, getAccessToken: provider, fetchImpl });
  }
  const limits = Object.fromEntries(Object.entries(ROUTES).map(([route, specs]) =>
    [route, specs.map(spec => ({
      ...spec,
      limit: configuredLimit(env, spec),
      // A console setting may not exceed the operator's environment value; with
      // none set, the registry maximum applies.
      ceiling: spec.setting && env[spec.env] === undefined ? SETTINGS[spec.setting].max : configuredLimit(env, spec),
    }))]));
  const results = new WeakMap();
  // Whether this account is a tester the owner chose to count without App Check. Asked of the database at most once
  // a minute per account, and never able to fail a request: a failure means "no".
  const testerCache = new Map();
  async function testerCounts(profileId) {
    if (typeof withUserClient !== 'function' || !profileId) return false;
    const cached = testerCache.get(profileId);
    if (cached && cached.until > now()) return cached.value;
    let value = false;
    try {
      value = await withUserClient(profileId, async (client) =>
        (await client.query('SELECT pandapay.sms_v2_tester_counts() AS counts')).rows[0]?.counts === true);
    } catch { value = false; }
    if (testerCache.size >= 2000) testerCache.clear();
    testerCache.set(profileId, { value, until: now() + 60000 });
    return value;
  }
  const security = {
    async verifyAttestation(req) {
      if (results.has(req)) return results.get(req);
      const raw = req.headers?.['x-device-attestation'];
      let claims = typeof raw === 'string' && raw ? await verifyToken(raw) : null;
      let outcome = raw ? 'invalid' : 'missing';
      if (claims && bindingMode !== 'off' &&
          !await bind(req.userId, sha256(raw), deviceDigestOf(req), claims.expiresAt)) {
        claims = null; // another account or installation presented this token first
        outcome = 'bound_elsewhere';
      }
      security.setState(req, claims);
      // A tester's phone that cannot attest (a free Apple developer account) can still count, when the owner says so.
      if (!claims && await testerCounts(req.userId)) security.setState(req, null, { tester: true });
      const allowed = !!claims || mode === 'monitor';
      results.set(req, allowed);
      if (!claims) log({ event: 'sms_v2_attestation', mode, outcome });
      return allowed;
    },
    setState(req, claims, { tester = false } = {}) {
      const verified = !!claims;
      // `verified` still means "passed App Check" (rate limits trust only that); `sharedLearningEligible` is what
      // the Learning page and shared cases count, and may also be true for a tester the owner chose to count.
      const state = Object.freeze({ verified, sharedLearningEligible: verified || tester, appId: claims?.appId || null });
      Object.defineProperty(req, 'smsV2Security', { value: state, configurable: true });
    },
    // Stored console settings for the public keys; {} when unreadable.
    async storedSettings(req) {
      try { return (await readStoredSettings(req)) || {}; } catch { return {}; }
    },
    async checkRate(req, route, units = 1) {
      if (!await security.verifyAttestation(req)) return false;
      const specs = limits[route];
      if (!specs || !Number.isSafeInteger(units) || units < 1 || units > 20000) throw new Error('sms_v2_rate_request_invalid');
      if (replay === 'on' && limitedUseRoutes.has(route) && req.smsV2Security.verified &&
          !(await consumeToken(req.headers['x-device-attestation']))) {
        // Already used, or Firebase could not confirm it: not verified for this request.
        security.setState(req, null);
        log({ event: 'sms_v2_attestation', mode, outcome: 'replayed' });
        if (mode === 'enforce') return false;
      }
      const multiplier = req.smsV2Security.verified ? 1 : 0.5;
      const stored = specs.some(spec => spec.setting) ? await security.storedSettings(req) : {};
      const checks = specs.map(spec => {
        const chosen = spec.setting && Number.isSafeInteger(stored[spec.setting]) && stored[spec.setting] >= 1
          ? Math.min(stored[spec.setting], spec.ceiling) : spec.limit;
        return {
          bucket: spec.bucket, seconds: spec.seconds,
          limit: Math.max(1, Math.floor(chosen * multiplier)),
          units: spec.items ? units : 1,
        };
      });
      const result = await consume(req.userId, deviceDigestOf(req), checks);
      if (!result.allowed) req.res?.set('Retry-After', String(result.retryAfterSeconds));
      return result.allowed;
    },
    async checkEntitlement(req) {
      return env.SMS_V2_REQUIRE_ENTITLEMENT !== 'true' || await hasEntitlement(req.userId) === true;
    },
  };
  return security;
}

// The public API process must not hold the rule signing key (LO-09). Production only; logs
// loudly rather than refusing to boot so a deploy ordering mistake cannot take the API down.
function assertNoSigningKeyInPublicProcess(env = process.env, log = (m) => console.error(m)) {
  if (env.NODE_ENV === 'production' && env.SMS_RULES_SIGNING_KEY) {
    log('SMS v2: SMS_RULES_SIGNING_KEY is set in the public API environment. Remove it; only the maintenance job and the private admin API sign.');
    return false;
  }
  return true;
}

function installSecurity(hooks, deps) {
  hooks.security = {
    ...createSecurity({ withUserClient: deps.withUserClient, env: deps.securityEnv || process.env,
      ...(deps.securityOptions || {}) }),
    ...(deps.hooks?.security || {}),
  };
}

module.exports = { createAttestationBinder, createLimitedUseConsumer, isDebugToken, createAppCheckVerifier, createSecurity, createPgRateStore, installSecurity, assertNoSigningKeyInPublicProcess };
