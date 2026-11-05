'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const full = require('../../../contracts/sms/v2/fixtures/valid/bundle/full.json');
const { MemoryStore } = require('../../src/sms_v2/rules_store');
const { createSigner } = require('../../src/sms_v2/signer');
const { importBundle } = require('../../src/sms_v2/rules_admin_route');
const { saveAliasDraft, aliasCandidates, publishAlias } = require('../../src/sms_v2/category_admin_route');
const { COHORTS } = require('../../src/sms_v2/bundle_builder');
const { routeManifest } = require('../../src/admin/route_manifest');

const now = new Date('2026-11-04T12:00:00Z');
const adminId = '00000000-0000-4000-8000-000000000001';
const id = '00000000-0000-4000-8000-0000000000a1';
const kp = crypto.generateKeyPairSync('ed25519');
const signer = createSigner({ privateKeyPem: kp.privateKey.export({ format: 'pem', type: 'pkcs8' }), keyId: 'alias-test' });
const ctx = { now, adminId, signer, gates: { m1: { captureRecall: { min: 0.99 } } } };
const alias = (overrides = {}) => ({ alias: 'PAYU SWIGGY', merchantKey: 'SWIGGY', kind: 'learned', ...overrides });
const report = (hash) => ({ bundleSha256: hash, counts: { cases: 1, casesPassed: 1, scenarios: 1, scenariosPassed: 1, scenariosEvaluated: true }, metrics: { captureRecall: { value: 1, status: 'ok' } } });
async function fixture() { const store = new MemoryStore(); await store.tx(adminId, (s) => importBundle(s, full, ctx)); return store; }
async function reportsFor(store, revision = 1, draftId = id) {
  const result = await store.tx(adminId, (s) => aliasCandidates(s, draftId, revision, ctx));
  return Object.fromEntries(result.candidates.map((candidate) => [candidate.cohort, report(candidate.contentSha256)]));
}

test('a learned shop name passes every cohort and publishes into merchantAliases', async () => {
  const store = await fixture();
  const saved = await store.tx(adminId, (s) => saveAliasDraft(s, id, alias(), ctx));
  assert.deepEqual(saved, { id, revision: 1, status: 'draft' });
  const reports = await reportsFor(store);
  assert.deepEqual(Object.keys(reports).sort(), [...COHORTS].sort());
  const bad = structuredClone(reports);
  bad.pct25.bundleSha256 = '0'.repeat(64);
  const before = JSON.stringify(store.state.parts);
  await assert.rejects(store.tx(adminId, (s) => publishAlias(s, id, { revision: 1, reason: 'review', goldenReports: bad }, ctx)), { code: 'golden_report_hash_mismatch' });
  assert.equal(JSON.stringify(store.state.parts), before, 'a refused publish changes nothing');
  const published = await store.tx(adminId, (s) => publishAlias(s, id, { revision: 1, reason: 'Three people renamed it', goldenReports: reports }, ctx));
  assert.equal(published.bundles.length, 4);
  for (const cohort of COHORTS) {
    const row = await store.tx(adminId, (s) => s.latestBundle(cohort));
    assert.ok(row.body.merchantAliases.some((entry) => entry.alias === 'PAYU SWIGGY' && entry.merchantKey === 'SWIGGY' && entry.kind === 'learned'), cohort);
  }
  assert.equal(store.state.audit.at(-1).entity, 'sms_v2_merchant_alias');
  assert.equal(store.state.audit.at(-1).action, 'sms_v2_alias_publish');
  assert.equal(store.state.audit.at(-1).reason, 'Three people renamed it');
  await assert.rejects(store.tx(adminId, (s) => publishAlias(s, id, { revision: 1, reason: 'again', goldenReports: reports }, ctx)), { code: 'alias_draft_not_publishable' });
});

test('names are stored normalised, and a later revision replaces the earlier published name', async () => {
  const store = await fixture();
  await store.tx(adminId, (s) => saveAliasDraft(s, id, alias({ alias: ' payu  swiggy ', merchantKey: 'swiggy' }), ctx));
  assert.deepEqual((await store.tx(adminId, (s) => s.aliasDraft(id))).body, alias());
  const reports = await reportsFor(store);
  await store.tx(adminId, (s) => publishAlias(s, id, { revision: 1, reason: 'first', goldenReports: reports }, ctx));
  // The same draft id can be corrected to a different canonical key: the old mapping goes.
  await store.tx(adminId, (s) => saveAliasDraft(s, id, alias({ merchantKey: 'SWIGGY INSTAMART' }), ctx));
  await store.tx(adminId, async (s) => publishAlias(s, id, { revision: 2, reason: 'better name', goldenReports: await reportsFor(store, 2) }, ctx));
  const aliases = store.state.parts.merchantAliases.filter((entry) => entry.alias === 'PAYU SWIGGY');
  assert.deepEqual(aliases.map((entry) => entry.merchantKey), ['SWIGGY INSTAMART']);
});

test('an alias equal to its key, with long digit runs, or with a bad shape is refused', async () => {
  const store = await fixture();
  const refuse = async (body, code) => {
    await assert.rejects(store.tx(adminId, (s) => saveAliasDraft(s, id, body, ctx)), { code });
    assert.equal(store.state.aliasDrafts.length, 0);
  };
  await refuse(alias({ alias: 'SWIGGY' }), 'alias_equals_key');
  await refuse(alias({ alias: 'swiggy ' }), 'alias_equals_key');
  await refuse(alias({ alias: 'PAYTMQR2810050501' }), 'alias_key_invalid');
  await refuse(alias({ merchantKey: 'SWIGGY 20261106' }), 'alias_key_invalid');
  await refuse(alias({ alias: 'RAHUL@OKAXIS' }), 'alias_key_invalid');
  await refuse(alias({ alias: 'A'.repeat(61) }), 'alias_key_invalid');
  await refuse(alias({ kind: 'catalogue' }), 'alias_kind_must_be_learned');
  await refuse({ alias: 'PAYU SWIGGY', merchantKey: 'SWIGGY' }, 'alias_rule_invalid');
  await refuse({ ...alias(), extra: true }, 'alias_rule_invalid');
});

test('an alias that already maps to a different key is a conflict', async () => {
  const store = await fixture();
  await store.tx(adminId, (s) => s.setParts({ merchantAliases: [{ alias: 'PAYU SWIGGY', merchantKey: 'ZOMATO', kind: 'learned' }] }));
  await assert.rejects(store.tx(adminId, (s) => saveAliasDraft(s, id, alias(), ctx)), { code: 'alias_conflict', status: 409 });
  // The same mapping again is not a conflict.
  const other = '00000000-0000-4000-8000-0000000000a2';
  await store.tx(adminId, (s) => saveAliasDraft(s, other, alias({ merchantKey: 'ZOMATO' }), ctx));
  assert.equal(store.state.aliasDrafts.length, 1);
});

test('shop-name routes need the existing private permissions and fresh MFA', () => {
  const rows = routeManifest.filter((row) => row.path.startsWith('/admin/sms/v2/merchant-aliases'));
  assert.equal(rows.length, 3);
  for (const row of rows) {
    assert.equal(row.permission, row.method === 'GET' ? 'learning.read' : 'learning.publish');
    assert.equal(row.freshMfa, row.method !== 'GET');
  }
});
