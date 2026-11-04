'use strict';

// GET /admin/sms/v2/metrics?days=7 (Lane C): the release go/no-go numbers.
//
// Registered by registerPrivateTemplateRoutes (ai_templates.js), which already
// supplies admin authentication (learning.read), the sms_pipeline_v2_enabled
// guard and error mapping. The payload keeps the earlier `ai` rows (daily AI
// usage for 30 days) and adds everything below. Cross-profile counts come from
// pandapay.sms_v2_release_metrics, an aggregate-only security-definer function,
// because the v2 event, fact and rate tables are owner-scoped.
//
// Signals the server cannot see are reported as {available:false, reason} and
// are never guessed: sync errors and migration failures happen on the phone.

const { cohortFor } = require('./bundle_builder');

// Limits from docs/sms-pipeline-v2/test-and-release.md (staged rollout go/no-go).
const GATES = Object.freeze({
  correctionRate: Object.freeze({ max: 0.01 }),
  syncErrorRate: Object.freeze({ max: 0.01 }),
  migrationFailureRate: Object.freeze({ max: 0.005 }),
});
const COHORTS = ['testers', 'pct5', 'pct25', 'all'];
const DEFAULT_DAYS = 7;
const MAX_DAYS = 30;

class MetricsInputError extends Error {}

function parseDays(raw) {
  if (raw === undefined) return DEFAULT_DAYS;
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (!/^[0-9]{1,2}$/.test(String(text))) throw new MetricsInputError('metrics_days_invalid');
  const days = Number(text);
  if (days < 1 || days > MAX_DAYS) throw new MetricsInputError('metrics_days_invalid');
  return days;
}

const num = (value) => (value === null || value === undefined ? 0 : Number(value));
const ratio = (top, bottom) => (bottom > 0 ? top / bottom : null);

function judge(value, max) {
  if (value === null || value === undefined) return 'unknown';
  return value < max ? 'pass' : 'fail';
}

const unavailable = (reason) => ({ available: false, reason });

async function aiRows(client) {
  const result = await client.query(
    `SELECT (started_at AT TIME ZONE 'utc')::date AS day,model,count(*)::int AS calls,
        sum(input_tokens)::bigint AS input_tokens,sum(output_tokens)::bigint AS output_tokens,
        sum(total_tokens)::bigint AS total_tokens,sum(cost_usd) AS cost_usd,
        count(*) FILTER(WHERE cost_usd IS NULL)::int AS calls_without_price
       FROM sms_v2_template_attempts WHERE started_at >= now()-interval '30 days' GROUP BY 1,2 ORDER BY 1 DESC,2`,
  );
  return result.rows;
}

function summariseAi(rows, activeProfiles30d) {
  let calls = 0;
  let withoutPrice = 0;
  let tokens = 0;
  let cost = 0;
  for (const row of rows) {
    calls += num(row.calls);
    withoutPrice += num(row.calls_without_price);
    tokens += num(row.total_tokens);
    cost += num(row.cost_usd);
  }
  const pricingComplete = withoutPrice === 0;
  return {
    windowDays: 30,
    calls,
    totalTokens: tokens,
    costUsd: Number(cost.toFixed(6)),
    callsWithoutPrice: withoutPrice,
    pricingComplete,
    activeProfiles30d,
    // Per-1,000-active-users monthly cost (budget table). Null when it cannot be stated honestly.
    costUsdPer1000ActiveUsers: pricingComplete && activeProfiles30d > 0
      ? Number(((cost / activeProfiles30d) * 1000).toFixed(6)) : null,
  };
}

async function cohortRuleStats(client, sinceDay) {
  const stats = await client.query(
    `SELECT profile_id,sum(hits)::bigint AS hits,sum(to_review)::bigint AS to_review,sum(corrected)::bigint AS corrected
       FROM sms_v2_rule_stats_profile_daily WHERE day >= $1::date GROUP BY profile_id`,
    [sinceDay],
  );
  const testers = await client.query('SELECT profile_id FROM sms_v2_testers');
  const testerIds = new Set(testers.rows.map((row) => String(row.profile_id).toLowerCase()));
  const out = Object.fromEntries(COHORTS.map((cohort) => [cohort, { profiles: 0, hits: 0, toReview: 0, corrected: 0 }]));
  for (const row of stats.rows) {
    const id = String(row.profile_id).toLowerCase();
    const bucket = out[cohortFor(id, testerIds.has(id))];
    bucket.profiles += 1;
    bucket.hits += num(row.hits);
    bucket.toReview += num(row.to_review);
    bucket.corrected += num(row.corrected);
  }
  for (const bucket of Object.values(out)) {
    // A "miss" is a message the rules left for review; a hit is one a rule handled.
    bucket.misses = bucket.toReview;
    bucket.hitRate = ratio(bucket.hits, bucket.hits + bucket.toReview);
    bucket.correctionRate = ratio(bucket.corrected, bucket.hits);
  }
  return out;
}

