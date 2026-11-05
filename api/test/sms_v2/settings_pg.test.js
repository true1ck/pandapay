'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const express = require('express');
const { Pool } = require('pg');
const { createAdminDbHelpers } = require('../../src/admin/server');
const { createAdminApiApp } = require('../../src/admin/app');
const { routeManifest } = require('../../src/admin/route_manifest');
const { registerSmsV2 } = require('../../src/sms_v2');
const { createSecurity } = require('../../src/sms_v2/security');
const { registerPrivateSettingsRoutes } = require('../../src/sms_v2/settings_admin_route');
const { clearSettingsCache } = require('../../src/sms_v2/settings');
const { template } = require('./fixtures/template_draft');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;
const V3 = 'sms-shared-learning-v3';

test('settings and per-user limits on a fully migrated Postgres', { skip: !url || !adminUrl }, async (t) => {
  const pool = new Pool({ connectionString: url });
  const privatePool = new Pool({ connectionString: adminUrl });
  const profile = crypto.randomUUID();
  const other = crypto.randomUUID();
  const admin = crypto.randomUUID();
  let adminServer;
  let publicServer;
  const prior = (await pool.query("SELECT is_enabled,rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'")).rows[0];
  t.after(async () => {
    for (const server of [adminServer, publicServer]) {
      if (server) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
    }
    await pool.query('DELETE FROM sms_v2_settings');
    await pool.query('DELETE FROM profiles WHERE id = ANY($1::uuid[])', [[profile, other]]);
    await pool.query('DELETE FROM sms_v2_unknown_templates WHERE template_hash = $1', [template.template_hash]);
    await pool.query('DELETE FROM admin_audit_log WHERE admin_id = $1', [admin]);
    await pool.query('DELETE FROM admin_users WHERE id = $1', [admin]);
    if (prior) {
      await pool.query("UPDATE feature_flags SET is_enabled=$1,rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'", [prior.is_enabled, prior.rollout_percent]);
    } else {
      await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
    }
    await Promise.all([pool.end(), privatePool.end()]);
  });
  clearSettingsCache();
  for (const id of [profile, other]) await pool.query('INSERT INTO profiles(id) VALUES($1)', [id]);
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')", [admin, `${admin}@example.invalid`]);
  await pool.query("INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at) VALUES($1,'sms_shared_learning',$2,true,clock_timestamp())", [profile, V3]);
  await pool.query(
    "INSERT INTO feature_flags(key,is_enabled,rollout_percent) VALUES('sms_pipeline_v2_enabled',true,100) ON CONFLICT(key) DO UPDATE SET is_enabled=true,rollout_percent=100");

  const limit = async (id, key, fallback) => (await pool.query('SELECT pandapay.sms_v2_limit($1,$2,$3) AS n', [id, key, fallback])).rows[0].n;

  // ---- sms_v2_limit: override, then setting, then default; expired overrides are ignored.
  assert.equal(await limit(profile, 'templates_per_user_per_day', 50), 50);
  await pool.query("INSERT INTO sms_v2_settings(key,value,updated_by,reason) VALUES('templates_per_user_per_day','20'::jsonb,$1,'test setting')", [admin]);
  assert.equal(await limit(profile, 'templates_per_user_per_day', 50), 20);
  await pool.query("INSERT INTO sms_v2_user_limits(profile_id,key,value,expires_at,updated_by,reason) VALUES($1,'templates_per_user_per_day',99,now()+interval '2 days',$2,'test override')", [profile, admin]);
  assert.equal(await limit(profile, 'templates_per_user_per_day', 50), 99);
  assert.equal(await limit(other, 'templates_per_user_per_day', 50), 20, 'another user keeps the setting');
  await pool.query("UPDATE sms_v2_user_limits SET expires_at = now() - interval '1 minute', created_at = now() - interval '2 days' WHERE profile_id = $1", [profile]);
  assert.equal(await limit(profile, 'templates_per_user_per_day', 50), 20, 'expired override ignored');
  await pool.query('DELETE FROM sms_v2_user_limits WHERE profile_id = $1', [profile]);
  await pool.query("DELETE FROM sms_v2_settings WHERE key='templates_per_user_per_day'");
  await assert.rejects(
    pool.query("INSERT INTO sms_v2_user_limits(profile_id,key,value,expires_at,updated_by,reason) VALUES($1,'templates_per_user_per_day',5,now()+interval '91 days',$2,'too long')", [profile, admin]),
    { code: '23514' }, 'an override lasts at most 90 days');
  await assert.rejects(
    pool.query("INSERT INTO sms_v2_user_limits(profile_id,key,value,expires_at,updated_by,reason) VALUES($1,'ai_rpm',5,now()+interval '1 day',$2,'bad key')", [profile, admin]),
    { code: '23514' });

  // ---- The admin routes, mounted on the real admin app with the real manifest policy.
  const helpers = createAdminDbHelpers(privatePool);
  const paths = new Set([
    '/admin/sms/v2/settings', '/admin/sms/v2/settings/:key',
    '/admin/sms/v2/user-limits', '/admin/sms/v2/user-limits/:profileId/:key',
  ]);
  const adminApp = createAdminApiApp({
    routeManifest: routeManifest.filter((row) => paths.has(row.path)),
    introspectAdminSession: async () => ({
      active: true, userId: admin, sessionId: 'test', assurance: 'email+webauthn-uv',
      mfaVerifiedAt: new Date(), expiresAt: new Date(Date.now() + 60000),
    }),
    ...helpers,
    registerRoutes: (api) => registerPrivateSettingsRoutes(api, { env: { SMS_V2_AI_MODEL: 'model-a', SMS_V2_AI_MODELS_ALLOWED: 'model-a,model-b', SMS_V2_AI_RPM: '60' } }),
  });
  adminServer = adminApp.listen(0, '127.0.0.1');
  await new Promise((resolve) => adminServer.once('listening', resolve));
  const adminOrigin = `http://127.0.0.1:${adminServer.address().port}`;
  const headers = { authorization: `Bearer ${'x'.repeat(43)}`, 'content-type': 'application/json' };
  const call = async (method, path, body) => {
    const response = await fetch(`${adminOrigin}${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json() };
  };

  const listed = await call('GET', '/admin/sms/v2/settings');
  assert.equal(listed.status, 200);
  assert.equal(listed.body.settings.find((row) => row.key === 'ai_enabled').value, true);
  assert.ok(listed.body.settings.every((row) => row.updatedAt === null));

  // No reason, bad values and unknown keys.
  assert.equal((await call('PUT', '/admin/sms/v2/settings/signals_min_distinct_users', { value: 4, expectedUpdatedAt: null })).status, 400);
  assert.equal((await call('PUT', '/admin/sms/v2/settings/signals_min_distinct_users', { value: 4, reason: 'x', expectedUpdatedAt: null })).status, 400);
  const tooLow = await call('PUT', '/admin/sms/v2/settings/signals_min_distinct_users', { value: 1, reason: 'friends run', expectedUpdatedAt: null });
  assert.equal(tooLow.status, 422);
  assert.equal(tooLow.body.error, 'setting_invalid');
  assert.equal((await call('PUT', '/admin/sms/v2/settings/not_a_key', { value: 1, reason: 'friends run', expectedUpdatedAt: null })).status, 404);
  assert.equal((await call('PUT', '/admin/sms/v2/settings/ai_rpm', { value: 61, reason: 'raise it', expectedUpdatedAt: null })).status, 422, 'above the environment ceiling');
  assert.equal((await call('PUT', '/admin/sms/v2/settings/ai_model', { value: 'model-c', reason: 'try it', expectedUpdatedAt: null })).status, 422, 'not on the allow-list');

  // Accepted write, then a stale write to the same key.
  const first = await call('PUT', '/admin/sms/v2/settings/signals_min_distinct_users', { value: 4, reason: 'friends run', expectedUpdatedAt: null });
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal(first.body.setting.value, 4);
  assert.match(first.body.setting.updatedAt, /^\d{4}-\d\d-\d\dT[\d:.]+Z$/);
  const stale = await call('PUT', '/admin/sms/v2/settings/signals_min_distinct_users', { value: 5, reason: 'second admin', expectedUpdatedAt: null });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.error, 'setting_stale');
  const second = await call('PUT', '/admin/sms/v2/settings/signals_min_distinct_users', { value: 5, reason: 'second admin', expectedUpdatedAt: first.body.setting.updatedAt });
  assert.equal(second.status, 200);
  assert.equal(second.body.setting.value, 5);
  assert.equal((await call('GET', '/admin/sms/v2/settings')).body.settings.find((row) => row.key === 'signals_min_distinct_users').value, 5);

  // Per-user limits through the routes.
  const limitPath = `/admin/sms/v2/user-limits/${profile}/templates_per_user_per_day`;
  const day = new Date(Date.now() + 86400000).toISOString();
  assert.equal((await call('PUT', limitPath, { value: 5, expiresAt: day })).status, 400, 'reason required');
  assert.equal((await call('PUT', limitPath, { value: 5, expiresAt: new Date(Date.now() - 1000).toISOString(), reason: 'past' })).status, 422);
  assert.equal((await call('PUT', limitPath, { value: 5, expiresAt: new Date(Date.now() + 91 * 86400000).toISOString(), reason: 'too long' })).status, 422);
  assert.equal((await call('PUT', `/admin/sms/v2/user-limits/${profile}/ai_rpm`, { value: 5, expiresAt: day, reason: 'bad key' })).status, 404);
  assert.equal((await call('PUT', `/admin/sms/v2/user-limits/${crypto.randomUUID()}/templates_per_user_per_day`, { value: 5, expiresAt: day, reason: 'nobody' })).status, 404);
  const set = await call('PUT', limitPath, { value: 3, expiresAt: day, reason: 'heavy tester' });
  assert.equal(set.status, 200, JSON.stringify(set.body));
  const limits = await call('GET', '/admin/sms/v2/user-limits');
  assert.equal(limits.body.limits.length, 1);
  assert.equal(limits.body.limits[0].profileId, profile);
  assert.equal(limits.body.limits[0].active, true);
  assert.equal(await limit(profile, 'templates_per_user_per_day', 50), 3);

  // The cap really applies to layout submissions (SQL path, no HTTP).
  const withUser = async (id, operation) => {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL ROLE app_user');
      await client.query("SELECT set_config('app.user_id',$1,true)", [id]);
      const out = await operation(client);
      await client.query('COMMIT');
      return out;
    } catch (error) { await client.query('ROLLBACK'); throw error; } finally { client.release(); }
  };
  const item = (n) => ({
    templateHash: crypto.createHash('sha256').update(`t${n}`).digest('hex'), senderBrand: 'TESTBK',
    redactedBody: '<AMT> paid to <PARTY>.', observedAt: new Date().toISOString(),
  });
  const submit = (...items) => withUser(profile, (client) => client.query(
    'SELECT * FROM pandapay.sms_v2_submit_templates($1::jsonb,true)', [JSON.stringify(items)]));
  assert.equal((await submit(item(1), item(2), item(3))).rows.length, 3);
  await assert.rejects(submit(item(4)), { code: 'P0050' });
  assert.equal((await call('DELETE', limitPath, { reason: 'done' })).status, 200);
  assert.equal((await call('DELETE', limitPath, { reason: 'done again' })).status, 404);
  assert.equal(await limit(profile, 'templates_per_user_per_day', 50), 50);
  assert.equal((await submit(item(4))).rows.length, 1);
  await pool.query("DELETE FROM sms_v2_unknown_templates WHERE template_hash = ANY($1::text[])", [[1, 2, 3, 4].map((n) => item(n).templateHash)]);

  // Every accepted change is in the audit log with its reason; refused ones are not.
  const audited = (await pool.query(
    "SELECT action, reason, after_value FROM admin_audit_log WHERE admin_id = $1 AND action LIKE 'sms_v2_%' ORDER BY id", [admin])).rows;
  assert.deepEqual(audited.map((row) => [row.action, row.reason]), [
    ['sms_v2_setting', 'friends run'],
    ['sms_v2_setting', 'second admin'],
    ['sms_v2_user_limit', 'heavy tester'],
    ['sms_v2_user_limit', 'done'],
  ]);
  assert.equal(audited[1].after_value.value, 5);

  // ---- Pausing intake over the real public routes, backed by the real settings table.
  const app = express();
  const requireMember = (req, res, next) => { req.userId = req.headers['x-test-user']; return req.userId ? next() : res.sendStatus(401); };
  const security = createSecurity({
    env: { SMS_V2_ATTESTATION_MODE: 'monitor', SMS_V2_ATTESTATION_BINDING: 'off' },
    withUserClient: (id, fn) => withUser(id, fn),
  });
  registerSmsV2(app, {
    withUserClient: withUser, requireAuth: requireMember, requireMember,
    requireSmsV2: (_req, _res, next) => next(), signer: null, hooks: { security },
  });
  publicServer = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => publicServer.once('listening', resolve));
  const publicOrigin = `http://127.0.0.1:${publicServer.address().port}`;
  const post = (n) => fetch(`${publicOrigin}/sms/v2/unknown-templates`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-test-user': profile },
    body: JSON.stringify({ items: [item(n)] }),
  });
  assert.equal((await post(10)).status, 202);
  const intake = await call('GET', '/admin/sms/v2/settings');
  const row = intake.body.settings.find((entry) => entry.key === 'intake_enabled');
  const paused = await call('PUT', '/admin/sms/v2/settings/intake_enabled', { value: false, reason: 'investigating abuse', expectedUpdatedAt: row.updatedAt });
  assert.equal(paused.status, 200);
  const refused = await post(11);
  assert.equal(refused.status, 503);
  assert.equal(refused.headers.get('retry-after'), '3600');
  assert.deepEqual(await refused.json(), { error: 'learning_paused' });
  const resumed = await call('PUT', '/admin/sms/v2/settings/intake_enabled', { value: true, reason: 'resolved', expectedUpdatedAt: paused.body.setting.updatedAt });
  assert.equal(resumed.status, 200);
  assert.equal((await post(12)).status, 202);
  await pool.query("DELETE FROM sms_v2_unknown_templates WHERE template_hash = ANY($1::text[])", [[10, 11, 12].map((n) => item(n).templateHash)]);
});
