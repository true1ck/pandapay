'use strict';
// Lane O security audit regressions (docs/sms-pipeline-v2/security-audit-2026-11.md).
//   node --test api/test/sms_v2/security_audit.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('node:zlib');
const express = require('express');

const { registerSmsV2 } = require('../../src/sms_v2');
const { lintPattern } = require('../../src/sms_v2/rules_admin_route');
const { evaluateAutoPause, AUTO_PAUSE_MIN_DEVICES } = require('../../src/sms_v2/rule_stats');
const h = require('./helpers');

const USER = h.uuid4();
const FACTS = '/sms/v2/facts:batch';

async function harness({ checkRate } = {}) {
  const state = { dbCalls: 0, rates: [] };
  const app = express();
  app.use((req, _res, next) => { req.userId = null; next(); });
  const requireAuth = (req, res, next) => {
    req.userId = req.headers['x-user'] || null;
    return req.userId ? next() : res.status(401).json({ error: 'unauthorized' });
  };
  registerSmsV2(app, {
    requireAuth,
    requireAdmin: (req, res) => res.status(403).json({ error: 'Admin access required' }),
    withUserClient: async () => { state.dbCalls += 1; throw new Error('database must not be reached'); },
    readFlag: async () => ({ key: 'sms_pipeline_v2_enabled', is_enabled: true, rollout_percent: 100 }),
    flagCacheMs: 0,
    signer: null,
    hooks: {
      security: {
        verifyAttestation: async () => true,
        checkEntitlement: async () => true,
        checkRate: async (req, route, units) => {
          state.rates.push([route, units]);
          return checkRate ? checkRate(route, units) : true;
        },
      },
    },
    loadUserCardForState: async () => null,
    applyTransactionState: async () => ({}),
    reverseTransactionState: async () => ({}),
  });
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = async (url, payload, { gzip = false } = {}) => {
    let body = Buffer.isBuffer(payload) ? payload : Buffer.from(typeof payload === 'string' ? payload : JSON.stringify(payload));
    const headers = { 'content-type': 'application/json', 'x-user': USER };
    if (gzip) { body = zlib.gzipSync(body); headers['content-encoding'] = 'gzip'; }
    const res = await fetch(base + url, { method: 'POST', headers, body });
    let json = null;
    try { json = await res.json(); } catch (_) { json = null; }
    return { status: res.status, json };
  };
  return { state, post, close: () => { server.closeAllConnections(); server.close(); } };
}

// ---- LO-01: facts:batch side arrays are capped and metered ----

for (const key of ['instruments', 'events', 'ledger']) {
  test(`LO-01: more than 500 ${key} is refused before any database work`, async () => {
    const h1 = await harness();
    try {
      const r = await h1.post(FACTS, h.batch({ [key]: Array.from({ length: 501 }, () => ({})) }));
      assert.equal(r.status, 413);
      assert.equal(r.json.error, 'request.facts_batch.items_too_many');
      assert.equal(h1.state.dbCalls, 0);
    } finally { h1.close(); }
  });
}

test('LO-01: a batch of only events or ledger rows is charged for them, so the daily item limit cannot be skipped', async () => {
  const h1 = await harness({ checkRate: () => ({ ok: false }) });
  try {
    for (const key of ['instruments', 'events', 'ledger']) {
      const r = await h1.post(FACTS, h.batch({ [key]: Array.from({ length: 300 }, () => ({})) }));
      assert.equal(r.status, 429, key);
    }
    assert.deepEqual(h1.state.rates, [['facts:batch', 300], ['facts:batch', 300], ['facts:batch', 300]]);
  } finally { h1.close(); }
});

// ---- LO-02: failed parses still spend budget ----

test('LO-02: unparseable, oversized-inflation and over-count bodies still consume one admission budget', async () => {
  const h1 = await harness();
  try {
    assert.equal((await h1.post(FACTS, '{not json')).status, 400);
    assert.equal((await h1.post(FACTS, Buffer.from('{not json'), { gzip: true })).status, 400);
    const tooMany = await h1.post(FACTS, h.batch({ items: Array.from({ length: 501 }, () => h.item([])) }));
    assert.equal(tooMany.status, 413);
    assert.deepEqual(h1.state.rates.map(([route]) => route), ['facts:batch', 'facts:batch', 'facts:batch']);
    assert.ok(h1.state.rates.every(([, units]) => units >= 1));
  } finally { h1.close(); }
});

test('LO-02: an exhausted budget answers 429 even for a malformed body', async () => {
  const h1 = await harness({ checkRate: () => false });
  try {
    assert.equal((await h1.post(FACTS, '{not json')).status, 429);
  } finally { h1.close(); }
});

// ---- LO-03: regex denial of service ----

test('LO-03: ambiguous alternation under an unbounded quantifier is refused', () => {
  for (const pattern of ['^(a|aa)+$', '(?:a|a)*b', '(?:\\d|\\d\\d)+$', '(?:\\w|\\d)+x', '(?:[a-z ]|\\d|\\s)*$', '(?:a|aa){1,}$', '^((a|aa))+$', '(?:ab|abc)+$', '(?:a|)+b']) {
    assert.ok(lintPattern(pattern, '').length > 0, `${pattern} must be refused`);
  }
});

