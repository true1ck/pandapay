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
  const paths = new Set([
    '/admin/sms/v2/learning/summary', '/admin/sms/v2/learning/categories', '/admin/sms/v2/learning/merchant-names',
    '/admin/sms/v2/learning/uncategorised', '/admin/sms/v2/learning/decisions',
  ]);
  const app = createAdminApiApp({
    routeManifest: routeManifest.filter((row) => paths.has(row.path)),
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
  await pool.query("INSERT INTO sms_v2_settings(key,value,updated_by,reason) VALUES('signals_min_distinct_users','8'::jsonb,$1,'stricter')", [admin]);
  clearSettingsCache();
  assert.equal((await rows('categories')).length, 0);
  assert.equal((await call('GET', '/admin/sms/v2/learning/categories')).body.minUsers, 8);
});
