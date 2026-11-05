'use strict';
// Runs the rule service against a real Postgres that already has the
// 20261110120000_sms_v2_rules migration. Skipped unless SMS_V2_TEST_DATABASE_URL
// is set (a disposable local database only; the test inserts and then deletes rows).
//   SMS_V2_TEST_DATABASE_URL=postgres://postgres:pw@127.0.0.1:5548/db node --test api/test/sms_v2/rules_pg.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;
const skip = url && adminUrl ? false : 'SMS_V2_TEST_DATABASE_URL and SMS_V2_TEST_ADMIN_DATABASE_URL not set';

test('PgStore: import, publish, serve, pause, stats and jobs on a real database', { skip }, async () => {
  const { Pool } = require('pg');
  const { createPgStore } = require('../../src/sms_v2/rules_store');
  const { createAdminDbHelpers } = require('../../src/admin/server');
  const { createSigner, verifyBundle } = require('../../src/sms_v2/signer');
  const { importBundle, saveDraft, publishVersion, pauseVersion, rollbackRule } = require('../../src/sms_v2/rules_admin_route');
  const { runRuleJobs } = require('../../src/sms_v2/rule_stats');
  const { cohortFor } = require('../../src/sms_v2/bundle_builder');

  const pool = new Pool({ connectionString: url });
  const withUserClient = async (userId, fn) => {
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await c.query('SET LOCAL ROLE app_user');
      await c.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      const out = await fn(c);
      await c.query('COMMIT');
      return out;
    } catch (e) {
      await c.query('ROLLBACK');
      throw e;
    } finally { c.release(); }
  };
  const userStore = createPgStore({ withUserClient });
  const { openRuleAdminStore } = require('../../src/sms_v2/admin_store');
  const { pool: privatePool, store: adminStore } = await openRuleAdminStore({
    env: { ADMIN_API_DATABASE_URL: adminUrl, DB_SSL: 'false', NODE_ENV: 'test' },
  });
  const { withAdminClient } = createAdminDbHelpers(privatePool);
  const kp = crypto.generateKeyPairSync('ed25519');
  const signer = createSigner({ privateKeyPem: kp.privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId: 'pg-test' });
  const full = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../contracts/sms/v2/fixtures/valid/bundle/full.json'), 'utf8'));
  const admin = crypto.randomUUID();
  const profile = crypto.randomUUID();
  // Auto-pause needs reports from AUTO_PAUSE_MIN_DEVICES distinct phones.
  const { AUTO_PAUSE_MIN_DEVICES } = require('../../src/sms_v2/rule_stats');
  const reporters = [profile, ...Array.from({ length: AUTO_PAUSE_MIN_DEVICES - 1 }, () => crypto.randomUUID())];
  const clean = async () => {
    for (const t of ['sms_v2_rule_stats_profile_daily', 'sms_v2_rule_stats_daily', 'sms_v2_rule_cohorts', 'sms_v2_bundles', 'sms_v2_bundle_parts', 'sms_v2_rules']) await pool.query(`DELETE FROM ${t}`);
    await pool.query('DELETE FROM admin_audit_log WHERE admin_id = $1', [admin]);
    await pool.query('DELETE FROM admin_users WHERE id = $1', [admin]);
    await pool.query('DELETE FROM profiles WHERE id = ANY($1::uuid[])', [reporters]);
  };
  await clean();
  const priorFlag = (await pool.query("SELECT is_enabled, rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'")).rows[0];
  for (const id of reporters) await pool.query('INSERT INTO profiles(id) VALUES ($1)', [id]);
  await pool.query("INSERT INTO admin_users(id, email, role, is_active) VALUES ($1, $2, 'owner', true)", [admin, `${admin}@example.invalid`]);
  const now = new Date('2026-11-20T10:00:00Z');
  try {
    await assert.rejects(withUserClient(profile, async client => {
      await client.query("SELECT set_config('pandapay.admin_actor', $1, true), set_config('pandapay.admin_permission', 'learning.publish', true)", [admin]);
      assert.equal((await client.query('SELECT pandapay.is_admin() AS allowed')).rows[0].allowed, false);
      assert.equal((await client.query('SELECT count(*)::int AS n FROM sms_v2_rules')).rows[0].n, 0);
      await client.query("INSERT INTO sms_v2_rules(rule_id,version,status,family,body,created_by) VALUES ('FORGED',1,'draft','card_spend','{}','admin')");
    }), { code: '42501' });
    await assert.rejects(withAdminClient(admin, 'learning.read', client =>
      client.query("INSERT INTO sms_v2_rules(rule_id,version,status,family,body,created_by) VALUES ('READ-ONLY',1,'draft','card_spend','{}','admin')")), { code: '42501' });
    await assert.rejects(withAdminClient(admin, 'learning.read', client =>
      client.query('SELECT pandapay.sms_v2_rollup_rule_stats()')), { code: '42501' });
    const imp = await adminStore.tx(admin, (s) => importBundle(s, full, { signer, adminId: admin, now }));
    assert.equal(imp.minted[0].bundleVersion, 1);
    const again = await adminStore.tx(admin, (s) => importBundle(s, full, { signer, adminId: admin, now }));
    assert.equal(again.minted.length, 0);

    const cohort = cohortFor(profile, false);
    const served = await userStore.tx(profile, async (s) => s.phoneBundle(cohort));
    assert.equal(served.bundleVersion >= 1, true);
    assert.deepEqual(served.body.rules.map((r) => r.id), ['HDFC-CARD-SPEND-03']);

    // Exercise the same private HTTP registrar and database helper used at runtime.
    const { createAdminApiApp } = require('../../src/admin/app');
    const { registerPrivateRulesAdminRoutes } = require('../../src/sms_v2/rules_admin_route');
    const policies = require('../../src/admin/route_manifest').routeManifest.filter(p => (p.path.startsWith('/admin/sms/v2/rules') || p.path === '/admin/sms/v2/bundles'));
    await pool.query("INSERT INTO feature_flags(key,is_enabled,rollout_percent) VALUES('sms_pipeline_v2_enabled',true,100) ON CONFLICT(key) DO UPDATE SET is_enabled=true, rollout_percent=100");
    const app = createAdminApiApp({
      routeManifest: policies,
      introspectAdminSession: async () => ({ active: true, userId: admin, sessionId: 'fixture', assurance: 'email+webauthn-uv', mfaVerifiedAt: new Date(), expiresAt: new Date(Date.now()+60000) }),
      loadPermissions: createAdminDbHelpers(privatePool).loadPermissions,
      withAdminClient,
      registerRoutes: api => registerPrivateRulesAdminRoutes(api, { signer, now: () => now, getGates: () => ({ m1: {} }) }),
    });
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    try {
      const origin = `http://127.0.0.1:${server.address().port}`;
      const headers = { authorization: `Bearer ${'a'.repeat(43)}`, 'content-type': 'application/json' };
      const listed = await fetch(`${origin}/admin/sms/v2/rules`, { headers });
      assert.equal(listed.status, 200, await listed.text());
      const draft = await fetch(`${origin}/admin/sms/v2/rules/HDFC-CARD-SPEND-03/draft`, { method: 'PUT', headers, body: JSON.stringify({ ...full.rules[0], confidence: 0.5, status: 'draft' }) });
      const body = await draft.json();
      assert.equal(draft.status, 200, JSON.stringify(body));
      assert.equal(body.version, 2);
    } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    const cand = await adminStore.tx(admin, async (s) => {
      const b = require('../../src/sms_v2/bundle_builder');
      const rows = await s.allRules();
      const act = rows.map((r) => (r.ruleId === 'HDFC-CARD-SPEND-03' && r.version === 2 ? { ...r, status: 'active', body: { ...r.body, status: 'active' } } : r));
      const parts = await s.getParts();
      const cohorts = [...(await s.allCohorts()), { ruleId: 'HDFC-CARD-SPEND-03', version: 2, cohort: 'pct25', pausedAt: null }];
      return b.contentSha256(b.candidateBundle({ manifest: b.buildManifest('pct25', act, cohorts, parts), rules: act, parts, now }));
    });
    const gates = { m1: {} };
    const pub = await adminStore.tx(admin, (s) => publishVersion(s, 'HDFC-CARD-SPEND-03', { version: 2, cohort: 'pct25', goldenReport: { total: 1, passed: 1, bundleSha256: cand } }, { signer, adminId: admin, now, gates }));
    assert.equal(pub.contentSha256, cand);
    const row = await userStore.tx(profile, (s) => s.phoneBundle('pct25'));
    assert.equal(row.body.rules[0].confidence, 0.5);
    assert.ok(verifyBundle({ ...row.body, signature: { alg: 'Ed25519', keyId: 'pg-test', value: (await adminStore.tx(admin, (s) => s.latestBundle('pct25'))).signature } }, signer.publicKeyPem));

    // stats through the security-definer function, then the job
    const realNow = new Date();
    const day = realNow.toISOString().slice(0, 10);
    const hits = Math.ceil(60 / reporters.length);
    for (const id of reporters) {
      await userStore.tx(id, (s) => s.recordRuleStats(id, day, '1.0.0', [{ ruleId: 'HDFC-CARD-SPEND-03', ruleVersion: 2, hits, toReview: 0, corrected: Math.ceil(hits / 2) }]));
    }
    const out = await runRuleJobs({ store: adminStore, signer, adminId: admin, now: realNow });
    assert.deepEqual(out.paused.map((p) => p.version), [2]);
    const rb = await adminStore.tx(admin, (s) => rollbackRule(s, 'HDFC-CARD-SPEND-03', { toVersion: 1, reason: 't' }, { signer, adminId: admin, now }));
    assert.equal(rb.version, 3);
    await assert.rejects(adminStore.tx(admin, (s) => pauseVersion(s, 'NOPE', { reason: 'x' }, { signer, adminId: admin, now })));
    const audits = await pool.query('SELECT action FROM admin_audit_log WHERE admin_id = $1', [admin]);
    assert.ok(audits.rows.length >= 5);
  } finally {
    if (priorFlag) await pool.query("UPDATE feature_flags SET is_enabled=$1, rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'", [priorFlag.is_enabled, priorFlag.rollout_percent]);
    else await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
    await clean();
    await privatePool.end();
    await pool.end();
  }
});
