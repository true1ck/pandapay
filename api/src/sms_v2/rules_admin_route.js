'use strict';

// Admin rule management (WP-09): list, draft, publish, pause, rollback, bundles.
// Every mutation runs in one store transaction under an advisory lock, mints the
// bundles whose manifest changed, and writes admin_audit_log.

const fs = require('node:fs');
const path = require('node:path');
const express = require('express');
const { createPgStore } = require('./rules_store');
const { createRequireSmsV2 } = require('./guard');
const { signerFromEnv } = require('./signer');
const { validateRequest, validateBundle } = require('./contracts');
const {
  COHORT_RANK, ruleManifest, partsOf, buildManifest, candidateBundle, contentSha256, mintBundles, PARTS_KEY,
} = require('./bundle_builder');
const { pauseRuleVersion, AUTO_PAUSE_REASON } = require('./rule_stats');
const { utcDay } = require('./rules_store');

class HttpError extends Error {
  constructor(status, code, detail) { super(code); this.status = status; this.code = code; this.detail = detail; }
}

// ---------- regex dialect lint ----------

// Dialect: no backreferences, no nested quantifiers. The regex must also compile in JS.
function lintPattern(pattern, flags = '') {
  const problems = [];
  try { new RegExp(pattern, flags); } catch (e) { return [`does not compile: ${e.message}`]; }
  if (/\\[1-9]/.test(pattern.replace(/\\\\/g, '')) || /\\k</.test(pattern)) problems.push('backreferences are not allowed');
  const frames = [{ varQuant: false }];
  let inClass = false;
  const quantAt = (i) => {
    const c = pattern[i];
    if (c === '*' || c === '+') return { len: 1, variable: true, repeat: true };
    if (c === '?') return { len: 1, variable: false, repeat: false };
    if (c === '{') {
      const m = /^\{(\d+)(,(\d*))?\}/.exec(pattern.slice(i));
      if (!m) return null;
      const min = Number(m[1]);
      const open = m[2] !== undefined && m[3] === '';
      const max = m[2] === undefined ? min : (open ? Infinity : Number(m[3]));
      return { len: m[0].length, variable: max > min, repeat: max > 1 };
    }
    return null;
  };
  let lastAtomWasGroupWithVar = false;
  for (let i = 0; i < pattern.length; i += 1) {
    const c = pattern[i];
    if (c === '\\') { i += 1; lastAtomWasGroupWithVar = false; continue; }
    if (inClass) { if (c === ']') inClass = false; continue; }
    if (c === '[') { inClass = true; lastAtomWasGroupWithVar = false; continue; }
    if (c === '(') { frames.push({ varQuant: false }); lastAtomWasGroupWithVar = false; continue; }
    if (c === ')') {
      const f = frames.pop() || { varQuant: false };
      if (frames.length === 0) frames.push({ varQuant: false });
      lastAtomWasGroupWithVar = f.varQuant;
      if (f.varQuant) frames[frames.length - 1].varQuant = true;
      continue;
    }
    const q = quantAt(i);
    if (q) {
      if (lastAtomWasGroupWithVar && q.repeat) problems.push('nested quantifiers are not allowed');
      if (q.variable) frames[frames.length - 1].varQuant = true;
      i += q.len - 1;
      lastAtomWasGroupWithVar = false;
      continue;
    }
    lastAtomWasGroupWithVar = false;
  }
  return [...new Set(problems)];
}

// ---------- golden report and gates ----------

let gatesCache = null;
function loadGates() {
  if (gatesCache) return gatesCache;
  const file = process.env.SMS_V2_GATES_PATH
    ? path.resolve(process.env.SMS_V2_GATES_PATH)
    : path.resolve(__dirname, '../../../tools/sms_golden/gates.json');
  gatesCache = JSON.parse(fs.readFileSync(file, 'utf8'));
  return gatesCache;
}

function reportCounts(report) {
  if (Number.isInteger(report.total) && Number.isInteger(report.passed)) return { total: report.total, passed: report.passed };
  const c = report.counts;
  if (c && Number.isInteger(c.cases) && Number.isInteger(c.casesPassed)) return { total: c.cases, passed: c.casesPassed };
  return null;
}