test('LO-03: ordinary rule shapes still pass the lint', () => {
  for (const pattern of [
    '^(?:rs\\.?|inr)\\s*(?<amt>[\\d,]+(?:\\.\\d{1,2})?)\\s+spent on card x(?<mask>\\d{4})',
    '(?:a|b){2}', '(?:a|b)?c', '(?:x|y)*', '(?:\\s|,)*x', '(?:ab|ac)+', '(?:\\d|[a-f])+', '(?:\\d|\\s)+$', '(?:credited|debited)\\s+by', '(?=a|b)[a-z]+', '(?<m>.+?) on (?<d>\\d{2})',
  ]) {
    assert.deepEqual(lintPattern(pattern, ''), [], `${pattern} must pass`);
  }
});

// ---- LO-04: one account cannot pause a staged rule ----

test('LO-04: auto-pause needs several distinct devices, not one account\'s counters', () => {
  const rules = [{ ruleId: 'R', version: 1 }, { ruleId: 'R', version: 2 }];
  const cohorts = [{ ruleId: 'R', version: 1, cohort: 'all', pausedAt: null }, { ruleId: 'R', version: 2, cohort: 'pct5', pausedAt: null }];
  const run = (devices) => evaluateAutoPause({ rules, cohorts, stats: [{ ruleId: 'R', version: 2, hits: 1000000, corrected: 1000000, devices }] });
  assert.ok(AUTO_PAUSE_MIN_DEVICES >= 3);
  assert.deepEqual(run(1), []);
  assert.deepEqual(run(AUTO_PAUSE_MIN_DEVICES - 1), []);
  assert.equal(run(AUTO_PAUSE_MIN_DEVICES).length, 1);
});

// ---- LO-08: rule-stats rows cannot be used to bloat the shared tables ----

test('LO-08: rule-stats refuses unbounded version strings, rule ids, row counts and counters', async () => {
  const { createStatsHandler } = require('../../src/sms_v2/rule_stats');
  const stored = [];
  const store = { tx: async (_user, fn) => fn({ recordRuleStats: async (...args) => { stored.push(args); } }) };
  const handler = createStatsHandler({ store, security: { verifyAttestation: async () => true, checkRate: async () => true } });
  const row = (over = {}) => ({ ruleId: 'R-1', ruleVersion: 1, hits: 5, toReview: 0, corrected: 0, ...over });
  const call = async (body) => {
    const out = {};
    const res = { status(code) { out.status = code; return this; }, json(value) { out.json = value; return this; } };
    await handler({ body, userId: 'u', headers: {} }, res);
    return out;
  };
  const good = { day: new Date().toISOString().slice(0, 10), appVersion: '1.2.3+45', bundleVersion: 1, stats: [row()] };
  assert.equal((await call(good)).status, 202);
  for (const bad of [
    { ...good, appVersion: 'x'.repeat(41) },
    { ...good, appVersion: '1.0 <script>' },
    { ...good, stats: [row({ ruleId: 'r'.repeat(300) })] },
    { ...good, stats: [row({ ruleId: 'bad id with spaces' })] },
    { ...good, stats: Array.from({ length: 501 }, (_, i) => row({ ruleId: `R-${i}` })) },
    { ...good, stats: [row({ hits: 1e9 })] },
  ]) {
    const out = await call(bad);
    assert.equal(out.status, 400, JSON.stringify(bad).slice(0, 80));
  }
  assert.equal(stored.length, 1);
});

// ---- LO-07: a consenting phone still shares only the reviewed fields ----

test('LO-07: shared corrections keep only category and merchantKey, never free text', async () => {
  const crypto = require('node:crypto');
  const { submitCorrection } = require('../../src/sms_v2/corrections_route');
  const base = require('../../../contracts/sms/v2/fixtures/valid/request.corrections/wrong_category.json');
  const redactedTemplate = 'Rs.<AMT> spent at <PARTY>';
  const hash = crypto.createHash('sha256').update('HDFCBK\n' + redactedTemplate).digest('hex');
  let inserted;
  const client = { query: async (sql, args) => {
    if (sql.includes('FROM sms_v2_facts')) return { rows: base.factIds.map((fact_id) => ({ fact_id, source_key: base.sourceKey })) };
    if (sql.includes('FROM sms_v2_events')) return { rows: [{ event_id: base.eventId }] };
    if (sql.includes('sms_shared_learning_granted')) return { rows: [{ shared: true }] };
    inserted = args; return { rows: [{ case_id: 'case' }] };
  } };
  const body = { ...base, redactedTemplate, corrected: {
    category: 'dining', merchantKey: 'SYNTHETIC SHOP', rawBody: 'a pasted private message', note: 'x'.repeat(5000),
    _template: { senderBrand: 'HDFCBK', hash, observedAt: '2026-11-01T12:00:00Z' },
  } };
  await submitCorrection(client, 'profile', body, { sharedLearningEligible: true });
  assert.deepEqual(inserted[7], { category: 'dining', merchantKey: 'SYNTHETIC SHOP' });
  await submitCorrection(client, 'profile', { ...body, corrected: { ...body.corrected, category: 'x'.repeat(500) } }, { sharedLearningEligible: true });
  assert.deepEqual(inserted[7], { merchantKey: 'SYNTHETIC SHOP' });
});