async function collectMetrics(client, { days = DEFAULT_DAYS, now = new Date() } = {}) {
  const since = new Date(now.getTime() - days * 86400000);
  const sinceDay = since.toISOString().slice(0, 10);
  // One pooled client runs one query at a time, so these are awaited in turn.
  const iso = since.toISOString();
  const ai = await aiRows(client);
  const core = await client.query('SELECT pandapay.sms_v2_release_metrics($1) AS m', [iso]);
  const corrections = await client.query(
    `SELECT count(*)::int AS total,count(*) FILTER(WHERE status='open')::int AS open,
        count(*) FILTER(WHERE shared_learning_eligible)::int AS shared_eligible,
        count(*) FILTER(WHERE is_tester)::int AS testers
       FROM sms_v2_correction_cases WHERE created_at >= $1`,
    [iso],
  );
  const stages = await client.query('SELECT stage,count(*)::int AS cases FROM sms_v2_correction_cases WHERE created_at >= $1 GROUP BY stage ORDER BY stage', [iso]);
  const templates = await client.query(
    `SELECT count(*) FILTER(WHERE eligible)::int AS verified,count(*) FILTER(WHERE NOT eligible)::int AS unverified
       FROM sms_v2_template_submitters WHERE last_submitted >= $1`,
    [iso],
  );
  const daily = await client.query(
    `SELECT coalesce(sum(hits),0)::bigint AS hits,coalesce(sum(to_review),0)::bigint AS to_review,
        coalesce(sum(corrected),0)::bigint AS corrected
       FROM sms_v2_rule_stats_daily WHERE day >= $1::date`,
    [sinceDay],
  );
  const perCohort = await cohortRuleStats(client, sinceDay);
  const bundles = await client.query(
    `SELECT cohort,bundle_version,key_id,created_at,golden_report->'counts' AS golden_counts
       FROM sms_v2_bundles WHERE status='active' ORDER BY cohort`,
  );
  const rolledBack = await client.query("SELECT count(*)::int AS n FROM sms_v2_bundles WHERE status='rolled_back' AND created_at >= $1", [iso]);

  const m = core.rows[0].m || {};
  const rateUsed = m.rateUsed || {};
  const newEvents = num(m.newEvents);
  const correctionRow = corrections.rows[0] || {};
  const correctionCases = num(correctionRow.total);
  const correctionRate = ratio(correctionCases, newEvents);
  const dailyRow = daily.rows[0] || {};
  const hits = num(dailyRow.hits);
  const toReview = num(dailyRow.to_review);
  const corrected = num(dailyRow.corrected);
  const activeProfiles30d = num(m.activeProfiles30d);

  const syncError = unavailable('The phone reports sync failures; the server keeps no per-request outcome store. Use app telemetry.');
  const migrationFailure = unavailable('The migration runs on the phone; its report is not uploaded. Use app telemetry or the owner dry-run report.');
  const gates = {
    correctionRate: { value: correctionRate, limit: GATES.correctionRate.max, status: judge(correctionRate, GATES.correctionRate.max) },
    syncErrorRate: { value: null, limit: GATES.syncErrorRate.max, status: 'unknown' },
    migrationFailureRate: { value: null, limit: GATES.migrationFailureRate.max, status: 'unknown' },
  };
  const statuses = Object.values(gates).map((gate) => gate.status);
  const decision = statuses.includes('fail') ? 'no-go' : statuses.every((s) => s === 'pass') ? 'go' : 'incomplete';

  return {
    generatedAt: now.toISOString(),
    windowDays: days,
    decision,
    missingSignals: Object.keys(gates).filter((key) => gates[key].status === 'unknown'),
    gates,
    volume: { newEvents, newFacts: num(m.newFacts), activeProfiles30d },
    corrections: {
      cases: correctionCases,
      open: num(correctionRow.open),
      fromTesters: num(correctionRow.testers),
      sharedLearningEligible: num(correctionRow.shared_eligible),
      byStage: Object.fromEntries(stages.rows.map((row) => [row.stage, row.cases])),
      // Cases created in the window over events written in the window (an event
      // counts again when the linker updates it, so the rate can read slightly low).
      ratePerNewEvent: correctionRate,
    },
    syncErrorRate: syncError,
    migrationFailureRate: migrationFailure,
    migration: {
      profilesWithV2Facts: num(m.profilesWithV2Facts),
      profilesWithSupersededLegacy: num(m.profilesWithSupersededLegacy),
    },
    attestation: {
      // Template submissions: eligible means verified and consented; held ones were unverified.
      templateSubmissions: { verified: num(templates.rows[0]?.verified), unverified: num(templates.rows[0]?.unverified) },
      correctionsSharedEligible: num(correctionRow.shared_eligible),
      correctionsNotShared: Math.max(0, correctionCases - num(correctionRow.shared_eligible)),
      note: 'Verified and unverified are counted where the server stores the distinction; plain request logs carry the rest.',
    },
    bundleChecks: {
      // Rule downloads admitted by the rate counter; counters are kept for 2 days.
      checks: num(rateUsed.rules),
      syncCalls: num(rateUsed.sync),
      factBatches: num(rateUsed['facts:requests']),
      counterWindowDays: Math.min(days, 2),
      active: bundles.rows.map((row) => ({
        cohort: row.cohort,
        bundleVersion: row.bundle_version,
        keyId: row.key_id,
        createdAt: row.created_at,
        golden: row.golden_counts || null,
      })),
      rolledBackInWindow: num(rolledBack.rows[0]?.n),
    },
    rules: {
      hits,
      toReview,
      corrected,
      hitRate: ratio(hits, hits + toReview),
      correctionRate: ratio(corrected, hits),
      // Profile-level rows are kept 48 hours, so the cohort view covers at most 2 days.
      perCohort,
      perCohortWindowDays: Math.min(days, 2),
    },
    aiSpend: summariseAi(ai, activeProfiles30d),
    ai,
  };
}

// register(method, path, handler) comes from registerPrivateTemplateRoutes.
async function metricsHandler(req, res, ctx) {
  let days;
  try {
    days = parseDays(req.query?.days);
  } catch (error) {
    if (error instanceof MetricsInputError) return res.status(400).json({ error: error.message });
    throw error;
  }
  const payload = await ctx.withAdminClient((client) => collectMetrics(client, { days }));
  return res.json(payload);
}

module.exports = { collectMetrics, metricsHandler, parseDays, summariseAi, GATES };