// Returns null when the report is acceptable, else {code, detail}.
function checkGoldenReport(report, candidateSha, gates) {
  if (!report || typeof report !== 'object') return { code: 'golden_report_required' };
  if (report.bundleSha256 !== candidateSha) return { code: 'golden_report_hash_mismatch', detail: 'goldenReport.bundleSha256 does not match the candidate bundle' };
  const counts = reportCounts(report);
  if (!counts || counts.total < 1 || counts.passed !== counts.total) return { code: 'golden_report_failing', detail: 'every golden case must pass' };
  if (report.counts && report.counts.scenariosEvaluated && report.counts.scenariosPassed !== report.counts.scenarios) {
    return { code: 'golden_report_failing', detail: 'every golden scenario must pass' };
  }
  const failed = [];
  const profile = (gates && gates.m1) || {};
  const metrics = report.metrics || {};
  for (const [name, bound] of Object.entries(profile)) {
    const m = metrics[name];
    if (!m || m.status === 'not_available' || m.value === null || m.value === undefined) continue; // skipped, not failed
    if (bound.min !== undefined && m.value < bound.min) failed.push(`${name} ${m.value} < ${bound.min}`);
    if (bound.max !== undefined && m.value > bound.max) failed.push(`${name} ${m.value} > ${bound.max}`);
  }
  if (failed.length) return { code: 'golden_report_gate_failed', detail: failed.join('; ') };
  return null;
}

// ---------- operations (shared with the import script) ----------

const nowIso = (now) => now.toISOString().replace(/\.\d{3}Z$/, 'Z');

async function importBundle(s, bundle, { signer, adminId = null, now = new Date() }) {
  const check = validateBundle(bundle);
  if (!check.ok) throw new HttpError(400, 'bundle_invalid', check.errors.map((e) => `${e.code}@${e.path}`).join(', '));
  await s.lock();
  await s.setParts(partsOf(bundle));
  let inserted = 0;
  for (const r of bundle.rules) {
    if (await s.getRule(r.id, 1)) continue;
    // Only active rules are released; provisional (AI) rules stay out of the public bundle.
    const body = { ...r, version: 1 };
    await s.insertRule({ ruleId: r.id, version: 1, status: r.status, family: r.family, senders: r.senders, body, createdBy: r.createdBy || 'import' });
    inserted += 1;
  }
  // Every imported version 1 is on cohort all (idempotent).
  for (const row of await s.allRules()) {
    if (row.version === 1 && row.status === 'active') await s.addCohort({ ruleId: row.ruleId, version: 1, cohort: 'all', startedAt: nowIso(now) });
  }
  const minted = await mintBundles(s, { signer, now, publishedBy: 'import' });
  if (inserted || minted.length) {
    await s.audit({ adminId, action: 'sms_v2_rules_import', after: { rulesInserted: inserted, bundles: minted.map((m) => m.bundleVersion) } });
  }
  return { rulesInserted: inserted, minted };
}

async function saveDraft(s, ruleId, body, { adminId, now }) {
  const issues = lintPattern(body.match.pattern, body.match.flags);
  if (issues.length) throw new HttpError(422, 'rule_pattern_invalid', issues.join('; '));
  await s.lock();
  const versions = await s.ruleVersions(ruleId);
  const latest = versions[versions.length - 1];
  const reuse = latest && latest.status === 'draft';
  const version = reuse ? latest.version : (latest ? latest.version + 1 : 1);
  const stored = { ...body, id: ruleId, version, status: 'draft', updatedAt: nowIso(now) };
  const row = { ruleId, version, status: 'draft', family: body.family, senders: body.senders, body: stored, createdBy: String(adminId || body.createdBy) };
  if (reuse) await s.updateRule(row); else await s.insertRule(row);
  await s.audit({ adminId, action: 'sms_v2_rule_draft', before: reuse ? { ruleId, version } : null, after: { ruleId, version } });
  return { ruleId, version, status: 'draft' };
}

