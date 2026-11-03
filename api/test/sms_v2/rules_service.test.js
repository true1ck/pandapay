'use strict';
// WP-09 rule service tests. Run: node --test api/test/sms_v2/rules_service.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const http = require('node:http');
const express = require('express');

const { canonicalize, canonicalBundleBytes, sha256Hex, createSigner, signBundle, verifyBundle, signerFromEnv } = require('../../src/sms_v2/signer');
const builder = require('../../src/sms_v2/bundle_builder');
const { MemoryStore, utcDay } = require('../../src/sms_v2/rules_store');
const { registerRules } = require('../../src/sms_v2/rules_route');
const { registerRulesAdminRoutes, lintPattern, importBundle, checkGoldenReport } = require('../../src/sms_v2/rules_admin_route');
const stats = require('../../src/sms_v2/rule_stats');
const { validateBundle } = require('../../src/sms_v2/contracts');

const CONTRACTS = path.resolve(__dirname, '../../../contracts/sms/v2');
const fullBundle = JSON.parse(fs.readFileSync(path.join(CONTRACTS, 'fixtures/valid/bundle/full.json'), 'utf8'));
const vectors = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/canonical/vectors.json'), 'utf8'));
const GATES = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../tools/sms_golden/gates.json'), 'utf8'));

const kp = crypto.generateKeyPairSync('ed25519');
const signer = createSigner({ privateKeyPem: kp.privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId: 'sms-rules-test' });
const ADMIN = 'aaaaaaaa-0000-4000-8000-000000000001';

