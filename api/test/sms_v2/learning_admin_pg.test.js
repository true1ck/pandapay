'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Pool } = require('pg');
const { createAdminDbHelpers } = require('../../src/admin/server');
const { createAdminApiApp } = require('../../src/admin/app');
const { routeManifest } = require('../../src/admin/route_manifest');
const { registerPrivateLearningRoutes } = require('../../src/sms_v2/learning_admin_route');
const { clearSettingsCache } = require('../../src/sms_v2/settings');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;
const V3 = 'sms-shared-learning-v3';

test('Learning page: counted, k-anonymous candidates on Postgres', { skip: !url || !adminUrl }, async (t) => {
  const pool = new Pool({ connectionString: url });
  const privatePool = new Pool({ connectionString: adminUrl });
  const admin = crypto.randomUUID();
  const people = Array.from({ length: 9 }, () => crypto.randomUUID());
  let server;
  const priorParts = (await pool.query("SELECT part, body FROM sms_v2_bundle_parts WHERE part IN ('taxonomyVersion','categoryRules','merchantAliases')")).rows;
  t.after(async () => {
    if (server) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
    await pool.query("DELETE FROM sms_v2_bundle_parts WHERE part IN ('taxonomyVersion','categoryRules','merchantAliases')");
    for (const row of priorParts) {
      await pool.query('INSERT INTO sms_v2_bundle_parts(part, body) VALUES($1,$2)', [row.part, JSON.stringify(row.body)]);
    }
    await pool.query('DELETE FROM sms_v2_learning_decisions');
    await pool.query('DELETE FROM sms_v2_settings');
    await pool.query('DELETE FROM profiles WHERE id = ANY($1::uuid[])', [people]);
    await pool.query('DELETE FROM admin_audit_log WHERE admin_id = $1', [admin]);
    await pool.query('DELETE FROM admin_users WHERE id = $1', [admin]);
    await Promise.all([pool.end(), privatePool.end()]);
  });
  clearSettingsCache();
  for (const id of people) await pool.query('INSERT INTO profiles(id) VALUES($1)', [id]);
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')", [admin, `${admin}@example.invalid`]);
  // The default is one person (friends run); this scenario is written for three.
  await pool.query("INSERT INTO sms_v2_settings(key,value,updated_by,reason) VALUES('signals_min_distinct_users','3'::jsonb,$1,'test: three people')", [admin]);
  clearSettingsCache();
  await pool.query("DELETE FROM sms_v2_bundle_parts WHERE part IN ('taxonomyVersion','categoryRules','merchantAliases')");
  await pool.query("INSERT INTO sms_v2_bundle_parts(part, body) VALUES('taxonomyVersion','1'::jsonb),('categoryRules','[]'::jsonb),('merchantAliases','[]'::jsonb)");

  const signal = (profile, kind, key, value, { sender = 'HDFCBK', eligible = true, taxonomy = 1, tester = false, ago = '1 hour' } = {}) => pool.query(
    `INSERT INTO sms_v2_learning_signals(profile_id,kind,sender_brand,merchant_key,value,taxonomy_version,eligible,is_tester,last_at)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8, now() - $9::interval)`, [profile, kind, sender, key, value, taxonomy, eligible, tester, ago]);
  // SWIGGY: 3 people say dining, 1 says groceries. RAHUL STORE: one person only.
  for (const p of people.slice(0, 3)) await signal(p, 'category_choice', 'SWIGGY', 'dining', { tester: p === people[0] });
  await signal(people[3], 'category_choice', 'SWIGGY', 'groceries', { sender: 'ICICIB' });
  await signal(people[4], 'category_choice', 'RAHUL STORE', 'dining');
  // These never count: unattested, and an old taxonomy.
  await signal(people[5], 'category_choice', 'SWIGGY', 'dining', { eligible: false });
  await signal(people[6], 'category_choice', 'SWIGGY', 'dining', { taxonomy: 2 });
  // Names: three people, one name. Uncategorised: three people for BLINKIT, two for ZEPTO.
  for (const p of people.slice(0, 3)) await signal(p, 'merchant_name', 'PAYU SWIGGY', 'SWIGGY');
  for (const p of people.slice(0, 3)) await signal(p, 'uncategorised', 'BLINKIT', '', { sender: 'ICICIB' });
  for (const p of people.slice(3, 5)) await signal(p, 'uncategorised', 'ZEPTO', '');
  // Consent for the opt-in numbers.
  for (const p of people.slice(0, 3)) {
    await pool.query("INSERT INTO user_consents(profile_id,purpose,policy_version,granted) VALUES($1,'sms_shared_learning',$2,true)", [p, V3]);
  }

  const helpers = createAdminDbHelpers(privatePool);
  const app = createAdminApiApp({
    routeManifest: routeManifest.filter((row) => row.path.startsWith('/admin/sms/v2/learning/')),
    introspectAdminSession: async () => ({
      active: true, userId: admin, sessionId: 'test', assurance: 'email+webauthn-uv',
      mfaVerifiedAt: new Date(), expiresAt: new Date(Date.now() + 60000),
    }),
    ...helpers,
    registerRoutes: registerPrivateLearningRoutes,
  });
  server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const headers = { authorization: `Bearer ${'x'.repeat(43)}`, 'content-type': 'application/json' };
  const call = async (method, path, body) => {
    const response = await fetch(`${origin}${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json() };
  };
  const rows = async (name) => (await call('GET', `/admin/sms/v2/learning/${name}`)).body.candidates;

  // ---- categories
  const categories = await call('GET', '/admin/sms/v2/learning/categories');
  assert.equal(categories.status, 200);
  assert.equal(categories.body.minUsers, 3);
  assert.equal(categories.body.candidates.length, 1, 'only SWIGGY reaches K');
  const swiggy = categories.body.candidates[0];
  assert.equal(swiggy.merchantKey, 'SWIGGY');
  assert.equal(swiggy.category, 'dining');
  assert.equal(swiggy.users, 3);
  assert.equal(swiggy.keyUsers, 4);
  assert.equal(swiggy.agreement, 0.75);
  assert.deepEqual(swiggy.split, { dining: 3, groceries: 1 });
  assert.equal(swiggy.testerUsers, 1);
  assert.deepEqual([...swiggy.senders].sort(), ['HDFCBK']);
  assert.equal(swiggy.status, 'new');
  assert.ok(!JSON.stringify(categories.body).includes('RAHUL STORE'), 'a shop below K is never named');
  assert.equal((await call('GET', '/admin/sms/v2/learning/categories?days=abc')).status, 400);

  // A shared rule for the same category covers it; a different category is a conflict.
  const setRules = (rules) => pool.query("UPDATE sms_v2_bundle_parts SET body=$1::jsonb WHERE part='categoryRules'", [JSON.stringify(rules)]);
  const rule = (category) => ({ merchantKey: 'SWIGGY', match: 'token', senders: ['*'], context: [], category, priority: 100, source: 'shared' });
  await setRules([rule('dining')]);
  assert.equal((await rows('categories'))[0].status, 'covered');
  await setRules([rule('groceries')]);
  assert.equal((await rows('categories'))[0].status, 'conflict');
  await setRules([]);

  // ---- names and uncategorised
  const names = await rows('merchant-names');
  assert.equal(names.length, 1);
  assert.deepEqual([names[0].merchantKey, names[0].name, names[0].users, names[0].status], ['PAYU SWIGGY', 'SWIGGY', 3, 'new']);
  await pool.query("UPDATE sms_v2_bundle_parts SET body=$1::jsonb WHERE part='merchantAliases'", [JSON.stringify([{ alias: 'PAYU SWIGGY', merchantKey: 'SWIGGY', kind: 'learned' }])]);
  assert.equal((await rows('merchant-names'))[0].status, 'covered');
  await pool.query("UPDATE sms_v2_bundle_parts SET body='[]'::jsonb WHERE part='merchantAliases'");
  const other = await rows('uncategorised');
  assert.deepEqual(other.map((row) => [row.merchantKey, row.users]), [['BLINKIT', 3]], 'ZEPTO has two people, below K');
  assert.deepEqual(other[0].senders, ['ICICIB']);

  // ---- the summary: counts only
  const summary = await call('GET', '/admin/sms/v2/learning/summary');
  assert.equal(summary.status, 200);
  const text = JSON.stringify(summary.body);
  for (const secret of ['RAHUL STORE', 'ZEPTO', 'BLINKIT', 'SWIGGY', ...people]) assert.ok(!text.includes(secret), `summary leaks ${secret}`);
  assert.equal(summary.body.minUsers, 3);
  const bySignalKind = Object.fromEntries(summary.body.signals.map((row) => [row.kind, row]));
  assert.ok(bySignalKind.category_choice.belowThreshold >= 1, 'RAHUL STORE counted, not named');
  assert.ok(bySignalKind.uncategorised.belowThreshold >= 1, 'ZEPTO counted, not named');
  assert.ok(summary.body.optIn.sharingNow >= 3);
  assert.ok(summary.body.optIn.perDay.reduce((n, day) => n + day.on, 0) >= 3);
  assert.equal(typeof summary.body.layouts.held, 'number');
  assert.equal(typeof summary.body.ai.calls, 'number');
  assert.equal(typeof summary.body.coverage.hits, 'number');
  assert.ok(Array.isArray(summary.body.trend));
  assert.equal(summary.body.candidates.categories, 1);
  assert.equal(summary.body.candidates.merchantNames, 1);
  assert.equal(summary.body.candidates.uncategorised, 1);
  assert.equal(summary.body.candidates.total, 3);

  // ---- decisions
  const bad = (body) => call('POST', '/admin/sms/v2/learning/decisions', body);
  assert.equal((await bad({ kind: 'category_choice', merchantKey: 'SWIGGY', value: 'dining', decision: 'dismissed' })).status, 400, 'reason required');
  assert.equal((await bad({ kind: 'category_choice', merchantKey: 'SWIGGY', value: 'dining', decision: 'dismissed', reason: 'ok' })).status, 400, 'reason too short');
  assert.equal((await bad({ kind: 'category_choice', merchantKey: 'swiggy', value: 'dining', decision: 'dismissed', reason: 'bad key' })).status, 400);
  assert.equal((await bad({ kind: 'category_choice', merchantKey: 'SWIGGY', value: 'dining', decision: 'approved', reason: 'bad decision' })).status, 400);
  assert.equal((await bad({ kind: 'uncategorised', merchantKey: 'BLINKIT', value: 'dining', decision: 'dismissed', reason: 'value must be empty' })).status, 400);
  assert.equal((await bad({ kind: 'category_choice', merchantKey: 'SWIGGY', value: 'dining', decision: 'dismissed', reason: 'ok reason', extra: 1 })).status, 400);

  const drafted = await bad({ kind: 'category_choice', merchantKey: 'SWIGGY', value: 'dining', decision: 'drafted', reason: 'Opened the category draft' });
  assert.equal(drafted.status, 200);
  assert.equal((await rows('categories'))[0].decision, 'drafted', 'a draft keeps the row, marked');
  const dismissed = await bad({ kind: 'category_choice', merchantKey: 'SWIGGY', value: 'dining', decision: 'dismissed', reason: 'Too few people for now' });
  assert.equal(dismissed.status, 200);
  assert.equal(dismissed.body.usersAtDecision, 4);
  assert.equal((await rows('categories')).length, 0, 'dismissed rows are hidden');
  // Hidden until the people grow by max(3, half): 4 + 3 = 7.
  await signal(people[7], 'category_choice', 'SWIGGY', 'dining');
  await signal(people[8], 'category_choice', 'SWIGGY', 'dining');
  assert.equal((await rows('categories')).length, 0, '6 people: still hidden');
  const extra = crypto.randomUUID();
  await pool.query('INSERT INTO profiles(id) VALUES($1)', [extra]);
  people.push(extra);
  await signal(extra, 'category_choice', 'SWIGGY', 'dining');
  const back = await rows('categories');
  assert.equal(back.length, 1, '7 people: back on the list');
  assert.equal(back[0].keyUsers, 7);

  const audited = (await pool.query(
    "SELECT action, reason FROM admin_audit_log WHERE admin_id = $1 AND action = 'sms_v2_learning_decision' ORDER BY id", [admin])).rows;
  assert.deepEqual(audited.map((row) => row.reason), ['Opened the category draft', 'Too few people for now']);

  // ---- a higher K from the settings hides the shop
  await pool.query("UPDATE sms_v2_settings SET value='8'::jsonb, reason='stricter', updated_at=clock_timestamp() WHERE key='signals_min_distinct_users'");
  clearSettingsCache();
  assert.equal((await rows('categories')).length, 0);
  assert.equal((await call('GET', '/admin/sms/v2/learning/categories')).body.minUsers, 8);
});

// ---- learning loop B7: reporters, ask again and the audit feed

const { startLoopHarness: startRig, registerAllLoopAdminRoutes: registerAll, skip: rigSkip } = require('./helpers/loop_harness');

test('reporters, ask-again and the audit feed on Postgres', { skip: rigSkip }, async (t) => {
  const rig = await startRig({ profileCount: 4, registerAdmin: registerAll });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const admin = rig.asAdmin();
  const signal = (profile, key, kind = 'category_choice', value = 'dining') => pool.query(
    `INSERT INTO sms_v2_learning_signals(profile_id,kind,sender_brand,merchant_key,value,taxonomy_version,eligible,is_tester)
     VALUES($1,$2,'HDFCBK',$3,$4,1,true,false)`, [profile, kind, key, kind === 'uncategorised' ? '' : value]);
  // profile 0: 5 signals; profile 1: 2 signals + 1 layout + 1 correction; profile 2: 1 signal; profile 3: nothing.
  for (const key of ['A1 SHOP', 'B1 SHOP', 'C1 SHOP', 'D1 SHOP', 'E1 SHOP']) await signal(profiles[0], key);
  for (const key of ['A1 SHOP', 'B1 SHOP']) await signal(profiles[1], key);
  await signal(profiles[2], 'A1 SHOP');
  await pool.query("INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,'TESTBK','<AMT> paid.','queued')", ['a'.repeat(64)]);
  await pool.query("INSERT INTO sms_v2_template_submitters(template_hash,profile_id,eligible) VALUES($1,$2,true)", ['a'.repeat(64), profiles[1]]);
  await pool.query(
    `INSERT INTO sms_v2_correction_cases(profile_id,source_key,fact_ids,correction_kind,stage,trace,request_hash)
     VALUES($1,'sms:synthetic:1','{}','missing','gate','{}'::jsonb,'r1')`, [profiles[1]]);

  const first = await admin.get('/admin/sms/v2/learning/reporters');
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.deepEqual(first.body.reporters.map((row) => [row.profileId, row.signals, row.layouts, row.corrections]), [
    [profiles[0], 5, 0, 0],
    [profiles[1], 2, 1, 1],
    [profiles[2], 1, 0, 0],
  ], 'most active first; an account with nothing is not listed');
  assert.deepEqual(first.body.reporters[0].effectiveLimits, { templates_per_user_per_day: 50, signals_per_user_per_day: 500 });
  assert.equal(first.body.reporters[0].override, null);
  assert.ok(!JSON.stringify(first.body).match(/@|email|phone/i), 'a pseudonymous id and counts only');
  assert.equal((await admin.get('/admin/sms/v2/learning/reporters?days=0')).status, 400);
  assert.equal((await admin.get('/admin/sms/v2/learning/reporters?days=91')).status, 400);

  // A per-user limit shows as the effective limit and as the override.
  const expiresAt = new Date(Date.now() + 2 * 86400000).toISOString();
  const set = await admin.put(`/admin/sms/v2/user-limits/${profiles[0]}/signals_per_user_per_day`, { value: 20, expiresAt, reason: 'Heavy tester' });
  assert.equal(set.status, 200, JSON.stringify(set.body));
  const second = (await admin.get('/admin/sms/v2/learning/reporters')).body.reporters[0];
  assert.equal(second.effectiveLimits.signals_per_user_per_day, 20);
  assert.equal(second.override.key, 'signals_per_user_per_day');
  assert.equal(second.override.value, 20);

  // Ask again: delete the stored suggestion; unknown keys are 404; a reason is needed.
  await pool.query("INSERT INTO sms_v2_merchant_suggestions(merchant_key,category,confidence,why,status) VALUES('BLINKIT','groceries',0.9,'brand_known','ready')");
  const path = `/admin/sms/v2/merchant-suggestions/${encodeURIComponent('BLINKIT')}/ask-again`;
  assert.equal((await admin.post(path, {})).body.error, 'reason_required');
  assert.equal((await admin.post(`/admin/sms/v2/merchant-suggestions/${encodeURIComponent('NOPE SHOP')}/ask-again`, { reason: 'ask again please' })).status, 404);
  assert.equal((await admin.post(`/admin/sms/v2/merchant-suggestions/${encodeURIComponent("BAD'; DROP")}/ask-again`, { reason: 'ask again please' })).body.error, 'shop_key_invalid');
  const asked = await admin.post(path, { reason: 'Prompt improved since' });
  assert.equal(asked.status, 200, JSON.stringify(asked.body));
  assert.equal((await pool.query("SELECT 1 FROM sms_v2_merchant_suggestions WHERE merchant_key='BLINKIT'")).rows.length, 0);
  assert.equal((await admin.post(path, { reason: 'twice' })).status, 404);
  // Accepted again right away after the worker's next ask: the worker, not the route, limits it.
  await pool.query("INSERT INTO sms_v2_merchant_suggestions(merchant_key,category,confidence,why,status) VALUES('BLINKIT','dining',0.8,'brand_known','ready')");
  assert.equal((await admin.post(path, { reason: 'and again' })).status, 200);

  // Decisions and settings reach the audit feed, newest first, with no bodies.
  await admin.post('/admin/sms/v2/learning/decisions', { kind: 'category_choice', merchantKey: 'A1 SHOP', value: 'dining', decision: 'dismissed', reason: 'Too few people' });
  const setting = (await admin.get('/admin/sms/v2/settings')).body.settings.find((row) => row.key === 'signals_min_distinct_users');
  await admin.put('/admin/sms/v2/settings/signals_min_distinct_users', { value: 4, reason: 'Friends run', expectedUpdatedAt: setting.updatedAt });
  const audit = await admin.get('/admin/sms/v2/audit?limit=50');
  assert.equal(audit.status, 200);
  assert.deepEqual(audit.body.entries.map((entry) => [entry.action, entry.reason]), [
    ['sms_v2_setting', 'Friends run'],
    ['sms_v2_learning_decision', 'Too few people'],
    ['sms_v2_suggestion_ask_again', 'and again'],
    ['sms_v2_suggestion_ask_again', 'Prompt improved since'],
    ['sms_v2_user_limit', 'Heavy tester'],
  ]);
  assert.deepEqual(Object.keys(audit.body.entries[0]).sort(), ['action', 'adminId', 'at', 'entity', 'entityId', 'reason']);
  assert.ok(!JSON.stringify(audit.body).includes('before_value') && !JSON.stringify(audit.body).includes('after_value'));
  assert.equal((await admin.get('/admin/sms/v2/audit?limit=1')).body.entries.length, 1);
  assert.equal((await admin.get('/admin/sms/v2/audit?limit=0')).status, 400);
  assert.equal((await admin.get('/admin/sms/v2/audit?limit=500')).status, 400);
});