async function publishVersion(s, ruleId, { version, cohort, goldenReport }, { signer, adminId, now, gates }) {
  await s.lock();
  const row = await s.getRule(ruleId, version);
  if (!row) throw new HttpError(404, 'rule_version_not_found');
  if (row.status === 'paused' || row.status === 'retired') throw new HttpError(409, 'rule_version_not_publishable', `status is ${row.status}`);
  const cohorts = await s.allCohorts();
  const live = cohorts.filter((c) => c.ruleId === ruleId && c.version === version && !c.pausedAt);
  if (live.some((c) => COHORT_RANK[c.cohort] > COHORT_RANK[cohort])) throw new HttpError(409, 'cohort_narrowing', 'a version can only be promoted to a wider cohort');
  const parts = await s.getParts();
  if (parts.minEngineVersion === undefined) throw new HttpError(409, 'bundle_parts_missing', 'import the baseline bundle first');
  const activated = { ...row, status: 'active', body: { ...row.body, status: 'active' } };
  const rules = (await s.allRules()).map((r) => (r.ruleId === ruleId && r.version === version ? activated : r));
  const prospective = [...cohorts.filter((c) => !(c.ruleId === ruleId && c.version === version && c.cohort === cohort)), { ruleId, version, cohort, pausedAt: null }];
  const manifest = buildManifest(cohort, rules, prospective, parts);
  const candidate = candidateBundle({ manifest, rules, parts, now });
  const sha = contentSha256(candidate);
  const refusal = checkGoldenReport(goldenReport, sha, gates);
  if (refusal) throw new HttpError(422, refusal.code, refusal.detail);
  await s.updateRule(activated);
  await s.addCohort({ ruleId, version, cohort, startedAt: nowIso(now) });
  const minted = await mintBundles(s, { signer, now, publishedBy: String(adminId), goldenReport });
  await s.audit({ adminId, action: 'sms_v2_rule_publish', before: { ruleId, version, status: row.status }, after: { ruleId, version, cohort, contentSha256: sha, bundles: minted.map((m) => m.bundleVersion) } });
  return { ruleId, version, cohort, contentSha256: sha, bundles: minted.map((m) => ({ bundleVersion: m.bundleVersion, cohort: m.cohort })) };
}

async function pauseVersion(s, ruleId, { reason, version }, { signer, adminId, now }) {
  await s.lock();
  const cohorts = await s.allCohorts();
  let target = version;
  if (target === undefined) {
    target = Math.max(0, ...cohorts.filter((c) => c.ruleId === ruleId && !c.pausedAt).map((c) => c.version));
  }
  if (!target || !cohorts.some((c) => c.ruleId === ruleId && c.version === target && !c.pausedAt)) throw new HttpError(404, 'no_live_version');
  await pauseRuleVersion(s, { ruleId, version: target, reason, adminId, now });
  const minted = await mintBundles(s, { signer, now, publishedBy: String(adminId) });
  return { ruleId, version: target, paused: true, bundles: minted.map((m) => ({ bundleVersion: m.bundleVersion, cohort: m.cohort })) };
}

async function rollbackRule(s, ruleId, { toVersion, reason }, { signer, adminId, now }) {
  await s.lock();
  const old = await s.getRule(ruleId, toVersion);
  if (!old) throw new HttpError(404, 'rule_version_not_found');
  const cohorts = await s.allCohorts();
  if (!cohorts.some((c) => c.ruleId === ruleId && c.version === toVersion)) throw new HttpError(409, 'version_never_published');
  const versions = await s.ruleVersions(ruleId);
  const version = versions[versions.length - 1].version + 1;
  const body = { ...old.body, version, status: 'active', updatedAt: nowIso(now) };
  await s.insertRule({ ruleId, version, status: 'active', family: old.family, senders: old.senders, body, createdBy: String(adminId) });
  await s.addCohort({ ruleId, version, cohort: 'all', startedAt: nowIso(now) });
  const minted = await mintBundles(s, { signer, now, publishedBy: String(adminId), supersededStatus: 'rolled_back' });
  await s.audit({ adminId, action: 'sms_v2_rule_rollback', before: { ruleId }, after: { ruleId, restoredFrom: toVersion, version, bundles: minted.map((m) => m.bundleVersion) }, reason });
  return { ruleId, version, restoredFrom: toVersion, bundles: minted.map((m) => ({ bundleVersion: m.bundleVersion, cohort: m.cohort })) };
}

// ---------- read models ----------

function widestLive(cohortRows) {
  const live = cohortRows.filter((c) => !c.pausedAt);
  if (!live.length) return null;
  return live.sort((a, b) => COHORT_RANK[b.cohort] - COHORT_RANK[a.cohort])[0].cohort;
}

