'use strict';
// Lane N: phone-reported release counters (route, privacy shape, metrics gates).
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const crypto = require('node:crypto');
const { parseClientMetrics, createClientMetricsLimiter, registerClientMetrics, COUNTERS } = require('../../src/sms_v2/client_metrics_route');
const { registerSmsV2 } = require('../../src/sms_v2');
const { collectMetrics } = require('../../src/sms_v2/metrics_route');

const NOW = new Date('2026-11-05T10:00:00Z');
const good = () => ({ day: '2026-11-04', appVersion: '1.2.3+4', counters: { sync_attempts: 12, sync_errors_network: 1 } });
const USER = crypto.randomUUID();
const yesterday = () => new Date(Date.now() - 86400000).toISOString().slice(0, 10);

test('client metrics body: closed vocabulary, bounded counts, recent day, no extra fields', () => {
  assert.deepEqual(parseClientMetrics(good(), NOW), { day: '2026-11-04', appVersion: '1.2.3+4', counters: { sync_attempts: 12, sync_errors_network: 1 } });
  assert.deepEqual(parseClientMetrics({ ...good(), counters: { sync_attempts: 3, migration_failed: 0 } }, NOW).counters, { sync_attempts: 3 });
  const bad = (patch, code) => assert.throws(() => parseClientMetrics({ ...good(), ...patch }, NOW), new RegExp(code));
  bad({ extra: 'HDFC debited Rs 500' }, 'client_metrics_invalid');
  bad({ counters: { merchant: 1 } }, 'client_metrics_counter_invalid');
  bad({ counters: { sync_attempts: 1.5 } }, 'client_metrics_counter_invalid');
  bad({ counters: { sync_attempts: -1 } }, 'client_metrics_counter_invalid');
  bad({ counters: { sync_attempts: 10001 } }, 'client_metrics_counter_invalid');
  bad({ counters: { sync_attempts: '5' } }, 'client_metrics_counter_invalid');
  bad({ counters: { sync_attempts: 0 } }, 'client_metrics_empty');
  bad({ counters: [1] }, 'client_metrics_invalid');
  bad({ day: '2026-11-06' }, 'client_metrics_day_invalid');
  bad({ day: '2026-10-20' }, 'client_metrics_day_invalid');
  bad({ day: '2026-02-30' }, 'client_metrics_day_invalid');
  bad({ day: 'yesterday' }, 'client_metrics_day_invalid');
  bad({ appVersion: 'a b' }, 'client_metrics_version_invalid');
  bad({ appVersion: 'x'.repeat(40) }, 'client_metrics_version_invalid');
  assert.throws(() => parseClientMetrics(null, NOW), /client_metrics_invalid/);
  assert.ok(COUNTERS.every((name) => /^[a-z_]+$/.test(name)));
});

test('rate limit uses its own bucket, half for unverified callers, and reports Retry-After', async () => {
  const seen = [];
  const consume = async (profile, digest, checks) => { seen.push({ profile, digest, checks }); return { allowed: seen.length < 3, retryAfterSeconds: 77 }; };
  const limiter = createClientMetricsLimiter({ env: { SMS_V2_CLIENT_METRICS_PER_DAY: '10' }, consume });
  const headers = {};
  const req = (verified, device) => ({ userId: USER, smsV2Security: { verified }, headers: { 'x-sms-device-id': device },
    res: { set: (k, v) => { headers[k] = v; } } });
  assert.equal((await limiter(req(true, 'device-0001'))).allowed, true);
  assert.equal((await limiter(req(false, 'device-0001'))).allowed, true);
  assert.deepEqual(seen.map((s) => s.checks), [
    [{ bucket: 'client-metrics', seconds: 86400, limit: 10, units: 1 }],
    [{ bucket: 'client-metrics', seconds: 86400, limit: 5, units: 1 }],
  ]);
  assert.match(seen[0].digest, /^[0-9a-f]{64}$/);
  assert.notEqual(seen[0].digest, 'device-0001', 'the raw installation id never reaches storage');
  assert.equal((await limiter(req(true, 'device-0001'))).allowed, false);
  assert.equal(headers['Retry-After'], '77');
  assert.throws(() => createClientMetricsLimiter({ env: { SMS_V2_CLIENT_METRICS_PER_DAY: '0' }, consume }), /rate_config_invalid/);
});

