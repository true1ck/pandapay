'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { startLoopHarness, registerAllLoopAdminRoutes, skip } = require('./helpers/loop_harness');
const { createPgSuggestionStore, runSuggestionOnce, SUGGESTION_PROMPT_VERSION } = require('../../src/sms_v2/merchant_suggestions');
const { createPgWorkerStore, runTemplateWorkerOnce } = require('../../src/sms_v2/template_worker');
const { config } = require('./fixtures/template_draft');

test('shop suggestions: who is picked, once per shop, one shared budget, and shown on the Learning page', { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 4, registerAdmin: registerAllLoopAdminRoutes });
  await rig.requirePeople(3);
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const admin = rig.asAdmin();
  const signal = (profile, key, { kind = 'uncategorised', eligible = true, sender = 'HDFCBK' } = {}) => pool.query(
    `INSERT INTO sms_v2_learning_signals(profile_id,kind,sender_brand,merchant_key,value,taxonomy_version,eligible,is_tester)
     VALUES($1,$2,$3,$4,'',1,$5,false)`, [profile, kind, sender, key, eligible]);
  const three = profiles.slice(0, 3);
  for (const p of three) await signal(p, 'BLINKIT', { sender: p === profiles[0] ? 'ICICIB' : 'HDFCBK' });
  for (const p of profiles.slice(0, 2)) await signal(p, 'ZEPTO'); // below K
  for (const p of three) await signal(p, 'UNATTESTED', { eligible: false });
  for (const p of three) await signal(p, 'ALREADYRULED');
  for (const p of three) await signal(p, 'ASKEDBEFORE');
  await pool.query("INSERT INTO sms_v2_bundle_parts(part,body) VALUES('taxonomyVersion','1'::jsonb),('categoryRules',$1::jsonb)",
    [JSON.stringify([{ merchantKey: 'ALREADYRULED', match: 'token', senders: ['*'], context: [], category: 'groceries', priority: 100, source: 'shared' }])]);
  await pool.query("INSERT INTO sms_v2_merchant_suggestions(merchant_key,category,confidence,why,status) VALUES('ASKEDBEFORE','dining',0.9,'brand_known','ready')");

  const store = createPgSuggestionStore({ ...rig.helpers, adminId: rig.admin });
  const asked = [];
  const provider = {
    generate: async ({ prompt }) => {
      asked.push(JSON.parse(prompt));
      return { rule: JSON.stringify({ category: 'groceries', confidence: 0.9, why: 'brand_known' }), inputTokens: 100, outputTokens: 20, totalTokens: 120 };
    },
  };

  // Off by default: nothing is claimed.
  assert.equal((await runSuggestionOnce({ store, provider, config })).status, 'disabled');
  assert.equal(asked.length, 0);
  const setting = (await admin.get('/admin/sms/v2/settings')).body.settings.find((row) => row.key === 'ai_merchant_suggestions_enabled');
  const enabled = await admin.put('/admin/sms/v2/settings/ai_merchant_suggestions_enabled', { value: true, reason: 'Try shop suggestions', expectedUpdatedAt: setting.updatedAt });
  assert.equal(enabled.status, 200, JSON.stringify(enabled.body));

  // On: BLINKIT is the only shop with K attested people, no rule and no suggestion.
  assert.deepEqual(await runSuggestionOnce({ store, provider, config }), { status: 'ready', merchantKey: 'BLINKIT' });
  assert.equal(asked.length, 1);
  assert.equal(asked[0].merchantKey, 'BLINKIT');
  assert.deepEqual([...asked[0].senderBrands].sort(), ['HDFCBK', 'ICICIB']);
  assert.deepEqual(Object.keys(asked[0]).sort(), ['allowedWhy', 'categories', 'instruction', 'merchantKey', 'promptVersion', 'senderBrands']);
  const row = (await pool.query("SELECT * FROM sms_v2_merchant_suggestions WHERE merchant_key='BLINKIT'")).rows[0];
  assert.deepEqual([row.status, row.category, Number(row.confidence), row.why, row.prompt_version], ['ready', 'groceries', 0.9, 'brand_known', SUGGESTION_PROMPT_VERSION]);

  // Called once ever: nothing else qualifies, and BLINKIT is not asked again.
  assert.equal((await runSuggestionOnce({ store, provider, config })).status, 'idle');
  assert.equal(asked.length, 1);

  // The call is in the same attempts table, so layouts and shops share one budget.
  const attempts = (await pool.query('SELECT prompt_version,total_tokens,outcome,cost_usd FROM sms_v2_template_attempts')).rows;
  assert.deepEqual(attempts.map((a) => [a.prompt_version, a.total_tokens, a.outcome]), [[SUGGESTION_PROMPT_VERSION, 120, 'valid']]);
  const layoutStore = createPgWorkerStore({ ...rig.helpers, adminId: rig.admin });
  assert.equal(await layoutStore.monthSpend(), Number(attempts[0].cost_usd), 'the layout worker sees the shop spend');
  const withBudget = await admin.get('/admin/sms/v2/settings');
  const budget = withBudget.body.settings.find((entry) => entry.key === 'ai_monthly_budget_usd');
  await admin.put('/admin/sms/v2/settings/ai_monthly_budget_usd', { value: 0.0001, reason: 'Tiny budget for the test', expectedUpdatedAt: budget.updatedAt });
  for (const p of three) await signal(p, 'SWIGGYDELIVERY');
  assert.equal((await runSuggestionOnce({ store, provider, config })).status, 'budget', 'the shop spend alone used the budget');
  assert.equal((await runTemplateWorkerOnce({ store: layoutStore, provider, config })).status, 'budget', 'and it stops layout drafts too');
  assert.equal(asked.length, 1);
  await admin.put('/admin/sms/v2/settings/ai_monthly_budget_usd', { value: 10, reason: 'Back to normal', expectedUpdatedAt: (await admin.get('/admin/sms/v2/settings')).body.settings.find((entry) => entry.key === 'ai_monthly_budget_usd').updatedAt });

  // An unsure answer is recorded as failed and the shop is not asked again.
  const unsure = { generate: async () => ({ rule: JSON.stringify({ category: 'dining', confidence: 0.95, why: 'unsure' }), inputTokens: 10, outputTokens: 5, totalTokens: 15 }) };
  assert.deepEqual(await runSuggestionOnce({ store, provider: unsure, config }), { status: 'failed', merchantKey: 'SWIGGYDELIVERY' });
  const failed = (await pool.query("SELECT status,why FROM sms_v2_merchant_suggestions WHERE merchant_key='SWIGGYDELIVERY'")).rows[0];
  assert.deepEqual(failed, { status: 'failed', why: 'unsure' });
  assert.equal((await runSuggestionOnce({ store, provider: unsure, config })).status, 'idle');

  // A crash between claim and answer leaves a pending claim that is never reissued.
  for (const p of three) await signal(p, 'CRASHED');
  const crashing = { generate: async () => { throw new Error('network down'); } };
  assert.equal((await runSuggestionOnce({ store, provider: crashing, config })).status, 'failed');
  assert.equal((await pool.query("SELECT why FROM sms_v2_merchant_suggestions WHERE merchant_key='CRASHED'")).rows[0].why, 'provider_failed');
  assert.equal((await runSuggestionOnce({ store, provider, config })).status, 'idle');

  // The Learning page shows only the ready suggestion.
  const other = (await admin.get('/admin/sms/v2/learning/uncategorised')).body.candidates;
  const byKey = Object.fromEntries(other.map((entry) => [entry.merchantKey, entry]));
  assert.deepEqual(byKey.BLINKIT.suggestion, { category: 'groceries', confidence: 0.9, why: 'brand_known' });
  assert.equal(byKey.SWIGGYDELIVERY.suggestion, null, 'a failed suggestion is not shown');
  assert.equal(byKey.ZEPTO, undefined, 'below K, never named');
  assert.equal(byKey.ALREADYRULED.status, 'covered');
});
