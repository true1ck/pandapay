'use strict';
// Draft feedback: rejection route, results mapping, and old-vs-new client sync shape. Synthetic data only.
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const c = require('../../src/sms_v2/contracts');
const storage = require('../../src/sms_v2/storage');
const { createSyncHandler, aiResultsForClient } = require('../../src/sms_v2/sync_route');
const { createTemplateStore, registerTemplates } = require('../../src/sms_v2/ai_templates');

const ID = '3f2b8c1e-5a47-4d9e-8b6a-1c2d3e4f5a6b';
const HASH = 'a'.repeat(64);
const rule = { id: 'AI-x', version: 1 };

function server({ store, security = {} }) {
  const app = express();
  app.use(express.json());
  const hooks = { security: { verifyAttestation: async () => true, checkRate: async () => true, ...security } };
  const pass = (_q, _s, n) => n();
  registerTemplates(app, { requireSmsV2: pass, requireMember: (q, _s, n) => { q.userId = 'u1'; n(); }, withUserClient: store, hooks });
  return app;
}
async function post(app, body) {
  const s = app.listen(0, '127.0.0.1');
  await new Promise((r) => s.once('listening', r));
  try {
    const r = await fetch(`http://127.0.0.1:${s.address().port}/sms/v2/draft-rejections`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    return { status: r.status, body: await r.json() };
  } finally { s.closeAllConnections(); s.close(); }
}
// withUserClient stand-in: the fake client answers the one SQL the route runs.
const withClient = (fn) => async (_id, op) => op({ query: async (sql, args) => fn(sql, args) });
const failWith = (code) => withClient(() => { throw Object.assign(new Error('x'), { code }); });

test('draft-rejections: validation, recorded, already_recorded and error mapping', async () => {
  const ok = (status) => withClient(() => ({ rows: [{ status }] }));
  let r = await post(server({ store: ok('recorded') }), { draftId: ID, reason: 'no_match' });
  assert.deepEqual([r.status, r.body], [200, { status: 'recorded' }]);
  assert.equal(c.validateResponse('draft_rejections', r.body).ok, true);
  r = await post(server({ store: ok('already_recorded') }), { draftId: ID, reason: 'unsafe_rule' });
  assert.deepEqual(r.body, { status: 'already_recorded' });
  r = await post(server({ store: ok('recorded') }), { draftId: 'nope', reason: 'no_match' });
  assert.deepEqual([r.status, r.body], [400, { error: 'request.draft_rejections.draft_id_invalid' }]);
  r = await post(server({ store: ok('recorded') }), { draftId: ID, reason: 'meh' });
  assert.equal(r.body.error, 'request.draft_rejections.reason_invalid');
  r = await post(server({ store: failWith('P0404') }), { draftId: ID, reason: 'no_match' });
  assert.deepEqual([r.status, r.body], [404, { error: 'draft_not_delivered' }]);
  r = await post(server({ store: failWith('42501') }), { draftId: ID, reason: 'no_match' });
  assert.deepEqual([r.status, r.body], [403, { error: 'sms_shared_learning_consent_required' }]);
  r = await post(server({ store: failWith('08006') }), { draftId: ID, reason: 'no_match' });
  assert.deepEqual([r.status, r.body], [503, { error: 'draft_rejections_unavailable' }]);
  r = await post(server({ store: ok('recorded'), security: { verifyAttestation: async () => false } }), { draftId: ID, reason: 'no_match' });
  assert.deepEqual([r.status, r.body], [403, { error: 'attestation_required' }]);
  r = await post(server({ store: ok('recorded'), security: { checkRate: async () => false } }), { draftId: ID, reason: 'no_match' });
  assert.deepEqual([r.status, r.body], [429, { error: 'rate_limited' }]);
});

test('results mapping: ready carries draftId, own rejection hides the draft', async () => {
  const rows = [
    { template_hash: HASH, ai_status: 'ready', ai_draft: rule, revision: '5', draft_id: ID, rejected: false },
    { template_hash: 'b'.repeat(64), ai_status: 'ready', ai_draft: null, revision: '6', draft_id: null, rejected: true },
    { template_hash: 'c'.repeat(64), ai_status: 'queued', ai_draft: null, revision: '7', draft_id: null, rejected: false },
  ];
  let seen;
  const store = createTemplateStore({ withUserClient: withClient((sql, args) => { seen = args; return { rows }; }) });
  const out = await store.results('u1', null, { draftFeedback: true });
  assert.deepEqual(seen, ['0', true]);
  assert.deepEqual(out.items[0], { templateHash: HASH, status: 'ready', ruleId: 'AI-x', ruleVersion: 1, rule, draftId: ID });
  assert.deepEqual(out.items[1], { templateHash: 'b'.repeat(64), status: 'rejected' });
  assert.equal(out.items[2].status, 'pending');
  await store.results('u1', null);
  assert.equal(seen[1], false);
});

function syncReq(features) {
  return { query: { cursor: storage.encodeCursor({}) }, userId: 'u1', get: (n) => (n.toLowerCase() === 'x-sms-contract-features' ? features : undefined) };
}
async function runSync(features) {
  const calls = [];
  const hooks = {
    security: { verifyAttestation: async () => true, checkRate: async () => true },
    aiResultsSince: async (_u, _c, opts) => { calls.push(opts); return { items: [{ templateHash: HASH, status: 'ready', ruleId: 'AI-x', ruleVersion: 1, rule, draftId: ID }], cursor: '5' }; },
    correctionStatusSince: async () => [], latestBundleVersion: async () => 0,
  };
  const original = storage.readChanges;
  storage.readChanges = async () => ({ cursor: 'c', instruments: [], events: [], ledger: [], facts: [], updatedAt: '2026-11-01T00:00:00Z', hasMore: false });
  try {
    let body;
    const res = { set() {}, status() { return this; }, json(b) { body = b; return this; } };
    await createSyncHandler({ withUserClient: async (_i, fn) => fn({}), hooks })(syncReq(features), res);
    return { body, calls };
  } finally { storage.readChanges = original; }
}

test('sync: old client gets the old aiResults shape, new client gets draftId', async () => {
  const old = await runSync(undefined);
  assert.equal('draftId' in old.body.aiResults[0], false);
  assert.deepEqual(old.calls, [{ draftFeedback: false }]);
  const fresh = await runSync('refund-category, Draft-Feedback');
  assert.equal(fresh.body.aiResults[0].draftId, ID);
  assert.deepEqual(fresh.calls, [{ draftFeedback: true }]);
  assert.deepEqual(aiResultsForClient([{ status: 'pending' }], syncReq(undefined)), [{ status: 'pending' }]);
});