async function listRules(s, query, now) {
  const rules = await s.allRules();
  const cohorts = await s.allCohorts();
  const stats = await s.statsSince(utcDay(new Date(now.getTime() - 7 * 86400000)));
  const out = [];
  const ids = [...new Set(rules.map((r) => r.ruleId))].sort();
  for (const id of ids) {
    const versions = rules.filter((r) => r.ruleId === id);
    const latest = versions[versions.length - 1];
    if (query.status && latest.status !== query.status) continue;
    if (query.family && latest.family !== query.family) continue;
    if (query.sender && !latest.senders.includes(query.sender)) continue;
    if (query.q && !`${id} ${latest.family}`.toLowerCase().includes(String(query.q).toLowerCase())) continue;
    const mine = stats.filter((x) => x.ruleId === id);
    const sum = (k) => mine.reduce((a, x) => a + x[k], 0);
    const rowCohorts = cohorts.filter((c) => c.ruleId === id && c.version === latest.version);
    out.push({
      ruleId: id, latestVersion: latest.version, status: latest.status, family: latest.family, senders: latest.senders,
      cohort: widestLive(rowCohorts),
      autoPaused: cohorts.some((c) => c.ruleId === id && c.pauseReason === AUTO_PAUSE_REASON),
      metrics7d: { hits: sum('hits'), toReview: sum('toReview'), corrected: sum('corrected') },
    });
  }
  return out;
}

async function ruleDetail(s, ruleId, now) {
  const versions = await s.ruleVersions(ruleId);
  if (!versions.length) throw new HttpError(404, 'rule_not_found');
  const cohorts = (await s.allCohorts()).filter((c) => c.ruleId === ruleId);
  const stats = await s.statsSince(utcDay(new Date(now.getTime() - 7 * 86400000)));
  return {
    ruleId,
    versions: versions.map((v) => {
      const m = stats.find((x) => x.ruleId === ruleId && x.version === v.version);
      return {
        version: v.version, status: v.status, createdBy: v.createdBy, createdAt: v.createdAt, body: v.body,
        cohorts: cohorts.filter((c) => c.version === v.version).map((c) => ({ cohort: c.cohort, startedAt: c.startedAt, pausedAt: c.pausedAt, pauseReason: c.pauseReason })),
        metrics7d: m ? { hits: m.hits, toReview: m.toReview, corrected: m.corrected, devices: m.devices } : { hits: 0, toReview: 0, corrected: 0, devices: 0 },
        goldenCoverage: { exampleCount: Array.isArray(v.body.examples) ? v.body.examples.length : 0 },
      };
    }),
  };
}

// ---------- routes ----------

