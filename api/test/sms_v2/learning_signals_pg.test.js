'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const express = require('express');
const { Pool } = require('pg');
const { registerSmsV2 } = require('../../src/sms_v2');
const { createSigner } = require('../../src/sms_v2/signer');
const { runRuleJobs } = require('../../src/sms_v2/rule_stats');
const { openRuleAdminStore } = require('../../src/sms_v2/admin_store');
const { clearSettingsCache } = require('../../src/sms_v2/settings');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;
const V2 = 'sms-shared-learning-v2';
const V3 = 'sms-shared-learning-v3';

test('learning signals: consent, counting, caps, revocation, cascade and retention on Postgres', { skip: !url || !adminUrl }, async (t) => {
  const pool = new Pool({ connectionString: url });
  const [p1, p2, p3, legacy] = [1, 2, 3, 4].map(() => crypto.randomUUID());
  const admin = crypto.randomUUID();
  let server;
  let privatePool;
  const prior = (await pool.query("SELECT is_enabled,rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'")).rows[0];
  t.after(async () => {
    if (server) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
    await pool.query('DELETE FROM sms_v2_settings');
    await pool.query('DELETE FROM profiles WHERE id = ANY($1::uuid[])', [[p1, p2, p3, legacy]]);
    await pool.query('DELETE FROM admin_audit_log WHERE admin_id = $1', [admin]);
    await pool.query('DELETE FROM admin_users WHERE id = $1', [admin]);
    if (prior) await pool.query("UPDATE feature_flags SET is_enabled=$1,rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'", [prior.is_enabled, prior.rollout_percent]);
    else await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
    if (privatePool) await privatePool.end();
    await pool.end();
  });
  clearSettingsCache();
  for (const id of [p1, p2, p3, legacy]) await pool.query('INSERT INTO profiles(id) VALUES($1)', [id]);
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')", [admin, `${admin}@example.invalid`]);
  const consent = (id, version, granted, at = 'clock_timestamp()') => pool.query(
    `INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at) VALUES($1,'sms_shared_learning',$2,$3,${at})`, [id, version, granted]);
  await consent(p1, V3, true);
  await consent(p2, V3, true);
  await consent(p3, V3, true);
  await consent(legacy, V2, true);

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
  const app = express();
  const requireMember = (req, res, next) => { req.userId = req.headers['x-test-user']; return req.userId ? next() : res.sendStatus(401); };
  registerSmsV2(app, {
    withUserClient: withUser, requireAuth: requireMember, requireMember,
    requireSmsV2: (_req, _res, next) => next(), signer: null,
    hooks: { security: {
      verifyAttestation: async (req) => { req.smsV2Security = { sharedLearningEligible: req.headers['x-test-verified'] === '1' }; return true; },
      checkRate: async () => true,
    } },
  });
  server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const send = (profile, items, verified = true) => fetch(`${origin}/sms/v2/learning-signals`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-test-user': profile, 'x-test-verified': verified ? '1' : '0' },
    body: JSON.stringify({ items }),
  });
  const swiggy = { kind: 'category_choice', senderBrand: 'HDFCBK', merchantKey: 'SWIGGY', value: 'dining', eventType: 'purchase', taxonomyVersion: 1 };
  const rows = (id) => pool.query('SELECT * FROM sms_v2_learning_signals WHERE profile_id = $1 ORDER BY merchant_key', [id]).then((r) => r.rows);

  // Consent: nothing for a v2-only profile, and nothing was stored for it.
  const refused = await send(legacy, [swiggy]);
  assert.equal(refused.status, 403);
  assert.equal((await refused.json()).error, 'sms_shared_learning_consent_required');
  assert.equal((await rows(legacy)).length, 0);

  // The same signal twice is one row with times = 2.
  assert.equal((await send(p1, [swiggy])).status, 202);
  assert.equal((await send(p1, [swiggy])).status, 202);
  const stored = await rows(p1);
  assert.equal(stored.length, 1);
  assert.equal(stored[0].times, 2);
  assert.equal(stored[0].eligible, true);
  assert.equal(stored[0].kind, 'category_choice');

  // Unattested requests are stored with eligible = false; a later attested one lifts it.
  assert.equal((await send(p2, [swiggy], false)).status, 202);
  assert.equal((await rows(p2))[0].eligible, false);
  assert.equal((await send(p2, [swiggy], true)).status, 202);
  assert.equal((await rows(p2))[0].eligible, true);

  // Different kinds and values are separate rows.
  const name = { kind: 'merchant_name', senderBrand: 'ICICIB', merchantKey: 'PAYU SWIGGY', value: 'SWIGGY', eventType: 'purchase', taxonomyVersion: 1 };
  const other = { kind: 'uncategorised', senderBrand: 'ICICIB', merchantKey: 'BLINKIT', value: '', eventType: 'purchase', taxonomyVersion: 1 };
  assert.equal((await send(p3, [swiggy, name, other])).status, 202);
  assert.equal((await rows(p3)).length, 3);

  // The database also refuses keys the route would (defence in depth).
  await assert.rejects(withUser(p3, (client) => client.query(
    "SELECT pandapay.sms_v2_submit_signals($1::jsonb,true)",
    [JSON.stringify([{ ...swiggy, merchantKey: 'PAYTMQR2810050501' }])])), { code: '23514' });

  // Daily cap through the setting, then a per-user override.
  await pool.query("INSERT INTO sms_v2_settings(key,value,updated_by,reason) VALUES('signals_per_user_per_day','3'::jsonb,$1,'test cap')", [admin]);
  const extra = { ...swiggy, merchantKey: 'ZOMATO' };
  const capped = await send(p3, [extra]);
  assert.equal(capped.status, 429);
  assert.equal(capped.headers.get('retry-after'), '86400');
  assert.equal((await send(p1, [extra])).status, 202, 'another person is unaffected');
  await pool.query("INSERT INTO sms_v2_user_limits(profile_id,key,value,expires_at,updated_by,reason) VALUES($1,'signals_per_user_per_day',10,now()+interval '1 day',$2,'test override')", [p3, admin]);
  assert.equal((await send(p3, [extra])).status, 202);
  await pool.query('DELETE FROM sms_v2_user_limits WHERE profile_id = $1', [p3]);
  await pool.query("DELETE FROM sms_v2_settings WHERE key='signals_per_user_per_day'");

  // A backdated opt-out does not erase a current consent.
  await consent(p1, V3, false, "'2000-01-01'");
  assert.ok((await rows(p1)).length >= 1);

  // Revoking deletes that profile's signals and only theirs.
  await consent(p2, V3, false);
  assert.equal((await rows(p2)).length, 0);
  assert.ok((await rows(p1)).length >= 1);
  // Moving to another policy version also leaves nothing shared.
  await consent(p1, V2, true);
  assert.equal((await rows(p1)).length, 0);
  assert.equal((await send(p1, [swiggy])).status, 403);

  // Deleting the profile cascades.
  assert.equal((await rows(p3)).length, 4);
  await pool.query('DELETE FROM profiles WHERE id = $1', [p3]);
  assert.equal((await rows(p3)).length, 0);

  // The hourly job prunes rows older than signals_retention_days.
  await consent(p1, V3, true);
  assert.equal((await send(p1, [swiggy, extra])).status, 202);
  await pool.query("UPDATE sms_v2_learning_signals SET last_at = now() - interval '200 days' WHERE profile_id = $1 AND merchant_key = 'ZOMATO'", [p1]);
  const opened = await openRuleAdminStore({ env: { ADMIN_API_DATABASE_URL: adminUrl, DB_SSL: 'false', NODE_ENV: 'test' } });
  privatePool = opened.pool;
  const kp = crypto.generateKeyPairSync('ed25519');
  const signer = createSigner({ privateKeyPem: kp.privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId: 'signals-test' });
  const out = await runRuleJobs({ store: opened.store, signer, adminId: admin, now: new Date() });
  assert.equal(out.prunedSignals, 1);
  assert.deepEqual((await rows(p1)).map((row) => row.merchant_key), ['SWIGGY']);
  // A shorter retention setting prunes more.
  await pool.query("INSERT INTO sms_v2_settings(key,value,updated_by,reason) VALUES('signals_retention_days','30'::jsonb,$1,'shorter')", [admin]);
  await pool.query("UPDATE sms_v2_learning_signals SET last_at = now() - interval '40 days' WHERE profile_id = $1", [p1]);
  const again = await runRuleJobs({ store: opened.store, signer, adminId: admin, now: new Date() });
  assert.equal(again.prunedSignals, 1);
  assert.equal((await rows(p1)).length, 0);
});
