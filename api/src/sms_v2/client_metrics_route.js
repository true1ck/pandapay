'use strict';

// POST /sms/v2/client-metrics (Lane N): the phone reports aggregate release counters.
//
// Counts only: sync attempts and errors by coarse reason, history migration
// started/completed/failed, bundle download failures. Never message content, never
// an id. The body has one closed day, the app version and a flat counter map; the
// server derives the attestation status itself and never trusts a client claim.
//
// Order: v2 flag (app.use in index.js and requireSmsV2 here), sign-in, attestation
// admission, rate limit (its own key, `client-metrics`), then one security-definer
// SQL function that also enforces sharing consent, de-duplicates a re-sent day per
// device, and writes only the aggregate row. No hook of security.js is edited: the
// limiter below reuses its pg counter store with this route's budget.

const crypto = require('node:crypto');
const { createPgRateStore } = require('./security');

const DAY = 86400;
const COUNTERS = Object.freeze([
  'sync_attempts',
  'sync_errors_network', 'sync_errors_timeout', 'sync_errors_server',
  'sync_errors_storage', 'sync_errors_data', 'sync_errors_other',
  'migration_started', 'migration_completed', 'migration_failed',
  'bundle_download_failures',
]);
const MAX_COUNT = 10000;
const VERSION = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$/;
const DAY_FORMAT = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
const BODY_KEYS = new Set(['day', 'appVersion', 'counters']);
const denied = (value) => value === false || value?.ok === false;

class ClientMetricsInputError extends Error {}

// Returns {day, appVersion, counters} or throws ClientMetricsInputError(code).
function parseClientMetrics(body, now = new Date()) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new ClientMetricsInputError('client_metrics_invalid');
  for (const key of Object.keys(body)) if (!BODY_KEYS.has(key)) throw new ClientMetricsInputError('client_metrics_invalid');
  const { day, appVersion, counters } = body;
  if (typeof day !== 'string' || !DAY_FORMAT.test(day) || Number.isNaN(Date.parse(`${day}T00:00:00Z`)) ||
      new Date(`${day}T00:00:00Z`).toISOString().slice(0, 10) !== day) throw new ClientMetricsInputError('client_metrics_day_invalid');
  const today = now.toISOString().slice(0, 10);
  const oldest = new Date(Date.parse(`${today}T00:00:00Z`) - 8 * DAY * 1000).toISOString().slice(0, 10);
  if (day > today || day < oldest) throw new ClientMetricsInputError('client_metrics_day_invalid');
  if (typeof appVersion !== 'string' || !VERSION.test(appVersion)) throw new ClientMetricsInputError('client_metrics_version_invalid');
  if (!counters || typeof counters !== 'object' || Array.isArray(counters)) throw new ClientMetricsInputError('client_metrics_invalid');
  const clean = {};
  for (const [name, value] of Object.entries(counters)) {
    if (!COUNTERS.includes(name) || !Number.isInteger(value) || value < 0 || value > MAX_COUNT) {
      throw new ClientMetricsInputError('client_metrics_counter_invalid');
    }
    if (value > 0) clean[name] = value;
  }
  if (!Object.keys(clean).length) throw new ClientMetricsInputError('client_metrics_empty');
  return { day, appVersion, counters: clean };
}

// Budget for this route only: one upload a day normally; a backlog of closed days,
// or a retry, needs a few more. Unverified callers get half, like the other routes.
function createClientMetricsLimiter({ withUserClient, env = process.env, consume }) {
  const raw = env.SMS_V2_CLIENT_METRICS_PER_DAY;
  const limit = raw === undefined ? 12 : Number(raw);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000) throw new Error('sms_v2_rate_config_invalid');
  let store = consume;
  return async function checkClientMetricsRate(req) {
    const verified = req.smsV2Security?.verified === true;
    const rawDevice = req.headers?.['x-sms-device-id'];
    const device = typeof rawDevice === 'string' && /^[A-Za-z0-9_-]{8,128}$/.test(rawDevice) ? rawDevice : 'missing';
    const deviceDigest = crypto.createHash('sha256').update(device).digest('hex');
    const checks = [{ bucket: 'client-metrics', seconds: DAY, limit: Math.max(1, Math.floor(limit * (verified ? 1 : 0.5))), units: 1 }];
    store ||= createPgRateStore({ withUserClient });
    const result = await store(req.userId, deviceDigest, checks);
    if (!result.allowed) req.res?.set('Retry-After', String(result.retryAfterSeconds));
    return { allowed: result.allowed, deviceDigest };
  };
}

function createClientMetricsHandler({ withUserClient, hooks, limiter, now = () => new Date() }) {
  return async function clientMetricsHandler(req, res) {
    let parsed;
    try {
      parsed = parseClientMetrics(req.body, now());
    } catch (error) {
      if (error instanceof ClientMetricsInputError) return res.status(400).json({ error: error.message });
      throw error;
    }
    try {
      if (denied(await hooks.security.verifyAttestation(req))) return res.status(403).json({ error: 'attestation_required' });
      const admitted = await limiter(req);
      if (!admitted.allowed) return res.status(429).json({ error: 'rate_limited' });
      const attestation = req.smsV2Security?.verified === true ? 'verified' : 'unverified';
      const result = await withUserClient(req.userId, (client) => client.query(
        'SELECT pandapay.sms_v2_record_client_metrics($1,$2::date,$3,$4,$5::jsonb) AS status',
        [admitted.deviceDigest, parsed.day, parsed.appVersion, attestation, JSON.stringify(parsed.counters)],
      ));
      // The same answer for every outcome: the phone only needs to know it may drop the day.
      return res.status(202).json({ status: result.rows[0].status });
    } catch (error) {
      console.error('sms_v2 client metrics failed', error?.code || 'internal');
      return res.status(503).json({ error: 'client_metrics_unavailable' });
    }
  };
}

function registerClientMetrics(app, { requireSmsV2, requireMember, withUserClient, hooks }, options = {}) {
  const limiter = options.limiter || createClientMetricsLimiter({ withUserClient, env: options.env });
  app.post('/sms/v2/client-metrics', requireSmsV2, requireMember,
    createClientMetricsHandler({ withUserClient, hooks, limiter, now: options.now }));
}

module.exports = {
  COUNTERS, MAX_COUNT, ClientMetricsInputError,
  parseClientMetrics, createClientMetricsLimiter, createClientMetricsHandler, registerClientMetrics,
};