async function harness({ flag = true, attestation = true, rateAllowed = true, recordStatus = 'recorded' } = {}) {
  const calls = [];
  const app = express();
  const requireAuth = (req, res, next) => {
    req.userId = req.headers['x-user'] || null;
    return req.userId ? next() : res.status(401).json({ error: 'unauthorized' });
  };
  registerSmsV2(app, {
    requireAuth,
    requireAdmin: (req, res) => res.status(403).json({ error: 'Admin access required' }),
    withUserClient: async (profile, fn) => fn({ query: async (sql, params) => {
      calls.push({ profile, sql, params });
      if (/sms_v2_consume_rate/.test(sql)) return { rows: [{ allowed: rateAllowed, retry_after_seconds: rateAllowed ? 0 : 30 }] };
      if (/sms_v2_record_client_metrics/.test(sql)) return { rows: [{ status: recordStatus }] };
      throw new Error(`unexpected sql ${sql}`);
    } }),
    readFlag: async () => (flag ? { key: 'sms_pipeline_v2_enabled', is_enabled: true, rollout_percent: 100 } : null),
    flagCacheMs: 0,
    signer: null,
    securityOptions: { verifyToken: async () => (attestation ? { appId: 'app', expiresAt: Date.now() + 60000 } : null) },
    loadUserCardForState: async () => null,
    applyTransactionState: async () => ({}),
    reverseTransactionState: async () => ({}),
  });
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = async (body, headers = {}) => {
    const res = await fetch(`${base}/sms/v2/client-metrics`, { method: 'POST',
      headers: { 'content-type': 'application/json', 'x-user': USER, 'x-sms-device-id': 'device-0001', ...headers },
      body: JSON.stringify(body) });
    return { status: res.status, json: await res.json().catch(() => null) };
  };
  return { calls, post, close: () => { server.closeAllConnections(); server.close(); } };
}

test('route: flag off answers 404 before any database work', async () => {
  const h = await harness({ flag: false });
  try {
    const r = await h.post({ day: yesterday(), appVersion: '1', counters: { sync_attempts: 1 } });
    assert.equal(r.status, 404);
    assert.equal(h.calls.length, 0);
  } finally { h.close(); }
});

test('route: sign-in and validation come first; an unverified caller is admitted at half the budget', async () => {
  const h = await harness();
  try {
    const ok = { day: yesterday(), appVersion: '1.0.0', counters: { sync_attempts: 1 } };
    assert.equal((await h.post(ok, { 'x-user': '' })).status, 401);
    assert.equal((await h.post({ ...ok, counters: { sender: 1 } })).status, 400);
    assert.equal(h.calls.length, 0);
  } finally { h.close(); }
  const unverified = await harness({ attestation: false });
  try {
    // Monitor mode (the default) admits an unverified caller, recorded as unverified.
    const r = await unverified.post({ day: yesterday(), appVersion: '1.0.0', counters: { sync_attempts: 1 } }, { 'x-device-attestation': 'bad' });
    assert.equal(r.status, 202);
    const record = unverified.calls.find((c) => /sms_v2_record_client_metrics/.test(c.sql));
    assert.equal(record.params[3], 'unverified');
    const rate = unverified.calls.find((c) => /sms_v2_consume_rate/.test(c.sql));
    assert.equal(JSON.parse(rate.params[1])[0].limit, 6, 'unverified callers get half of the daily budget');
  } finally { unverified.close(); }
});

test('route: a verified upload stores aggregate values only and the server sets attestation', async () => {
  const h = await harness();
  try {
    const day = yesterday();
    const r = await h.post({ day, appVersion: '2.0.1+9', counters: { sync_attempts: 12, sync_errors_timeout: 2, migration_failed: 1 } },
      { 'x-device-attestation': 'token' });
    assert.equal(r.status, 202);
    const rate = h.calls.find((c) => /sms_v2_consume_rate/.test(c.sql));
    assert.equal(JSON.parse(rate.params[1])[0].bucket, 'client-metrics');
    const record = h.calls.find((c) => /sms_v2_record_client_metrics/.test(c.sql));
    assert.match(record.params[0], /^[0-9a-f]{64}$/);
    assert.deepEqual(record.params.slice(1, 4), [day, '2.0.1+9', 'verified']);
    assert.deepEqual(JSON.parse(record.params[4]), { sync_attempts: 12, sync_errors_timeout: 2, migration_failed: 1 });
    assert.equal(record.params.length, 5, 'no other value is passed to storage');
  } finally { h.close(); }
});

test('route: a rate-limited caller gets 429 and nothing is stored', async () => {
  const h = await harness({ rateAllowed: false });
  try {
    const r = await h.post({ day: yesterday(), appVersion: '1', counters: { sync_attempts: 1 } });
    assert.equal(r.status, 429);
    assert.equal(h.calls.some((c) => /sms_v2_record_client_metrics/.test(c.sql)), false);
  } finally { h.close(); }
});