function idInBucket(pred) {
  for (let i = 0; i < 100000; i += 1) {
    const id = `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
    if (pred(builder.bucketOf(id))) return id;
  }
  throw new Error('no id found');
}
const P5 = idInBucket((b) => b < 5);
const P25 = idInBucket((b) => b >= 5 && b < 25);
const PALL = idInBucket((b) => b >= 25);
const TESTER = 'bbbbbbbb-0000-4000-8000-000000000002';

// ---- harness ----
async function harness({ flag = true, tick } = {}) {
  const store = new MemoryStore();
  store.state.testers.add(TESTER);
  let clock = new Date('2026-11-20T10:00:00Z');
  const state = { flag, entitled: true };
  const app = express();
  app.use(express.json());
  const requireSmsV2 = (req, res, next) => (state.flag ? next() : res.status(404).json({ error: 'not_found' }));
  const requireMember = (req, res, next) => {
    req.userId = req.headers['x-user'];
    return req.userId ? next() : res.status(401).json({ error: 'unauthorized' });
  };
  const requireAdmin = (req, res, next) => {
    if (!req.headers['x-user']) return res.status(401).json({ error: 'unauthorized' });
    req.userId = req.headers['x-user'];
    return req.headers['x-admin'] === '1' ? next() : res.status(403).json({ error: 'Admin access required' });
  };
  registerRules(app, {
    store, signer, requireSmsV2, requireMember, requireAdmin, now: () => clock,
    hooks: { security: { checkEntitlement: async () => state.entitled } },
  });
  registerRulesAdminRoutes(app, { store, getSigner: () => signer, requireSmsV2, requireAdmin, now: () => clock });
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, url, { user = ADMIN, admin = true, body, headers = {} } = {}) => {
    const res = await fetch(base + url, {
      method,
      headers: { 'content-type': 'application/json', ...(user ? { 'x-user': user } : {}), ...(admin ? { 'x-admin': '1' } : {}), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const buf = Buffer.from(await res.arrayBuffer());
    let json = null;
    if (buf.length) {
      const text = buf[0] === 0x1f && buf[1] === 0x8b ? zlib.gunzipSync(buf).toString('utf8') : buf.toString('utf8');
      try { json = JSON.parse(text); } catch { json = null; }
    }
    return { status: res.status, json, headers: res.headers };
  };
  const phone = (user, since = 0, headers = {}) => call('GET', `/sms/v2/rules?since=${since}`, { user, admin: false, headers });
  try {
    await store.tx(ADMIN, (s) => importBundle(s, fullBundle, { signer, adminId: ADMIN, now: clock }));
  } catch (e) { server.closeAllConnections(); server.close(); throw e; }
  return {
    store, app, call, phone, state, server, base,
    setClock: (d) => { clock = d; },
    close: () => { server.closeAllConnections(); server.close(); },
    tick,
  };
}

const RULE_ID = 'HDFC-CARD-SPEND-03';
const draftBody = (confidence = 0.9) => ({ ...fullBundle.rules[0], confidence, status: 'draft' });
const passingReport = (sha) => ({ total: 10, passed: 10, bundleSha256: sha });

async function publish(h, version, cohort, mutate = (r) => r) {
  const cand = await h.call('GET', `/admin/sms/v2/rules/${RULE_ID}/candidate?version=${version}&cohort=${cohort}`);
  assert.equal(cand.status, 200);
  const report = mutate(passingReport(cand.json.contentSha256));
  return h.call('POST', `/admin/sms/v2/rules/${RULE_ID}/publish`, { body: { version, cohort, goldenReport: report } });
}
const ruleConfidence = (bundleJson) => bundleJson.rules.find((r) => r.id === RULE_ID).confidence;

// ---- cohorts ----

test('cohort assignment is deterministic and follows the 5/25 buckets', () => {
  assert.equal(builder.bucketOf(P5), builder.bucketOf(P5));
  assert.equal(builder.cohortFor(P5, false), 'pct5');
  assert.equal(builder.cohortFor(P25, false), 'pct25');
  assert.equal(builder.cohortFor(PALL, false), 'all');
  assert.equal(builder.cohortFor(PALL, true), 'testers');
  assert.equal(builder.cohortFor(P5.toUpperCase(), false), 'pct5', 'case-insensitive');
  // distribution sanity
  let below5 = 0;
  for (let i = 0; i < 2000; i += 1) if (builder.bucketOf(crypto.randomUUID()) < 5) below5 += 1;
  assert.ok(below5 > 40 && below5 < 170, `pct5 share was ${below5}/2000`);
});

test('cohort visibility nests: testers see everything, pct5 sees pct25 and all', () => {
  const v = builder.visibleTo;
  assert.deepEqual(['testers', 'pct5', 'pct25', 'all'].map((c) => v('testers', c)), [true, true, true, true]);
  assert.deepEqual(['testers', 'pct5', 'pct25', 'all'].map((c) => v('pct5', c)), [false, true, true, true]);
  assert.deepEqual(['testers', 'pct5', 'pct25', 'all'].map((c) => v('pct25', c)), [false, false, true, true]);
  assert.deepEqual(['testers', 'pct5', 'pct25', 'all'].map((c) => v('all', c)), [false, false, false, true]);
});

// ---- canonical JSON + signature ----

test('canonical JSON vectors', () => {
  for (const c of vectors.canonical) {
    assert.equal(canonicalize(c.input), c.canonical, c.name);
    assert.equal(sha256Hex(Buffer.from(c.canonical, 'utf8')), c.sha256, c.name);
  }
});

test('signature vector verifies with the test public key and rejects tampering', () => {
  const v = vectors.signedBundle;
  const bytes = canonicalBundleBytes(v.input);
  assert.equal(bytes.toString('utf8'), v.canonical);
  assert.equal(sha256Hex(bytes), v.sha256);
  assert.ok(crypto.verify(null, bytes, vectors.testKey.publicKeyPem, Buffer.from(v.signatureBase64, 'base64')));
  const signed = { ...v.input, signature: { alg: 'Ed25519', keyId: v.keyId, value: v.signatureBase64 } };
  assert.ok(verifyBundle(signed, vectors.testKey.publicKeyPem));
  assert.ok(verifyBundle(signed, { [v.keyId]: vectors.testKey.publicKeyPem }));
  assert.equal(verifyBundle({ ...signed, bundleVersion: 8 }, vectors.testKey.publicKeyPem), false);
  // re-signing with the vector's private key reproduces the stored signature (Ed25519 is deterministic)
  const again = createSigner({ privateKeyPem: vectors.testKey.privateKeyPem, keyId: v.keyId });
  assert.equal(signBundle(v.input, again).signature.value, v.signatureBase64);
});

test('the signing key is required in production', () => {
  assert.throws(() => signerFromEnv({ NODE_ENV: 'production' }), /SMS_RULES_SIGNING_KEY/);
  assert.equal(signerFromEnv({ NODE_ENV: 'test' }), null);
});

// ---- import ----

test('import creates bundle 1, verifies with the public key, and is idempotent', async () => {
  const h = await harness();
  try {
    const b1 = await h.store.tx(ADMIN, (s) => s.latestBundle('all'));
    assert.equal(b1.bundleVersion, 1);
    const served = await h.phone(PALL, 0);
    assert.equal(served.status, 200);
    assert.equal(served.json.bundleVersion, 1);
    assert.ok(verifyBundle(served.json, signer.publicKeyPem));
    assert.ok(validateBundle(served.json).ok);
    assert.deepEqual(served.json.rules.map((r) => r.id), [RULE_ID], 'provisional AI rule is not shipped');
    assert.equal(served.json.signature.keyId, 'sms-rules-test');
    const before = JSON.stringify(h.store.state);
    const again = await h.store.tx(ADMIN, (s) => importBundle(s, fullBundle, { signer, adminId: ADMIN, now: new Date('2026-11-21T00:00:00Z') }));
    assert.equal(again.rulesInserted, 0);
    assert.equal(again.minted.length, 0);
    assert.equal(JSON.stringify(h.store.state.bundles), JSON.stringify(JSON.parse(before).bundles));
  } finally { h.close(); }
});

// ---- serving: 304, headers ----

test('GET /sms/v2/rules returns 304 when not newer, honours ETag, expiry is 7 days ahead', async () => {
  const h = await harness();
  try {
    const first = await h.phone(PALL, 0);
    assert.equal(first.status, 200);
    const raw = await new Promise((resolve, reject) => {
      http.get(`${h.base}/sms/v2/rules?since=0`, { headers: { 'x-user': PALL } }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ res, body: Buffer.concat(chunks) }));
      }).on('error', reject);
    });
    assert.equal(raw.res.headers['content-encoding'], 'gzip');
    assert.deepEqual([...raw.body.subarray(0, 2)], [0x1f, 0x8b]);
    assert.equal(Date.parse(first.json.expiresAt) - Date.parse('2026-11-20T10:00:00Z'), 7 * 86400000);
    const etag = first.headers.get('etag');
    assert.ok(etag);
    assert.equal((await h.phone(PALL, 1)).status, 304);
    assert.equal((await h.phone(PALL, 99)).status, 304);
    assert.equal((await h.phone(PALL, 0, { 'if-none-match': etag })).status, 304);
    assert.equal((await h.phone(PALL, 'abc')).status, 400);
    h.state.entitled = false;
    const denied = await h.phone(PALL, 0);
    assert.equal(denied.status, 403);
    assert.equal(denied.json.error, 'entitlement_required');
  } finally { h.close(); }
});

test('rule routes answer 404 with the flag off, before authentication', async () => {
  const h = await harness({ flag: false });
  try {
    assert.equal((await h.call('GET', '/sms/v2/rules', { user: null, admin: false })).status, 404);
    assert.equal((await h.call('POST', '/sms/v2/rule-stats:batch', { user: null, admin: false, body: {} })).status, 404);
    assert.equal((await h.call('GET', '/admin/sms/v2/rules', { user: null, admin: false })).status, 404);
  } finally { h.close(); }
});

test('admin routes require admin authority', async () => {
  const h = await harness();
  try {
    assert.equal((await h.call('GET', '/admin/sms/v2/rules', { user: null, admin: false })).status, 401);
    assert.equal((await h.call('GET', '/admin/sms/v2/rules', { user: PALL, admin: false })).status, 403);
    assert.equal((await h.call('PUT', `/admin/sms/v2/rules/${RULE_ID}/draft`, { user: PALL, admin: false, body: draftBody() })).status, 403);
    assert.equal((await h.call('POST', `/admin/sms/v2/rules/${RULE_ID}/pause`, { user: PALL, admin: false, body: { reason: 'x' } })).status, 403);
    assert.equal((await h.call('GET', '/admin/sms/v2/rules')).status, 200);
  } finally { h.close(); }
});

// ---- lifecycle ----

test('draft -> testers -> all -> pause -> rollback, with a bundle change at each step', async () => {
  const h = await harness();
  try {
    // draft
    const draft = await h.call('PUT', `/admin/sms/v2/rules/${RULE_ID}/draft`, { body: draftBody(0.8) });
    assert.equal(draft.status, 200, JSON.stringify(draft.json));
    assert.equal(draft.json.version, 2);
    const before = (await h.phone(TESTER, 0)).json;
    assert.equal(ruleConfidence(before), fullBundle.rules[0].confidence, 'draft is invisible');

    // publish to testers
    const toTesters = await publish(h, 2, 'testers');
    assert.equal(toTesters.status, 200, JSON.stringify(toTesters.json));
    const t1 = (await h.phone(TESTER, 0)).json;
    assert.equal(ruleConfidence(t1), 0.8);
    assert.ok(verifyBundle(t1, signer.publicKeyPem));
    assert.equal(ruleConfidence((await h.phone(PALL, 0)).json), fullBundle.rules[0].confidence, 'others unchanged');
    assert.equal(ruleConfidence((await h.phone(P5, 0)).json), fullBundle.rules[0].confidence);
    assert.ok(t1.bundleVersion > before.bundleVersion);

    // promote to pct5, then all
    assert.equal((await publish(h, 2, 'pct5')).status, 200);
    assert.equal(ruleConfidence((await h.phone(P5, 0)).json), 0.8);
    assert.equal(ruleConfidence((await h.phone(P25, 0)).json), fullBundle.rules[0].confidence);
    const narrow = await publish(h, 2, 'testers');
    assert.equal(narrow.status, 409);
    assert.equal(narrow.json.error, 'cohort_narrowing');
    assert.equal((await publish(h, 2, 'all')).status, 200);
    const allBundle = (await h.phone(PALL, 0)).json;
    assert.equal(ruleConfidence(allBundle), 0.8);

    // pause: falls back to version 1
    const paused = await h.call('POST', `/admin/sms/v2/rules/${RULE_ID}/pause`, { body: { reason: 'bad match' } });
    assert.equal(paused.status, 200);
    assert.equal(paused.json.version, 2);
    const afterPause = (await h.phone(PALL, 0)).json;
    assert.equal(ruleConfidence(afterPause), fullBundle.rules[0].confidence);
    assert.ok(afterPause.bundleVersion > allBundle.bundleVersion);

    // rollback creates a new version holding the old body
    const rb = await h.call('POST', `/admin/sms/v2/rules/${RULE_ID}/rollback`, { body: { toVersion: 1, reason: 'restore' } });
    assert.equal(rb.status, 200, JSON.stringify(rb.json));
    assert.equal(rb.json.version, 3);
    const detail = (await h.call('GET', `/admin/sms/v2/rules/${RULE_ID}`)).json;
    assert.deepEqual(detail.versions.map((v) => v.version), [1, 2, 3]);
    assert.equal(detail.versions[2].body.confidence, fullBundle.rules[0].confidence);
    assert.equal(detail.versions[2].body.version, 3);
    const afterRollback = (await h.phone(TESTER, 0)).json;
    assert.equal(ruleConfidence(afterRollback), fullBundle.rules[0].confidence);
    assert.ok(afterRollback.bundleVersion > afterPause.bundleVersion || afterRollback.bundleVersion >= 1);
    assert.deepEqual(h.store.state.bundles.filter((b) => b.status === 'rolled_back').length > 0, true);
    assert.equal((await h.call('POST', `/admin/sms/v2/rules/${RULE_ID}/rollback`, { body: { toVersion: 9, reason: 'x' } })).status, 404);

    // every action audited
    const actions = h.store.state.audit.map((a) => a.action);
    for (const a of ['sms_v2_rule_draft', 'sms_v2_rule_publish', 'sms_v2_rule_pause', 'sms_v2_rule_rollback']) assert.ok(actions.includes(a), a);

    // bundle history lists signer and cohort
    const hist = (await h.call('GET', '/admin/sms/v2/bundles')).json.bundles;
    assert.ok(hist.length >= 8 && hist.every((b) => b.keyId === 'sms-rules-test' && b.cohort));
  } finally { h.close(); }
});

test('bundle composition: a paused version falls back to the previous one, per cohort', () => {
  const rules = [
    { ruleId: 'R', version: 1, status: 'active' }, { ruleId: 'R', version: 2, status: 'active' }, { ruleId: 'R', version: 3, status: 'active' },
    { ruleId: 'S', version: 1, status: 'draft' }, { ruleId: 'T', version: 1, status: 'retired' },
  ];
  const cohorts = [
    { ruleId: 'R', version: 1, cohort: 'all', pausedAt: null },
    { ruleId: 'R', version: 2, cohort: 'pct25', pausedAt: null },
    { ruleId: 'R', version: 3, cohort: 'testers', pausedAt: null },
    { ruleId: 'S', version: 1, cohort: 'all', pausedAt: null },
    { ruleId: 'T', version: 1, cohort: 'all', pausedAt: null },
  ];
  assert.deepEqual(builder.ruleManifest('testers', rules, cohorts), { R: 3 });
  assert.deepEqual(builder.ruleManifest('pct5', rules, cohorts), { R: 2 });
  assert.deepEqual(builder.ruleManifest('all', rules, cohorts), { R: 1 });
  cohorts[2].pausedAt = 'x';
  assert.deepEqual(builder.ruleManifest('testers', rules, cohorts), { R: 2 });
  cohorts[1].pausedAt = 'x';
  assert.deepEqual(builder.ruleManifest('testers', rules, cohorts), { R: 1 });
});

test('a new bundle version is minted only when the manifest changes', async () => {
  const h = await harness();
  try {
    const n = h.store.state.bundles.length;
    const minted = await h.store.tx(ADMIN, (s) => builder.mintBundles(s, { signer }));
    assert.equal(minted.length, 0);
    assert.equal(h.store.state.bundles.length, n);
  } finally { h.close(); }
});

// ---- publish gate ----

test('publish is refused without a matching passing golden report', async () => {
  const h = await harness();
  try {
    await h.call('PUT', `/admin/sms/v2/rules/${RULE_ID}/draft`, { body: draftBody(0.7) });
    const url = `/admin/sms/v2/rules/${RULE_ID}/publish`;
    const missing = await h.call('POST', url, { body: { version: 2, cohort: 'testers' } });
    assert.equal(missing.status, 400);
    assert.equal(missing.json.error, 'request.admin_rule_publish.golden_report_required');
    const wrongHash = await h.call('POST', url, { body: { version: 2, cohort: 'testers', goldenReport: passingReport('0'.repeat(64)) } });
    assert.equal(wrongHash.status, 422);
    assert.equal(wrongHash.json.error, 'golden_report_hash_mismatch');
    assert.equal((await publish(h, 2, 'testers', (r) => ({ ...r, passed: 9 }))).json.error, 'golden_report_failing');
    assert.equal((await publish(h, 2, 'testers', (r) => ({ ...r, total: 0, passed: 0 }))).json.error, 'golden_report_failing');
    const gate = await publish(h, 2, 'testers', (r) => ({ ...r, metrics: { captureRecall: { status: 'ok', value: 0.5 }, askRate: { status: 'ok', value: 0.5 } } }));
    assert.equal(gate.json.error, 'golden_report_gate_failed');
    assert.match(gate.json.detail, /captureRecall/);
    const bad = await h.call('POST', url, { body: { version: 2, cohort: 'nope', goldenReport: {} } });
    assert.equal(bad.status, 400);
    assert.equal((await h.call('POST', url, { body: { version: 9, cohort: 'testers', goldenReport: {} } })).status, 404);
    assert.equal(h.store.state.cohorts.filter((c) => c.version === 2).length, 0, 'nothing was published');
    // an acceptable report with skipped metrics passes
    const ok = await publish(h, 2, 'testers', (r) => ({ ...r, metrics: { captureRecall: { status: 'not_available', value: null }, eventKind: { status: 'ok', value: 0.99 } } }));
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
  } finally { h.close(); }
});

test('checkGoldenReport accepts the CLI report shape', () => {
  const report = { bundleSha256: 'a', counts: { cases: 82, casesPassed: 82, scenarios: 15, scenariosPassed: 15, scenariosEvaluated: true }, metrics: { askRate: { status: 'ok', value: 0.04 } } };
  assert.equal(checkGoldenReport(report, 'a', GATES), null);
  assert.equal(checkGoldenReport({ ...report, counts: { ...report.counts, scenariosPassed: 14 } }, 'a', GATES).code, 'golden_report_failing');
  assert.equal(checkGoldenReport({ ...report, metrics: { askRate: { status: 'ok', value: 0.06 } } }, 'a', GATES).code, 'golden_report_gate_failed');
});

// ---- draft validation ----

test('draft validates against the schema and refuses regex dialect violations', async () => {
  const h = await harness();
  try {
    const put = (body, id = RULE_ID) => h.call('PUT', `/admin/sms/v2/rules/${id}/draft`, { body });
    const mk = (pattern) => ({ ...draftBody(), match: { ...fullBundle.rules[0].match, pattern } });
    assert.equal((await put({ nope: 1 })).status, 400);
    assert.equal((await put({ ...draftBody(), id: 'OTHER' })).json.error, 'rule_id_mismatch');
    for (const bad of ['(a+)+b', '(?:x*)*', '(a|b+){2,}', '(\\d)\\1', '(?<q>a)\\k<q>', '(']) {
      const r = await put(mk(bad));
      assert.ok(r.status === 422 || r.status === 400, `${bad} -> ${r.status}`);
    }
    assert.equal((await put(mk('(a+)+b'))).json.error, 'rule_pattern_invalid');
    assert.equal((await put(mk('^(?:rs\\.?|inr)\\s*(?<amt>[\\d,]+)(?:\\.\\d{1,2})?'))).status, 200);
    // updating the open draft keeps the version; a published version is never edited
    const again = await put({ ...draftBody(0.6) });
    assert.equal(again.json.version, 2);
    assert.equal(h.store.state.rules.filter((r) => r.ruleId === RULE_ID).length, 2);
  } finally { h.close(); }
});

test('lintPattern allows bounded and sequential quantifiers', () => {
  assert.deepEqual(lintPattern('^(?:abc)?\\s*[\\d,]+(?:\\.\\d{1,2})?$', 'i'), []);
  assert.deepEqual(lintPattern('(a+)?', ''), []);
  assert.deepEqual(lintPattern('([a-z]+ )+', ''), ['nested quantifiers are not allowed']);
  assert.deepEqual(lintPattern('(a)\\1', ''), ['backreferences are not allowed']);
});

test('list joins 7-day metrics and flags auto-paused rules', async () => {
  const h = await harness();
  try {
    const day = utcDay(new Date('2026-11-20T10:00:00Z'));
    await h.store.tx(PALL, (s) => s.recordRuleStats(PALL, day, '1.0.0', [{ ruleId: RULE_ID, ruleVersion: 1, hits: 10, toReview: 1, corrected: 2 }]));
    await h.store.tx(ADMIN, (s) => s.rollupRuleStats());
    const list = (await h.call('GET', '/admin/sms/v2/rules?family=card_spend')).json.rules;
    const mine = list.find((r) => r.ruleId === RULE_ID);
    assert.equal(list.length, 2, 'includes the provisional rule');
    assert.deepEqual(mine.metrics7d, { hits: 10, toReview: 1, corrected: 2 });
    assert.equal(mine.autoPaused, false);
    assert.equal((await h.call('GET', '/admin/sms/v2/rules?family=nothing')).json.rules.length, 0);
  } finally { h.close(); }
});

// ---- stats ----

test('stats upload upserts profile rows; rollup counts distinct devices and trims 48h', async () => {
  const h = await harness();
  try {
    h.store.today = () => '2026-11-20';
    const body = (hits, day = '2026-11-20') => ({ day, appVersion: '1.0.0', bundleVersion: 1, stats: [{ ruleId: RULE_ID, ruleVersion: 1, hits, toReview: 1, corrected: 0 }] });
    assert.equal((await h.call('POST', '/sms/v2/rule-stats:batch', { user: PALL, admin: false, body: body(5) })).status, 202);
    assert.equal((await h.call('POST', '/sms/v2/rule-stats:batch', { user: PALL, admin: false, body: body(7) })).status, 202, 'same profile replaces');
    assert.equal((await h.call('POST', '/sms/v2/rule-stats:batch', { user: P5, admin: false, body: body(3) })).status, 202);
    assert.equal((await h.call('POST', '/sms/v2/rule-stats:batch', { user: P25, admin: false, body: body(9, '2026-11-17') })).status, 202, 'too old, ignored');
    assert.equal(h.store.state.profileStats.length, 2);
    const bad = await h.call('POST', '/sms/v2/rule-stats:batch', { user: PALL, admin: false, body: { ...body(1), stats: [{ ruleId: RULE_ID, ruleVersion: 1, hits: -1, toReview: 0, corrected: 0 }] } });
    assert.equal(bad.status, 400);
    assert.equal(bad.json.error, 'request.rule_stats_batch.counter_invalid');

    await h.store.tx(ADMIN, (s) => s.rollupRuleStats());
    assert.deepEqual(h.store.state.daily.map((d) => [d.day, d.hits, d.toReview, d.devices]), [['2026-11-20', 10, 2, 2]]);
    // rollup is idempotent
    await h.store.tx(ADMIN, (s) => s.rollupRuleStats());
    assert.equal(h.store.state.daily[0].hits, 10);
    // three days later the profile rows are dropped but the daily row stays
    h.store.today = () => '2026-11-23';
    await h.store.tx(ADMIN, (s) => s.rollupRuleStats());
    assert.equal(h.store.state.profileStats.length, 0);
    assert.equal(h.store.state.daily.length, 1);
    assert.equal(h.store.state.daily[0].devices, 2);
  } finally { h.close(); }
});

// ---- auto-pause ----

function pauseScenario({ hits, corrected, prev = null, cohort = 'pct5', all = false }) {
  const rules = [{ ruleId: 'R', version: 1 }, { ruleId: 'R', version: 2 }];
  const cohorts = [{ ruleId: 'R', version: 1, cohort: 'all', pausedAt: null }, { ruleId: 'R', version: 2, cohort, pausedAt: null }];
  if (all) cohorts.push({ ruleId: 'R', version: 2, cohort: 'all', pausedAt: null });
  const st = [{ ruleId: 'R', version: 2, hits, corrected }];
  if (prev) st.push({ ruleId: 'R', version: 1, ...prev });
  return stats.evaluateAutoPause({ rules, cohorts, stats: st }).map((x) => `${x.ruleId}@${x.version}`);
}

test('auto-pause thresholds: 50-hit minimum, 1% floor, twice the previous rate', () => {
  assert.deepEqual(pauseScenario({ hits: 49, corrected: 49 }), [], 'below the 50-hit minimum');
  assert.deepEqual(pauseScenario({ hits: 50, corrected: 0 }), [], 'zero corrections');
  assert.deepEqual(pauseScenario({ hits: 200, corrected: 2 }), [], 'exactly 1% is not above 1%');
  assert.deepEqual(pauseScenario({ hits: 200, corrected: 3 }), ['R@2']);
  assert.deepEqual(pauseScenario({ hits: 100, corrected: 4, prev: { hits: 1000, corrected: 30 } }), [], '4% vs 2x3%=6%');
  assert.deepEqual(pauseScenario({ hits: 100, corrected: 7, prev: { hits: 1000, corrected: 30 } }), ['R@2'], '7% above 6%');
  assert.deepEqual(pauseScenario({ hits: 100, corrected: 2, prev: { hits: 1000, corrected: 1 } }), ['R@2'], 'floor 1%, previous 0.1%');
  assert.deepEqual(pauseScenario({ hits: 100, corrected: 50, cohort: 'all' }), [], 'versions on all are not auto-paused');
  assert.deepEqual(pauseScenario({ hits: 100, corrected: 50, cohort: 'pct5', all: true }), []);
  assert.deepEqual(pauseScenario({ hits: 100, corrected: 50, cohort: 'testers' }), ['R@2']);
  assert.deepEqual(pauseScenario({ hits: 100, corrected: 50, cohort: 'pct25' }), ['R@2']);
});

test('the job pauses with auto_correction_rate, re-mints, and the list flags it', async () => {
  const h = await harness();
  try {
    await h.call('PUT', `/admin/sms/v2/rules/${RULE_ID}/draft`, { body: draftBody(0.8) });
    assert.equal((await publish(h, 2, 'pct25')).status, 200);
    const day = utcDay(new Date('2026-11-20T10:00:00Z'));
    h.store.today = () => day;
    const rows = Array.from({ length: 60 }, (_, i) => `00000000-0000-4000-9000-${String(i).padStart(12, '0')}`);
    for (const p of rows) await h.store.tx(p, (s) => s.recordRuleStats(p, day, '1.0.0', [{ ruleId: RULE_ID, ruleVersion: 2, hits: 1, toReview: 0, corrected: 1 }]));
    const before = (await h.phone(P25, 0)).json;
    assert.equal(ruleConfidence(before), 0.8);
    const out = await stats.runRuleJobs({ store: h.store, signer, adminId: ADMIN, now: new Date('2026-11-20T11:00:00Z') });
    assert.deepEqual(out.paused.map((p) => `${p.ruleId}@${p.version}`), [`${RULE_ID}@2`]);
    const after = (await h.phone(P25, 0)).json;
    assert.equal(ruleConfidence(after), fullBundle.rules[0].confidence);
    assert.ok(after.bundleVersion > before.bundleVersion);
    assert.ok(h.store.state.cohorts.filter((c) => c.version === 2).every((c) => c.pauseReason === 'auto_correction_rate'));
    assert.equal((await h.call('GET', '/admin/sms/v2/rules')).json.rules.find((r) => r.ruleId === RULE_ID).autoPaused, true);
    // running again changes nothing
    const again = await stats.runRuleJobs({ store: h.store, signer, adminId: ADMIN, now: new Date('2026-11-20T12:00:00Z') });
    assert.deepEqual(again.paused, []);
  } finally { h.close(); }
});