function registerRuleHandlers(router, deps) {
  const { storeFor, getSigner, getGates = loadGates, now = () => new Date() } = deps;

  const wrap = (fn) => async (req, res) => {
    try {
      await fn(req, res);
    } catch (err) {
      if (err && err.code === 'ADMIN_PERMISSION_DENIED') return res.status(403).json({ error: 'admin_permission_required' });
      if (err instanceof HttpError) return res.status(err.status).json({ error: err.code, ...(err.detail ? { detail: err.detail } : {}) });
      if (err && err.code === 'signing_unavailable') return res.status(503).json({ error: 'signing_unavailable' });
      if (err && err.code === 'bundle_invalid') return res.status(422).json({ error: 'bundle_invalid', detail: JSON.stringify(err.details) });
      console.error('sms_v2 rules admin failed', err && (err.code || err.name));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
  const validate = (route, body) => {
    const check = validateRequest(route, body);
    if (!check.ok) throw new HttpError(400, check.errors[0].code, check.errors.map((e) => `${e.code}@${e.path}`).join(', '));
  };
  const ctx = (req) => ({ signer: getSigner(), adminId: req.userId, now: now() });

  router.get('/rules', wrap(async (req, res) => {
    const rules = await storeFor(req).tx(req.userId, (s) => listRules(s, req.query, now()));
    res.json({ rules });
  }));
  router.get('/rules/:id', wrap(async (req, res) => {
    res.json(await storeFor(req).tx(req.userId, (s) => ruleDetail(s, req.params.id, now())));
  }));
  router.put('/rules/:id/draft', wrap(async (req, res) => {
    validate('admin_rule_draft', req.body);
    if (req.body.id !== req.params.id) throw new HttpError(400, 'rule_id_mismatch');
    res.json(await storeFor(req).tx(req.userId, (s) => saveDraft(s, req.params.id, req.body, ctx(req))));
  }));
  router.get('/rules/:id/candidate', wrap(async (req, res) => {
    const version = Number(req.query.version);
    const cohort = String(req.query.cohort || '');
    if (!Number.isInteger(version) || !(cohort in COHORT_RANK)) throw new HttpError(400, 'candidate_query_invalid');
    const out = await storeFor(req).tx(req.userId, async (s) => {
      const row = await s.getRule(req.params.id, version);
      if (!row) throw new HttpError(404, 'rule_version_not_found');
      const parts = await s.getParts();
      const cohorts = await s.allCohorts();
      const rules = (await s.allRules()).map((r) => (r === row || (r.ruleId === row.ruleId && r.version === version) ? { ...r, status: 'active', body: { ...r.body, status: 'active' } } : r));
      const prospective = [...cohorts.filter((c) => !(c.ruleId === row.ruleId && c.version === version && c.cohort === cohort)), { ruleId: row.ruleId, version, cohort, pausedAt: null }];
      const bundle = candidateBundle({ manifest: buildManifest(cohort, rules, prospective, parts), rules, parts, now: now() });
      return { contentSha256: contentSha256(bundle), bundle };
    });
    res.json(out);
  }));
  router.post('/rules/:id/publish', wrap(async (req, res) => {
    validate('admin_rule_publish', req.body);
    res.json(await storeFor(req).tx(req.userId, (s) => publishVersion(s, req.params.id, req.body, { ...ctx(req), gates: getGates() })));
  }));
  router.post('/rules/:id/pause', wrap(async (req, res) => {
    validate('admin_rule_pause', req.body);
    const version = req.query.version === undefined ? undefined : Number(req.query.version);
    if (version !== undefined && !Number.isInteger(version)) throw new HttpError(400, 'version_invalid');
    res.json(await storeFor(req).tx(req.userId, (s) => pauseVersion(s, req.params.id, { reason: req.body.reason, version }, ctx(req))));
  }));
  router.post('/rules/:id/rollback', wrap(async (req, res) => {
    validate('admin_rule_rollback', req.body);
    res.json(await storeFor(req).tx(req.userId, (s) => rollbackRule(s, req.params.id, req.body, ctx(req))));
  }));
  router.get('/bundles', wrap(async (req, res) => {
    const rows = await storeFor(req).tx(req.userId, (s) => s.listBundles(100));
    res.json({ bundles: rows.map((b) => ({ bundleVersion: b.bundleVersion, cohort: b.cohort, status: b.status, manifest: b.manifest, sha256: b.sha256, keyId: b.keyId, publishedBy: b.publishedBy, createdAt: b.createdAt })) });
  }));

}

// Explicit standalone adapter for focused service tests. Production registers
// these handlers exclusively through the private admin registrar below.
function registerRulesAdminRoutes(app, deps) {
  const router = express.Router();
  router.use(deps.requireSmsV2, deps.requireAdmin);
  registerRuleHandlers(router, { ...deps, storeFor: () => deps.store });
  app.use('/admin/sms/v2', router);
}

function registerPrivateRulesAdminRoutes(api, deps = {}) {
  let signer = deps.signer;
  if (signer === undefined) {
    try { signer = signerFromEnv(); } catch { signer = null; }
  }
  const requestStores = new WeakMap();
  const router = {};
  for (const method of ['get', 'put', 'post']) {
    router[method] = (path, handler) => api.route(method, `/admin/sms/v2${path}`, async (req, res, ctx) => {
      req.userId = req.admin.userId;
      const withPrivateClient = (_actorId, operation) => ctx.withAdminClient(operation);
      requestStores.set(req, deps.store || createPgStore({ withUserClient: withPrivateClient }));
      const requireSmsV2 = createRequireSmsV2({ withUserClient: withPrivateClient, cacheMs: 0 });
      return requireSmsV2(req, res, () => handler(req, res));
    });
  }
  registerRuleHandlers(router, { ...deps, getSigner: () => signer, storeFor: req => requestStores.get(req) });
}

module.exports = {
  registerRulesAdminRoutes, registerPrivateRulesAdminRoutes, lintPattern, checkGoldenReport, loadGates, importBundle, saveDraft, publishVersion,
  pauseVersion, rollbackRule, listRules, ruleDetail, HttpError, PARTS_KEY, ruleManifest,
};
