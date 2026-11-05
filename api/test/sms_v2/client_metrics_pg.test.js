'use strict';
// Lane N: client counters end to end on a fully migrated disposable Postgres
// (SMS_V2_TEST_DATABASE_URL superuser, SMS_V2_TEST_ADMIN_DATABASE_URL admin_api_runtime).
// Skipped otherwise. Phone route -> aggregate rows -> admin metrics gates.
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const express = require('express');
const { registerSmsV2 } = require('../../src/sms_v2');
const { registerPrivateTemplateRoutes } = require('../../src/sms_v2/ai_templates');
const { createAdminDbHelpers } = require('../../src/admin/server');
const { createAdminApiApp } = require('../../src/admin/app');
const { routeManifest } = require('../../src/admin/route_manifest');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;

test('client counters: consent, de-duplication and the go decision through the real route', { skip: !url || !adminUrl }, async (t) => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const privatePool = new Pool({ connectionString: adminUrl });
  const owner = crypto.randomUUID();
  const profiles = [crypto.randomUUID(), crypto.randomUUID(), crypto.randomUUID()];
  const prior = (await pool.query("SELECT is_enabled,rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'")).rows[0];
  const day = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  const marker = `9.${Date.now() % 100000}.0`;
  let publicServer; let adminServer;
  t.after(async () => {
    for (const server of [publicServer, adminServer]) {
      if (server) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
    }
    if (prior) await pool.query("UPDATE feature_flags SET is_enabled=$1,rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'", [prior.is_enabled, prior.rollout_percent]);
    else await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
    await pool.query('DELETE FROM sms_v2_client_metrics_daily WHERE app_version=$1', [marker]);
    await pool.query('DELETE FROM sms_v2_client_metric_receipts WHERE profile_id=ANY($1::uuid[])', [profiles]);
    await pool.query('DELETE FROM profiles WHERE id=ANY($1::uuid[])', [profiles]);
    await pool.query('DELETE FROM admin_users WHERE id=$1', [owner]);
    await Promise.all([pool.end(), privatePool.end()]);
  });
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')", [owner, `${owner}@lanen.invalid`]);
  await pool.query('INSERT INTO profiles(id) VALUES($1),($2),($3)', profiles);
  await pool.query("INSERT INTO user_consents(profile_id,purpose,policy_version,granted) VALUES($1,'sms_shared_learning','t',true),($2,'sms_shared_learning','t',true)", [profiles[0], profiles[1]]);
  await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
  await pool.query("INSERT INTO feature_flags(key,is_enabled,rollout_percent) VALUES('sms_pipeline_v2_enabled',true,100)");

  const withUserClient = async (id, operation) => {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL ROLE app_user');
      await client.query("SELECT set_config('app.user_id',$1,true)", [id]);
      const out = await operation(client);
      await client.query('COMMIT');
      return out;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  };
  const app = express();
  const requireMember = (req, res, next) => { req.userId = req.headers['x-test-user']; return req.userId ? next() : res.sendStatus(401); };
  registerSmsV2(app, {
    withUserClient, requireAuth: requireMember, requireMember, requireSmsV2: (_req, _res, next) => next(), signer: null,
    hooks: { security: { verifyAttestation: async (req) => { req.smsV2Security = { verified: req.headers['x-test-verified'] === '1', sharedLearningEligible: true }; return true; } } },
  });
  publicServer = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => publicServer.once('listening', resolve));
  const origin = `http://127.0.0.1:${publicServer.address().port}`;
  const send = (profile, counters, { verified = true, device = 'device-0001' } = {}) => fetch(`${origin}/sms/v2/client-metrics`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-test-user': profile, 'x-test-verified': verified ? '1' : '0', 'x-sms-device-id': device },
    body: JSON.stringify({ day, appVersion: marker, counters }),
  });

  const first = await send(profiles[0], { sync_attempts: 600, sync_errors_network: 3, migration_started: 2, migration_completed: 2 });
  assert.equal(first.status, 202);
  assert.equal((await first.json()).status, 'recorded');
  assert.equal((await (await send(profiles[0], { sync_attempts: 600 })).json()).status, 'duplicate', 'a re-sent day counts once');
  assert.equal((await (await send(profiles[1], { sync_attempts: 400, sync_errors_server: 1 }, { verified: false, device: 'device-0002' })).json()).status, 'recorded');
  assert.equal((await (await send(profiles[2], { sync_attempts: 9999 })).json()).status, 'no_consent', 'no sharing consent stores nothing');

  const rows = (await pool.query('SELECT attestation,metric,total::int AS total FROM sms_v2_client_metrics_daily WHERE app_version=$1 ORDER BY 1,2', [marker])).rows;
  assert.deepEqual(rows.find((r) => r.attestation === 'verified' && r.metric === 'sync_attempts').total, 600);
  assert.equal(rows.find((r) => r.attestation === 'unverified' && r.metric === 'sync_attempts').total, 400);
  assert.equal(rows.some((r) => r.total === 9999), false);
  const columns = (await pool.query("SELECT column_name FROM information_schema.columns WHERE table_name='sms_v2_client_metrics_daily'")).rows.map((r) => r.column_name);
  assert.deepEqual(columns.sort(), ['app_version', 'attestation', 'day', 'metric', 'total']);

  const helpers = createAdminDbHelpers(privatePool);
  const adminApp = createAdminApiApp({
    routeManifest: routeManifest.filter((row) => row.path.startsWith('/admin/sms/v2/templates') || row.path === '/admin/sms/v2/metrics'),
    introspectAdminSession: async () => ({ active: true, userId: owner, sessionId: 'lane-n', assurance: 'email+webauthn-uv', mfaVerifiedAt: new Date(), expiresAt: new Date(Date.now() + 60000) }),
    ...helpers,
    registerRoutes: registerPrivateTemplateRoutes,
  });
  adminServer = adminApp.listen(0, '127.0.0.1');
  await new Promise((resolve) => adminServer.once('listening', resolve));
  const res = await fetch(`http://127.0.0.1:${adminServer.address().port}/admin/sms/v2/metrics?days=7`, { headers: { authorization: `Bearer ${'x'.repeat(43)}` } });
  assert.equal(res.status, 200);
  const m = await res.json();
  assert.equal(m.syncErrorRate.available, true);
  assert.ok(m.syncErrorRate.attempts >= 1000);
  assert.ok(m.syncErrorRate.errors >= 4);
  assert.equal(m.migrationFailureRate.available, true);
  const mine = m.clientReports.byVersion.filter((row) => row.appVersion === marker);
  assert.deepEqual(mine.map((row) => [row.attestation, row.syncAttempts, row.syncErrors]).sort(), [['unverified', 400, 1], ['verified', 600, 3]]);
  assert.ok(m.clientReports.reports >= 2);
  assert.doesNotMatch(JSON.stringify(m.clientReports), new RegExp(`${profiles[0]}|device-0001`));
});
