'use strict';
// The whole learning loop on a fully migrated PostgreSQL, with a fake Gemini
// provider and a fake App Check hook (learning-loop Task B8). One scenario, in
// the order a real rollout would meet it.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const full = require('../../../contracts/sms/v2/fixtures/valid/bundle/full.json');
const { template, config, rule } = require('./fixtures/template_draft');
const { startLoopHarness, registerAllLoopAdminRoutes, skip, V3 } = require('./helpers/loop_harness');
const { createPgWorkerStore, runTemplateWorkerOnce } = require('../../src/sms_v2/template_worker');
const { importBundle } = require('../../src/sms_v2/rules_admin_route');
const { createPgStore } = require('../../src/sms_v2/rules_store');
const { runRuleJobs } = require('../../src/sms_v2/rule_stats');

const V2 = 'sms-shared-learning-v2';

// A second layout of the same sender that reads differently from the fixture one.
const second = {
  template_hash: 'b'.repeat(64),
  sender_brand: 'TESTBK',
  redacted_body: '<AMT> paid at <PARTY>.',
};
function secondRule(hash) {
  const draft = rule();
  draft.id = `AI-${hash}`;
  draft.match.templateHash = hash;
  draft.match.pattern = '^Rs\\. (?<amt>[0-9.]+) paid at (?<merchant>[A-Z ]+)\\.$';
  draft.examples = [
    { sender: 'TESTBK', body: 'Rs. 127.45 paid at SYNTHETIC STORE.', expectFactTypes: ['movement'] },
    { sender: 'TESTBK', body: 'Rs. 239.12 paid at TEST SHOP.', expectFactTypes: ['movement'] },
    { sender: 'TESTBK', body: 'Rs. 127.45 payment at SYNTHETIC STORE failed.', expectFactTypes: [] },
    { sender: 'TESTBK', body: 'Rs. 239.12 will be paid at TEST SHOP.', expectFactTypes: [] },
  ];
  return draft;
}
const layoutItem = (layout) => ({
  templateHash: layout.template_hash, senderBrand: layout.sender_brand,
  redactedBody: layout.redacted_body, observedAt: new Date().toISOString(),
});
const swiggy = (value, key = 'SWIGGY') => ({
  kind: 'category_choice', senderBrand: 'HDFCBK', merchantKey: key, value, eventType: 'purchase', taxonomyVersion: 1,
});

