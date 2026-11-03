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
const skip = url ? false : 'SMS_V2_TEST_DATABASE_URL not set';

test('PgStore: import, publish, serve, pause, stats and jobs on a real database', { skip }, async () => {
  const { Pool } = require('pg');
  const { createPgStore } = require('../../src/sms_v2/rules_store');
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
  const store = createPgStore({ withUserClient });
  const kp = crypto.generateKeyPairSync('ed25519');
  const signer = createSigner({ privateKeyPem: kp.privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId: 'pg-test' });
  const full = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../contracts/sms/v2/fixtures/valid/bundle/full.json'), 'utf8'));
  const admin = crypto.randomUUID();
  const profile = crypto.randomUUID();
  const clean = async () => {
    for (const t of ['sms_v2_rule_stats_profile_daily', 'sms_v2_rule_stats_daily', 'sms_v2_rule_cohorts', 'sms_v2_bundles', 'sms_v2_bundle_parts', 'sms_v2_rules']) await pool.query(`DELETE FROM ${t}`);
    await pool.query('DELETE FROM admin_audit_log WHERE admin_id = $1', [admin]);
    await pool.query('DELETE FROM admin_users WHERE id = $1', [admin]);
    await pool.query('DELETE FROM profiles WHERE id = $1', [profile]);
  };
  await clean();
  await pool.query('INSERT INTO profiles(id) VALUES ($1)', [profile]);
  await pool.query('INSERT INTO admin_users(id, is_active) VALUES ($1, true)', [admin]);
  const now = new Date('2026-11-20T10:00:00Z');
  try {
    const imp = await store.tx(admin, (s) => importBundle(s, full, { signer, adminId: admin, now }));
    assert.equal(imp.minted[0].bundleVersion, 1);
    const again = await store.tx(admin, (s) => importBundle(s, full, { signer, adminId: admin, now }));
    assert.equal(again.minted.length, 0);

    const cohort = cohortFor(profile, false);
    const served = await store.tx(profile, async (s) => s.phoneBundle(cohort));
    assert.equal(served.bundleVersion >= 1, true);
    assert.deepEqual(served.body.rules.map((r) => r.id), ['HDFC-CARD-SPEND-03']);

    const draft = await store.tx(admin, (s) => saveDraft(s, 'HDFC-CARD-SPEND-03', { ...full.rules[0], confidence: 0.5, status: 'draft' }, { adminId: admin, now }));
    assert.equal(draft.version, 2);
    const cand = await store.tx(admin, async (s) => {
      const b = require('../../src/sms_v2/bundle_builder');
      const rows = await s.allRules();
      const act = rows.map((r) => (r.ruleId === 'HDFC-CARD-SPEND-03' && r.version === 2 ? { ...r, status: 'active', body: { ...r.body, status: 'active' } } : r));
      const parts = await s.getParts();
      const cohorts = [...(await s.allCohorts()), { ruleId: 'HDFC-CARD-SPEND-03', version: 2, cohort: 'pct25', pausedAt: null }];
      return b.contentSha256(b.candidateBundle({ manifest: b.buildManifest('pct25', act, cohorts, parts), rules: act, parts, now }));
    });
    const gates = { m1: {} };
    const pub = await store.tx(admin, (s) => publishVersion(s, 'HDFC-CARD-SPEND-03', { version: 2, cohort: 'pct25', goldenReport: { total: 1, passed: 1, bundleSha256: cand } }, { signer, adminId: admin, now, gates }));
    assert.equal(pub.contentSha256, cand);
    const row = await store.tx(profile, (s) => s.phoneBundle('pct25'));
    assert.equal(row.body.rules[0].confidence, 0.5);
    assert.ok(verifyBundle({ ...row.body, signature: { alg: 'Ed25519', keyId: 'pg-test', value: (await store.tx(admin, (s) => s.latestBundle('pct25'))).signature } }, signer.publicKeyPem));

    // stats through the security-definer function, then the job
    const realNow = new Date();
    const day = realNow.toISOString().slice(0, 10);
    await store.tx(profile, (s) => s.recordRuleStats(profile, day, '1.0.0', [{ ruleId: 'HDFC-CARD-SPEND-03', ruleVersion: 2, hits: 60, toReview: 0, corrected: 30 }]));
    const out = await runRuleJobs({ store, signer, adminId: admin, now: realNow });
    assert.deepEqual(out.paused.map((p) => p.version), [2]);
    const rb = await store.tx(admin, (s) => rollbackRule(s, 'HDFC-CARD-SPEND-03', { toVersion: 1, reason: 't' }, { signer, adminId: admin, now }));
    assert.equal(rb.version, 3);
    await assert.rejects(store.tx(admin, (s) => pauseVersion(s, 'NOPE', { reason: 'x' }, { signer, adminId: admin, now })));
    const audits = await pool.query('SELECT action FROM admin_audit_log WHERE admin_id = $1', [admin]);
    assert.ok(audits.rows.length >= 5);
  } finally {
    await clean();
    await pool.end();
  }
});
