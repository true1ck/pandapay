'use strict';

// Rule statistics (WP-09): the phone upload handler, the daily rollup and the
// auto-pause decision.

const { validateRequest } = require('./contracts');
const { COHORT_RANK, mintBundles, refreshServedBundles } = require('./bundle_builder');
const { utcDay } = require('./rules_store');

const AUTO_PAUSE_MIN_HITS = 50;
const AUTO_PAUSE_MIN_RATE = 0.01;
// One account must not be able to pause a staged rule with its own counters.
const AUTO_PAUSE_MIN_DEVICES = 3;
const AUTO_PAUSE_REASON = 'auto_correction_rate';
const AUTO_PAUSE_COHORTS = ['testers', 'pct5', 'pct25'];

const SAFE_VERSION = /^[0-9A-Za-z.+_-]{1,40}$/;
const SAFE_RULE_ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const MAX_STAT_ROWS = 500;
const MAX_COUNTER = 1000000; // per device, per rule version, per day

// POST /sms/v2/rule-stats:batch handler. Auth and the v2 flag are applied by the caller.
function createStatsHandler({ store, security }) {
  return async function ruleStatsHandler(req, res) {
    const check = validateRequest('rule_stats_batch', req.body);
    if (!check.ok) return res.status(400).json({ error: check.errors[0].code, detail: check.errors.map((e) => `${e.code}@${e.path}`).join(', ') });
    const { day, appVersion, stats } = req.body;
    // The contract leaves these open; the shared tables must not grow from them.
    if (!SAFE_VERSION.test(appVersion) || stats.length > MAX_STAT_ROWS ||
        stats.some((x) => !SAFE_RULE_ID.test(x.ruleId) || [x.hits, x.toReview, x.corrected].some((n) => n > MAX_COUNTER))) {
      return res.status(400).json({ error: 'request.rule_stats_batch.counter_invalid' });
    }
    try {
      if (security) {
        const denied = value => value === false || value?.ok === false;
        if (denied(await security.verifyAttestation(req))) return res.status(403).json({ error: 'attestation_required' });
        if (denied(await security.checkRate(req, 'rule-stats', 1))) return res.status(429).json({ error: 'rate_limited' });
      }
      // Device telemetry may influence global pause decisions. Unverified
      // requests retain admission telemetry, but cannot alter shared rollups.
      if (req.smsV2Security?.sharedLearningEligible === false) return res.status(202).json({});

      await store.tx(req.userId, (s) => s.recordRuleStats(req.userId, day, appVersion, stats));
    } catch (err) {
      console.error('sms_v2 rule stats failed', err && err.code);
      return res.status(503).json({ error: 'rule_stats_unavailable' });
    }
    return res.status(202).json({});
  };
}

// Pure decision. `stats`: [{ruleId, version, hits, corrected}] for the last 24 hours.
// `rules`/`cohorts`: all rule rows and cohort rows. Returns the versions to pause.
function evaluateAutoPause({ rules, cohorts, stats, minHits = AUTO_PAUSE_MIN_HITS, minRate = AUTO_PAUSE_MIN_RATE }) {
  const byKey = new Map(stats.map((x) => [`${x.ruleId}\u0000${x.version}`, x]));
  const rate = (x) => (x && x.hits > 0 ? x.corrected / x.hits : 0);
  const released = new Map(); // key -> widest unpaused cohort rank
  const everReleased = new Set();
  for (const c of cohorts) {
    everReleased.add(`${c.ruleId}\u0000${c.version}`);
    if (c.pausedAt) continue;
    const k = `${c.ruleId}\u0000${c.version}`;
    released.set(k, Math.max(released.get(k) ?? -1, COHORT_RANK[c.cohort]));
  }
  const out = [];
  for (const [k, widest] of released) {
    if (widest >= COHORT_RANK.all) continue;
    const cur = byKey.get(k);
    if (!cur || cur.hits < minHits) continue;
    if (Number.isFinite(cur.devices) && cur.devices < AUTO_PAUSE_MIN_DEVICES) continue;
    const [ruleId, vs] = k.split('\u0000');
    const version = Number(vs);
    const prev = rules
      .filter((r) => r.ruleId === ruleId && r.version < version && everReleased.has(`${ruleId}\u0000${r.version}`))
      .sort((a, b) => b.version - a.version)[0];
    const prevRate = prev ? rate(byKey.get(`${ruleId}\u0000${prev.version}`)) : 0;
    const threshold = Math.max(minRate, 2 * prevRate);
    const r = rate(cur);
    if (r > threshold) out.push({ ruleId, version, hits: cur.hits, corrected: cur.corrected, rate: r, threshold });
  }
  return out.sort((a, b) => a.ruleId.localeCompare(b.ruleId) || a.version - b.version);
}

// Pause one version in every cohort it was released to, mark it paused, audit.
async function pauseRuleVersion(s, { ruleId, version, reason, adminId, now }) {
  const row = await s.getRule(ruleId, version);
  if (!row) return null;
  await s.pauseVersion(ruleId, version, reason, now.toISOString());
  await s.updateRule({ ...row, status: 'paused', body: { ...row.body, status: 'paused' } });
  await s.audit({ adminId, action: 'sms_v2_rule_pause', before: { ruleId, version, status: row.status }, after: { ruleId, version, status: 'paused' }, reason });
  return row;
}

// Hourly job body: roll up, evaluate, pause, re-mint. Returns what was paused.
async function runRuleJobs({ store, signer, adminId, now = new Date(), refreshBeforeMs }) {
  return store.tx(adminId, async (s) => {
    await s.lock();
    const rolled = await s.rollupRuleStats();
    const since = utcDay(new Date(now.getTime() - 24 * 60 * 60 * 1000));
    const stats = await s.statsSince(since);
    // Thresholds and retention are console settings (settings.js).
    const settings = typeof s.settings === 'function' ? await s.settings() : {};
    const toPause = evaluateAutoPause({
      rules: await s.allRules(), cohorts: await s.allCohorts(), stats,
      minHits: settings.auto_pause_min_hits, minRate: settings.auto_pause_min_rate,
    });
    // Shared signals are kept for signals_retention_days only.
    const prunedSignals = typeof s.pruneSignals === 'function' && settings.signals_retention_days
      ? await s.pruneSignals(settings.signals_retention_days) : 0;
    for (const p of toPause) {
      await pauseRuleVersion(s, { ruleId: p.ruleId, version: p.version, reason: AUTO_PAUSE_REASON, adminId, now });
    }
    let minted = [];
    if (toPause.length) minted = await mintBundles(s, { signer, now, publishedBy: 'auto_pause' });
    // The public API only serves pre-signed bundles, so this job also keeps their expiry fresh.
    const refreshed = await refreshServedBundles(s, { signer, now, refreshBeforeMs });
    return { rolledUp: rolled, prunedSignals, paused: toPause, minted: minted.map((m) => ({ bundleVersion: m.bundleVersion, cohort: m.cohort })), refreshed };
  });
}

module.exports = {
  AUTO_PAUSE_MIN_HITS, AUTO_PAUSE_MIN_DEVICES, AUTO_PAUSE_MIN_RATE, AUTO_PAUSE_REASON, AUTO_PAUSE_COHORTS,
  createStatsHandler, evaluateAutoPause, pauseRuleVersion, runRuleJobs,
};