test('the whole learning loop, from a shared layout to a published rule and back to nothing', { skip }, async (t) => {
  // Profiles 0 to 3 opt in at v3, 4 only at v2, 5 never.
  const rig = await startLoopHarness({ profileCount: 6, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const [p1, p2, p3, p4, legacy, never] = profiles;
  const admin = rig.asAdmin();
  const as = (profile, verified = true) => rig.asUser(profile, { verified });
  for (const id of [p1, p2, p3, p4]) await rig.consent(id, true, V3);
  await rig.consent(legacy, true, V2);

  // The shared rule set the admin will add to, signed and served like production.
  const adminStore = createPgStore({ withUserClient: (actor, fn) => rig.helpers.withAdminClient(actor, 'learning.publish', fn) });
  const now = new Date();
  await adminStore.tx(rig.admin, (s) => importBundle(s, full, { signer: rig.signer, adminId: rig.admin, now }));
  await pool.query('INSERT INTO sms_v2_testers(profile_id) VALUES($1)', [p1]);
  const refreshServed = () => runRuleJobs({ store: adminStore, signer: rig.signer, adminId: rig.admin, now: new Date() });
  await refreshServed();

  const settingRow = async (key) => (await admin.get('/admin/sms/v2/settings')).body.settings.find((row) => row.key === key);
  const setSetting = async (key, value, reason) => {
    const out = await admin.put(`/admin/sms/v2/settings/${key}`, { value, reason, expectedUpdatedAt: (await settingRow(key)).updatedAt });
    assert.equal(out.status, 200, JSON.stringify(out.body));
  };

  // ---- 1. Only a v3 opt-in is accepted.
  const layout1 = layoutItem(template);
  assert.equal((await as(legacy).post('/sms/v2/unknown-templates', { items: [layout1] })).status, 403);
  assert.equal((await as(never).post('/sms/v2/unknown-templates', { items: [layout1] })).status, 403);
  assert.equal((await as(legacy).post('/sms/v2/learning-signals', { items: [swiggy('dining')] })).status, 403);
  assert.equal((await as(never).post('/sms/v2/learning-signals', { items: [swiggy('dining')] })).status, 403);

  // ---- 2. Three attested phones and one unattested phone share a layout.
  for (const id of [p1, p2, p3]) assert.equal((await as(id).post('/sms/v2/unknown-templates', { items: [layout1] })).status, 202);
  assert.equal((await as(p4, false).post('/sms/v2/unknown-templates', { items: [layout1] })).status, 202);
  const queued = (await pool.query('SELECT ai_status,distinct_profiles FROM sms_v2_unknown_templates WHERE template_hash=$1', [template.template_hash])).rows[0];
  assert.deepEqual([queued.ai_status, queued.distinct_profiles], ['queued', 3]);
  const held = (await pool.query('SELECT eligible FROM sms_v2_template_submitters WHERE template_hash=$1 AND profile_id=$2', [template.template_hash, p4])).rows[0];
  assert.equal(held.eligible, false, 'the unattested submission is held');

  // ---- 3. The fake model drafts a rule; attested phones get it, the unattested one does not.
  const worker = createPgWorkerStore({ ...rig.helpers, adminId: rig.admin });
  let calls = 0;
  const provider = {
    generate: async ({ prompt }) => {
      calls++;
      const asked = JSON.parse(prompt);
      const draft = asked.templateHash === template.template_hash ? rule() : secondRule(asked.templateHash);
      return { rule: draft, inputTokens: 100, outputTokens: 50, totalTokens: 150 };
    },
  };
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, 'ready');
  const privateRule = (await as(p1).get('/sms/v2/sync')).body.aiResults.find((entry) => entry.templateHash === template.template_hash);
  assert.equal(privateRule.status, 'ready');
  assert.equal(privateRule.rule.id, `AI-${template.template_hash}`);
  assert.deepEqual((await as(p4, false).get('/sms/v2/sync')).body.aiResults, [], 'an unattested phone gets nothing');

  // ---- 4. Pausing intake refuses new layouts and signals until switched back.
  await setSetting('intake_enabled', false, 'Investigating a flood');
  const paused = await as(p1).post('/sms/v2/unknown-templates', { items: [layoutItem(second)] });
  assert.equal(paused.status, 503);
  assert.deepEqual(paused.body, { error: 'learning_paused' });
  assert.equal(paused.headers.get('retry-after'), '3600');
  assert.equal((await as(p1).post('/sms/v2/learning-signals', { items: [swiggy('dining')] })).status, 503);
  await setSetting('intake_enabled', true, 'Flood over');
  assert.equal((await as(p1).post('/sms/v2/unknown-templates', { items: [layoutItem(second)] })).status, 202);

  // ---- 5. People pick a category for a shop; only a shop K people agree on is shown.
  for (const id of [p1, p2, p3]) assert.equal((await as(id).post('/sms/v2/learning-signals', { items: [swiggy('dining')] })).status, 202);
  assert.equal((await as(p4).post('/sms/v2/learning-signals', { items: [swiggy('groceries')] })).status, 202);
  assert.equal((await as(p3).post('/sms/v2/learning-signals', { items: [swiggy('dining', 'RAHUL STORE')] })).status, 202);
  const categories = (await admin.get('/admin/sms/v2/learning/categories')).body.candidates;
  assert.equal(categories.length, 1);
  assert.deepEqual([categories[0].merchantKey, categories[0].category, categories[0].users, categories[0].keyUsers, categories[0].agreement], ['SWIGGY', 'dining', 3, 4, 0.75]);
  assert.deepEqual(categories[0].split, { dining: 3, groceries: 1 });
  const summary = (await admin.get('/admin/sms/v2/learning/summary')).body;
  assert.ok(!JSON.stringify(summary).includes('RAHUL STORE'));
  assert.ok(summary.signals.find((row) => row.kind === 'category_choice').belowThreshold >= 1, 'the one-person shop is only counted');

  // ---- 6. The admin turns the row into a category rule: draft, golden check, publish.
  const draftId = crypto.randomUUID();
  const learned = { merchantKey: 'SWIGGY', match: 'token', senders: ['*'], context: [], category: 'dining', priority: 100, source: 'shared' };
  assert.equal((await admin.put(`/admin/sms/v2/category-rules/${draftId}/draft`, learned)).status, 200);
  await admin.post('/admin/sms/v2/learning/decisions', { kind: 'category_choice', merchantKey: 'SWIGGY', value: 'dining', decision: 'drafted', reason: 'Opened the category draft' });
  const candidates = (await admin.get(`/admin/sms/v2/category-rules/${draftId}/candidate?revision=1`)).body.candidates;
  assert.equal(candidates.length, 4);
  const reports = Object.fromEntries(candidates.map((entry) => [entry.cohort, { bundleSha256: entry.contentSha256, counts: { cases: 1, casesPassed: 1 }, metrics: {} }]));
  const published = await admin.post(`/admin/sms/v2/category-rules/${draftId}/publish`, { revision: 1, reason: 'Four people agree on Dining', goldenReports: reports });
  assert.equal(published.status, 200, JSON.stringify(published.body));
  await refreshServed();
  const rulesFor = async (profile) => (await as(profile).get('/sms/v2/rules')).body;
  const forTester = await rulesFor(p1);
  assert.ok(forTester.categoryRules.some((entry) => entry.merchantKey === 'SWIGGY' && entry.category === 'dining' && entry.source === 'shared'));
  // A category rule is a shared bundle part: every cohort's bundle carries it from the same publish.
  assert.ok((await rulesFor(p2)).categoryRules.some((entry) => entry.merchantKey === 'SWIGGY' && entry.category === 'dining'));
  assert.equal((await admin.get('/admin/sms/v2/learning/categories')).body.candidates[0].status, 'covered');

  // ---- 7. A shop name: three people say PAYU SWIGGY is SWIGGY.
  for (const id of [p1, p2, p3]) {
    assert.equal((await as(id).post('/sms/v2/learning-signals', { items: [{ kind: 'merchant_name', senderBrand: 'ICICIB', merchantKey: 'PAYU SWIGGY', value: 'SWIGGY', eventType: 'purchase', taxonomyVersion: 1 }] })).status, 202);
  }
  const names = (await admin.get('/admin/sms/v2/learning/merchant-names')).body.candidates;
  assert.deepEqual([names[0].merchantKey, names[0].name, names[0].users], ['PAYU SWIGGY', 'SWIGGY', 3]);
  const aliasId = crypto.randomUUID();
  assert.equal((await admin.put(`/admin/sms/v2/merchant-aliases/${aliasId}/draft`, { alias: 'PAYU SWIGGY', merchantKey: 'SWIGGY', kind: 'learned' })).status, 200);
  const aliasCandidates = (await admin.get(`/admin/sms/v2/merchant-aliases/${aliasId}/candidate?revision=1`)).body.candidates;
  const aliasReports = Object.fromEntries(aliasCandidates.map((entry) => [entry.cohort, { bundleSha256: entry.contentSha256, counts: { cases: 1, casesPassed: 1 }, metrics: {} }]));
  assert.equal((await admin.post(`/admin/sms/v2/merchant-aliases/${aliasId}/publish`, { revision: 1, reason: 'Three people renamed it', goldenReports: aliasReports })).status, 200);
  await refreshServed();
  const bundle = await rulesFor(p1);
  assert.ok(bundle.merchantAliases.some((entry) => entry.alias === 'PAYU SWIGGY' && entry.merchantKey === 'SWIGGY' && entry.kind === 'learned'));
  assert.ok(bundle.categoryRules.some((entry) => entry.merchantKey === 'SWIGGY'), 'the earlier category rule is still there');
  assert.equal((await admin.get('/admin/sms/v2/learning/merchant-names')).body.candidates[0].status, 'covered');

  // ---- 8. A bad draft is rejected: the phone drops it, and requeue brings the layout back.
  for (const id of [p2, p3]) assert.equal((await as(id).post('/sms/v2/unknown-templates', { items: [layoutItem(second)] })).status, 202);
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, 'ready');
  const secondResult = async () => (await as(p1).get('/sms/v2/sync')).body.aiResults.find((entry) => entry.templateHash === second.template_hash);
  assert.equal((await secondResult()).status, 'ready');
  const rejected = await admin.post(`/admin/sms/v2/templates/${second.template_hash}/reject`, { reason: 'overmatches' });
  assert.equal(rejected.status, 200, JSON.stringify(rejected.body));
  assert.equal((await secondResult()).status, 'failed', 'the next sync drops the private rule');
  assert.deepEqual((await admin.get('/admin/sms/v2/templates?status=rejected')).body.templates.map((row) => row.template_hash), [second.template_hash]);
  assert.equal((await admin.post(`/admin/sms/v2/templates/${second.template_hash}/requeue`, { reason: 'Prompt improved' })).status, 200);
  assert.equal((await secondResult()).status, 'queued');
  assert.equal((await pool.query('SELECT ai_status FROM sms_v2_unknown_templates WHERE template_hash=$1', [second.template_hash])).rows[0].ai_status, 'queued');

  // ---- 9. The AI budget stops the worker; raising it lets the next run call the provider.
  await setSetting('ai_monthly_budget_usd', 0.01, 'Cap the test month');
  await pool.query(
    `INSERT INTO sms_v2_template_attempts(template_hash,job_id,attempt,model,capacity_minute,reserved_tokens,cost_usd,outcome)
     VALUES($1,$2,1,'test-model',date_trunc('minute',now()),1,0.02,'valid')`, ['c'.repeat(64), crypto.randomUUID()]);
  const callsBefore = calls;
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, 'budget');
  assert.equal(calls, callsBefore, 'the provider is not called over budget');
  await setSetting('ai_monthly_budget_usd', 50, 'Test month reopened');
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, 'ready');
  assert.equal(calls, callsBefore + 1);

  // ---- 10. A per-account limit stops one phone, not the others.
  const limitPath = `/admin/sms/v2/user-limits/${p1}/signals_per_user_per_day`;
  const limited = await admin.put(limitPath, { value: 1, expiresAt: new Date(Date.now() + 86400000).toISOString(), reason: 'Bot-like volume' });
  assert.equal(limited.status, 200, JSON.stringify(limited.body));
  const extra = await as(p1).post('/sms/v2/learning-signals', { items: [swiggy('dining', 'ZOMATO')] });
  assert.equal(extra.status, 429);
  assert.equal(extra.headers.get('retry-after'), '86400');
  assert.equal((await as(p2).post('/sms/v2/learning-signals', { items: [swiggy('dining', 'ZOMATO')] })).status, 202);
  const reporter = (await admin.get('/admin/sms/v2/learning/reporters')).body.reporters.find((row) => row.profileId === p1);
  assert.equal(reporter.effectiveLimits.signals_per_user_per_day, 1);
  assert.equal(reporter.override.value, 1);

  // ---- 11. The audit feed lists the changes in order, each with its reason.
  const feed = (await admin.get('/admin/sms/v2/audit?limit=100')).body.entries.reverse();
  const expected = [
    ['sms_v2_setting', 'Investigating a flood'],
    ['sms_v2_setting', 'Flood over'],
    ['sms_v2_learning_decision', 'Opened the category draft'],
    ['sms_v2_category_publish', 'Four people agree on Dining'],
    ['sms_v2_alias_publish', 'Three people renamed it'],
    ['sms_v2_template_reject', 'overmatches'],
    ['sms_v2_template_requeue', 'Prompt improved'],
    ['sms_v2_setting', 'Cap the test month'],
    ['sms_v2_setting', 'Test month reopened'],
    ['sms_v2_user_limit', 'Bot-like volume'],
  ];
  let at = 0;
  for (const entry of feed) if (at < expected.length && entry.action === expected[at][0] && entry.reason === expected[at][1]) at++;
  assert.equal(at, expected.length, `the audit feed is missing or misorders: ${JSON.stringify(feed.map((e) => [e.action, e.reason]))}`);
  // Every change an admin makes in the loop carries the reason they gave (drafts and imports have none to give).
  const reasoned = ['sms_v2_setting', 'sms_v2_user_limit', 'sms_v2_learning_decision', 'sms_v2_category_publish', 'sms_v2_alias_publish', 'sms_v2_template_reject', 'sms_v2_template_requeue', 'sms_v2_template_block', 'sms_v2_suggestion_ask_again'];
  assert.ok(feed.filter((entry) => reasoned.includes(entry.action)).every((entry) => entry.reason), 'every decision carries a reason');

  // ---- 12. Withdrawing sharing deletes what the person shared; published rules stay.
  await rig.consent(p2, false, V3);
  assert.equal((await pool.query('SELECT 1 FROM sms_v2_learning_signals WHERE profile_id=$1', [p2])).rows.length, 0);
  assert.equal((await pool.query('SELECT 1 FROM sms_v2_template_submitters WHERE profile_id=$1', [p2])).rows.length, 0);
  let swiggyRow = (await admin.get('/admin/sms/v2/learning/categories')).body.candidates.find((row) => row.merchantKey === 'SWIGGY');
  assert.deepEqual([swiggyRow.users, swiggyRow.keyUsers], [2, 3], 'one fewer person');
  await rig.consent(p3, false, V3);
  swiggyRow = (await admin.get('/admin/sms/v2/learning/categories')).body.candidates.find((row) => row.merchantKey === 'SWIGGY');
  assert.equal(swiggyRow, undefined, 'under K people the shop is no longer shown');
  const kept = await rulesFor(p1);
  assert.ok(kept.categoryRules.some((entry) => entry.merchantKey === 'SWIGGY' && entry.category === 'dining'), 'the published rule stays');
  assert.ok(kept.merchantAliases.some((entry) => entry.alias === 'PAYU SWIGGY'), 'and so does the shop name');

  // ---- 13. Deleting an account cascades what it sent.
  await pool.query('DELETE FROM profiles WHERE id=$1', [p4]);
  assert.equal((await pool.query('SELECT 1 FROM sms_v2_learning_signals WHERE profile_id=$1', [p4])).rows.length, 0);
  assert.equal((await pool.query('SELECT 1 FROM sms_v2_template_submitters WHERE profile_id=$1', [p4])).rows.length, 0);
});