test('route: a database failure answers 503 without detail', async () => {
  const app = express();
  app.use(express.json());
  registerClientMetrics(app, {
    requireSmsV2: (req, res, next) => next(),
    requireMember: (req, res, next) => { req.userId = USER; next(); },
    withUserClient: async () => { throw Object.assign(new Error('secret connection string'), { code: 'ECONNREFUSED' }); },
    hooks: { security: { verifyAttestation: async () => true } },
  }, { limiter: async () => ({ allowed: true, deviceDigest: 'a'.repeat(64) }) });
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const origError = console.error; console.error = () => {};
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/sms/v2/client-metrics`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ day: yesterday(), appVersion: '1', counters: { sync_attempts: 1 } }) });
    assert.equal(res.status, 503);
    assert.deepEqual(await res.json(), { error: 'client_metrics_unavailable' });
  } finally { console.error = origError; server.closeAllConnections(); server.close(); }
});

// --- admin metrics: the two phone-reported gates ---
function metricsClient({ clientReport, newEvents = 1000, corrections = 2 }) {
  return { async query(sql) {
    if (/sms_v2_template_attempts/.test(sql)) return { rows: [] };
    if (/sms_v2_release_metrics/.test(sql)) return { rows: [{ m: { newEvents, newFacts: 10, activeProfiles30d: 5, rateUsed: {} } }] };
    if (/sms_v2_client_metrics_report/.test(sql)) return { rows: [{ r: clientReport }] };
    if (/GROUP BY stage/.test(sql)) return { rows: [] };
    if (/FROM sms_v2_correction_cases/.test(sql)) return { rows: [{ total: corrections, open: 0, shared_eligible: 0, testers: 0 }] };
    if (/sms_v2_template_submitters/.test(sql)) return { rows: [{ verified: 0, unverified: 0 }] };
    if (/sms_v2_rule_stats_daily/.test(sql)) return { rows: [{ hits: '0', to_review: '0', corrected: '0' }] };
    if (/sms_v2_rule_stats_profile_daily/.test(sql)) return { rows: [] };
    if (/sms_v2_testers/.test(sql)) return { rows: [] };
    if (/status='rolled_back'/.test(sql)) return { rows: [{ n: 0 }] };
    if (/FROM sms_v2_bundles/.test(sql)) return { rows: [] };
    throw new Error(`unexpected query: ${sql}`);
  } };
}
// 140 receipts over 7 days is at least 20 reporting devices (the go floor).
const report = (totals, byVersion = [], reports = 4) => ({ totals, byVersion, reports });

test('metrics: reported sync and migration counters make both gates available and the decision can be go', async () => {
  const m = await collectMetrics(metricsClient({ clientReport: report(
    { sync_attempts: 2000, sync_errors_network: 10, sync_errors_timeout: 5, migration_started: 300, migration_completed: 299, migration_failed: 1, bundle_download_failures: 7 },
    [{ appVersion: '2.0.0', attestation: 'verified', counters: { sync_attempts: 2000, sync_errors_network: 10, sync_errors_timeout: 5 } }], 140) }), { days: 7, now: NOW });
  assert.equal(m.syncErrorRate.available, true);
  assert.equal(m.syncErrorRate.value, 15 / 2000);
  assert.deepEqual([m.syncErrorRate.attempts, m.syncErrorRate.errors, m.syncErrorRate.byReason.network, m.syncErrorRate.byReason.timeout], [2000, 15, 10, 5]);
  assert.equal(m.migrationFailureRate.available, true);
  assert.equal(m.migrationFailureRate.value, 1 / 300);
  assert.equal(m.gates.syncErrorRate.status, 'pass');
  assert.equal(m.gates.migrationFailureRate.status, 'pass');
  assert.deepEqual(m.missingSignals, []);
  assert.equal(m.decision, 'go');
  assert.equal(m.clientReports.bundleDownloadFailures, 7);
  assert.equal(m.clientReports.byVersion[0].syncErrors, 15);
  assert.equal(m.clientReports.byVersion[0].attestation, 'verified');
});

test('metrics: a sync error rate of 1% or more, or a migration failure rate of 0.5% or more, is a no-go', async () => {
  const syncBad = await collectMetrics(metricsClient({ clientReport: report({ sync_attempts: 1000, sync_errors_server: 10, migration_completed: 1000 }) }), { days: 7, now: NOW });
  assert.equal(syncBad.gates.syncErrorRate.status, 'fail');
  assert.equal(syncBad.decision, 'no-go');
  const migBad = await collectMetrics(metricsClient({ clientReport: report({ sync_attempts: 1000, migration_completed: 199, migration_failed: 1 }) }), { days: 7, now: NOW });
  assert.equal(migBad.migrationFailureRate.value, 0.005);
  assert.equal(migBad.gates.migrationFailureRate.status, 'fail');
  assert.equal(migBad.decision, 'no-go');
});

test('metrics: with no phone reports the two signals stay unavailable and the decision incomplete', async () => {
  for (const clientReport of [{}, report({}), report({ migration_started: 3 })]) {
    const m = await collectMetrics(metricsClient({ clientReport }), { days: 7, now: NOW });
    assert.equal(m.syncErrorRate.available, false);
    assert.equal(m.migrationFailureRate.available, false);
    assert.equal(m.decision, 'incomplete');
  }
  const half = await collectMetrics(metricsClient({ clientReport: report({ sync_attempts: 100 }) }), { days: 7, now: NOW });
  assert.equal(half.syncErrorRate.available, true);
  assert.equal(half.migrationFailureRate.available, false);
  assert.deepEqual(half.missingSignals, ['migrationFailureRate']);
  assert.equal(half.decision, 'incomplete');
});

test('metrics payload with client counters carries no profile, device or message values', async () => {
  const m = await collectMetrics(metricsClient({ clientReport: report({ sync_attempts: 10, migration_completed: 1 },
    [{ appVersion: '2.0.0', attestation: 'unverified', counters: { sync_attempts: 10 } }]) }), { days: 7, now: NOW });
  assert.doesNotMatch(JSON.stringify(m.clientReports), /profile|device|digest|sender|body/i);
});
