'use strict';
// Runs GET /admin/sms/v2/metrics through the private admin app on a fully
// migrated disposable Postgres (SMS_V2_TEST_DATABASE_URL superuser,
// SMS_V2_TEST_ADMIN_DATABASE_URL admin_api_runtime). Skipped otherwise.
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { registerPrivateTemplateRoutes } = require('../../src/sms_v2/ai_templates');
const { createAdminDbHelpers } = require('../../src/admin/server');
const { createAdminApiApp } = require('../../src/admin/app');
const { routeManifest } = require('../../src/admin/route_manifest');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;

test('metrics endpoint: flag, permission and real aggregates', { skip: !url || !adminUrl }, async (t) => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const privatePool = new Pool({ connectionString: adminUrl });
  const owner = crypto.randomUUID();
  const reviewer = crypto.randomUUID();
  const profiles = [crypto.randomUUID(), crypto.randomUUID()];
  const prior = (await pool.query("SELECT is_enabled,rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'")).rows[0];
  const jobId = crypto.randomUUID();
  let server;
  t.after(async () => {
    if (server) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
    if (prior) await pool.query("UPDATE feature_flags SET is_enabled=$1,rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'", [prior.is_enabled, prior.rollout_percent]);
    else await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
    await pool.query('DELETE FROM sms_v2_template_attempts WHERE job_id=$1', [jobId]);
    await pool.query('DELETE FROM sms_v2_rule_stats_profile_daily WHERE profile_id=ANY($1::uuid[])', [profiles]);
    await pool.query('DELETE FROM profiles WHERE id=ANY($1::uuid[])', [profiles]);
    await pool.query('DELETE FROM admin_users WHERE id=ANY($1::uuid[])', [[owner, reviewer]]);
    await Promise.all([pool.end(), privatePool.end()]);
  });
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner'),($3,$4,'reviewer')", [owner, `${owner}@lanec.invalid`, reviewer, `${reviewer}@lanec.invalid`]);
  await pool.query('INSERT INTO profiles(id) VALUES($1),($2)', profiles);
  const hex = (c) => c.repeat(64);
  await pool.query(
    `INSERT INTO sms_v2_facts(fact_id,profile_id,source_key,fact_type,contract_version,observed_at,payload,provenance)
     VALUES($1,$3,'synthetic:a','movement','2.0',now(),'{}','{}'),($2,$4,'synthetic:b','movement','2.0',now(),'{}','{}')`,
    [hex('e'), hex('f'), profiles[0], profiles[1]],
  );
  await pool.query(
    `INSERT INTO sms_v2_events(event_id,profile_id,type,status,legs,confidence,occurred_at,amount_minor)
     VALUES($1,$3,'purchase','complete','[{"factId":"x","role":"debit_leg"}]',1,now(),100),($2,$4,'purchase','complete','[{"factId":"x","role":"debit_leg"}]',1,now(),100)`,
    [hex('e'), hex('f'), profiles[0], profiles[1]],
  );
  await pool.query(
    `INSERT INTO sms_v2_correction_cases(profile_id,source_key,fact_ids,correction_kind,stage,trace,request_hash,shared_learning_eligible)
     VALUES($1,'synthetic:a',ARRAY[$2],'category','category','{}','h1',true)`,
    [profiles[0], hex('e')],
  );
  await pool.query(
    `INSERT INTO sms_v2_rate_counters(profile_id,device_digest,bucket,window_start,used) VALUES($1,'','rules',date_trunc('hour',now()),4)`,
    [profiles[0]],
  );
  await pool.query(
    `INSERT INTO sms_v2_rule_stats_profile_daily(day,profile_id,rule_id,rule_version,app_version,hits,to_review,corrected)
     VALUES((now() AT TIME ZONE 'utc')::date,$1,'R1',1,'1.0.0',9,1,1)`,
    [profiles[0]],
  );
  await pool.query(
    `INSERT INTO sms_v2_template_attempts(template_hash,job_id,attempt,model,capacity_minute,reserved_tokens,total_tokens,cost_usd,outcome)
     VALUES($1,$2,1,'m',date_trunc('minute',now()),10,100,0.25,'ok')`,
    [hex('9'), jobId],
  );

  let actor = owner;
  const helpers = createAdminDbHelpers(privatePool);
  const app = createAdminApiApp({
    routeManifest: routeManifest.filter((row) => row.path.startsWith('/admin/sms/v2/templates') || row.path === '/admin/sms/v2/metrics'),
    introspectAdminSession: async () => ({ active: true, userId: actor, sessionId: 'lane-c', assurance: 'email+webauthn-uv', mfaVerifiedAt: new Date(), expiresAt: new Date(Date.now() + 60000) }),
    ...helpers,
    registerRoutes: registerPrivateTemplateRoutes,
  });
  server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const get = (path) => fetch(`${origin}${path}`, { headers: { authorization: `Bearer ${'x'.repeat(43)}` } });

  await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
  assert.equal((await get('/admin/sms/v2/metrics')).status, 404, 'flag off answers 404');

  await pool.query("INSERT INTO feature_flags(key,is_enabled,rollout_percent) VALUES('sms_pipeline_v2_enabled',true,100)");
  actor = reviewer;
  assert.equal((await get('/admin/sms/v2/metrics')).status, 403, 'a role without learning.read is refused');

  actor = owner;
  assert.equal((await get('/admin/sms/v2/metrics?days=0')).status, 400);
  const res = await get('/admin/sms/v2/metrics?days=7');
  assert.equal(res.status, 200);
  const m = await res.json();
  assert.ok(m.volume.newEvents >= 2);
  assert.ok(m.corrections.cases >= 1);
  assert.ok(m.attestation.correctionsSharedEligible >= 1);
  assert.ok(m.bundleChecks.checks >= 4);
  assert.ok(m.rules.hits >= 0);
  assert.ok(Object.values(m.rules.perCohort).reduce((n, c) => n + c.hits, 0) >= 9);
  assert.ok(m.aiSpend.costUsd >= 0.25);
  assert.ok(Array.isArray(m.ai) && m.ai.length >= 1);
  assert.equal(m.syncErrorRate.available, false);
  assert.doesNotMatch(JSON.stringify(m), new RegExp(profiles[0]));
});
