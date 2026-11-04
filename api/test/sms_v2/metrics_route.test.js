'use strict';
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const { collectMetrics, metricsHandler, parseDays, GATES } = require('../../src/sms_v2/metrics_route');
const { cohortFor } = require('../../src/sms_v2/bundle_builder');

const NOW = new Date('2026-11-05T00:00:00Z');

// Finds one profile id per cohort so per-cohort numbers are deterministic.
function profileFor(cohort, skip = new Set()) {
  for (let i = 0; i < 5000; i += 1) {
    const id = `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
    if (!skip.has(id) && cohortFor(id, false) === cohort) return id;
  }
  throw new Error('no profile for cohort');
}

function fakeClient(overrides = {}) {
  const pct5 = profileFor('pct5');
  const all = profileFor('all');
  const tester = profileFor('all', new Set([all]));
  const data = {
    core: { newEvents: 400, newFacts: 900, activeProfiles30d: 50, profilesWithV2Facts: 60, profilesWithSupersededLegacy: 58,
      rateUsed: { rules: 120, sync: 300, 'facts:requests': 40 } },
    corrections: { total: 2, open: 1, shared_eligible: 1, testers: 1 },
    stages: [{ stage: 'category', cases: 2 }],
    templates: { verified: 5, unverified: 3 },
    daily: { hits: '1000', to_review: '50', corrected: '8' },
    profileStats: [
      { profile_id: pct5, hits: '100', to_review: '10', corrected: '1' },
      { profile_id: all, hits: '300', to_review: '30', corrected: '2' },
      { profile_id: tester, hits: '50', to_review: '0', corrected: '0' },
    ],
    testers: [{ profile_id: tester }],
    bundles: [{ cohort: 'all', bundle_version: 4, key_id: 'k1', created_at: NOW, golden_counts: { cases: 10, casesPassed: 10 } }],
    rolledBack: 1,
    ai: [{ day: '2026-11-04', model: 'm', calls: 4, input_tokens: '100', output_tokens: '20', total_tokens: '120', cost_usd: '0.5', calls_without_price: 0 }],
    ...overrides,
  };
  const seen = [];
  return {
    seen,
    async query(sql, params) {
      seen.push({ sql, params });
      if (/sms_v2_template_attempts/.test(sql)) return { rows: data.ai };
      if (/sms_v2_release_metrics/.test(sql)) return { rows: [{ m: data.core }] };
      if (/FROM sms_v2_correction_cases.*GROUP BY stage/s.test(sql)) return { rows: data.stages };
      if (/FROM sms_v2_correction_cases/.test(sql)) return { rows: [data.corrections] };
      if (/sms_v2_template_submitters/.test(sql)) return { rows: [data.templates] };
      if (/sms_v2_rule_stats_daily/.test(sql)) return { rows: [data.daily] };
      if (/sms_v2_rule_stats_profile_daily/.test(sql)) return { rows: data.profileStats };
      if (/sms_v2_testers/.test(sql)) return { rows: data.testers };
      if (/status='rolled_back'/.test(sql)) return { rows: [{ n: data.rolledBack }] };
      if (/FROM sms_v2_bundles/.test(sql)) return { rows: data.bundles };
      throw new Error(`unexpected query: ${sql}`);
    },
  };
}

test('payload carries every go/no-go number and keeps the earlier ai rows', async () => {
  const client = fakeClient();
  const m = await collectMetrics(client, { days: 7, now: NOW });
  assert.equal(m.volume.newEvents, 400);
  assert.equal(m.corrections.cases, 2);
  assert.equal(m.corrections.ratePerNewEvent, 2 / 400);
  assert.equal(m.gates.correctionRate.status, 'pass');
  assert.equal(m.migration.profilesWithSupersededLegacy, 58);
  assert.deepEqual(m.attestation.templateSubmissions, { verified: 5, unverified: 3 });
  assert.equal(m.attestation.correctionsNotShared, 1);
  assert.equal(m.bundleChecks.checks, 120);
  assert.equal(m.bundleChecks.active[0].bundleVersion, 4);
  assert.equal(m.bundleChecks.rolledBackInWindow, 1);
  assert.equal(m.rules.hitRate, 1000 / 1050);
  assert.equal(m.ai.length, 1, 'earlier ai rows are kept');
  assert.equal(m.aiSpend.costUsd, 0.5);
  assert.equal(m.aiSpend.costUsdPer1000ActiveUsers, 10);
});

test('per-cohort rule hits and misses use the cohort hash and the tester list', async () => {
  const m = await collectMetrics(fakeClient(), { days: 7, now: NOW });
  const c = m.rules.perCohort;
  assert.deepEqual([c.pct5.hits, c.pct5.misses, c.pct5.corrected], [100, 10, 1]);
  assert.deepEqual([c.all.hits, c.all.misses], [300, 30]);
  assert.deepEqual([c.testers.hits, c.testers.misses, c.testers.profiles], [50, 0, 1]);
  assert.equal(c.pct25.profiles, 0);
  assert.equal(c.pct25.hitRate, null);
});

test('unmeasurable signals are reported as unavailable, never as zero, and keep the decision incomplete', async () => {
  const m = await collectMetrics(fakeClient(), { days: 7, now: NOW });
  assert.equal(m.syncErrorRate.available, false);
  assert.equal(m.migrationFailureRate.available, false);
  assert.deepEqual(m.missingSignals, ['syncErrorRate', 'migrationFailureRate']);
  assert.equal(m.decision, 'incomplete');
});

test('a correction rate at or over 1% is a no-go', async () => {
  const m = await collectMetrics(fakeClient({ corrections: { total: 4, open: 4, shared_eligible: 0, testers: 0 } }), { days: 7, now: NOW });
  assert.equal(m.corrections.ratePerNewEvent, 0.01);
  assert.equal(m.gates.correctionRate.status, 'fail');
  assert.equal(m.decision, 'no-go');
  assert.equal(GATES.correctionRate.max, 0.01);
});

test('no events gives an unknown rate instead of a divide by zero', async () => {
  const m = await collectMetrics(fakeClient({ core: { newEvents: 0, newFacts: 0, activeProfiles30d: 0, rateUsed: {} }, corrections: { total: 0 } }), { days: 7, now: NOW });
  assert.equal(m.corrections.ratePerNewEvent, null);
  assert.equal(m.gates.correctionRate.status, 'unknown');
  assert.equal(m.aiSpend.costUsdPer1000ActiveUsers, null);
  assert.equal(m.bundleChecks.checks, 0);
});

test('AI spend per 1,000 users is withheld while some calls have no price', async () => {
  const ai = [{ day: '2026-11-04', model: 'm', calls: 4, total_tokens: '10', cost_usd: '0.2', calls_without_price: 2 }];
  const m = await collectMetrics(fakeClient({ ai }), { days: 7, now: NOW });
  assert.equal(m.aiSpend.pricingComplete, false);
  assert.equal(m.aiSpend.callsWithoutPrice, 2);
  assert.equal(m.aiSpend.costUsdPer1000ActiveUsers, null);
});

test('the window is passed to SQL as a timestamp and the days query value is validated', async () => {
  const client = fakeClient();
  await collectMetrics(client, { days: 3, now: NOW });
  const call = client.seen.find((q) => /sms_v2_release_metrics/.test(q.sql));
  assert.equal(call.params[0], '2026-11-02T00:00:00.000Z');
  assert.equal(parseDays(undefined), 7);
  assert.equal(parseDays('30'), 30);
  for (const bad of ['0', '31', '-1', '1.5', 'abc', '07x', '']) assert.throws(() => parseDays(bad), /metrics_days_invalid/);
});

test('handler answers 400 for a bad window and serialises the payload otherwise', async () => {
  const reply = () => {
    const r = { code: 200, body: null };
    r.status = (c) => { r.code = c; return r; };
    r.json = (b) => { r.body = b; return r; };
    return r;
  };
  const ctx = { withAdminClient: (fn) => fn(fakeClient()) };
  const bad = reply();
  await metricsHandler({ query: { days: '99' } }, bad, ctx);
  assert.equal(bad.code, 400);
  assert.equal(bad.body.error, 'metrics_days_invalid');
  const good = reply();
  await metricsHandler({ query: {} }, good, ctx);
  assert.equal(good.code, 200);
  assert.equal(good.body.windowDays, 7);
  assert.ok(Array.isArray(good.body.ai));
});

test('the payload holds no profile ids, message text or secrets', async () => {
  const m = await collectMetrics(fakeClient(), { days: 7, now: NOW });
  const text = JSON.stringify(m);
  assert.doesNotMatch(text, /00000000-0000-4000/);
  assert.doesNotMatch(text, /profile_id|source_key|redacted/);
});
