'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createAdminApiApp } = require('../../src/admin/app');
const { createAdminDbHelpers } = require('../../src/admin/server');
const { registerPrivateAliasRoutes } = require('../../src/sms_v2/category_admin_route');
const { createSigner, verifyBundle } = require('../../src/sms_v2/signer');
const { createPgStore } = require('../../src/sms_v2/rules_store');
const { importBundle } = require('../../src/sms_v2/rules_admin_route');
const { routeManifest } = require('../../src/admin/route_manifest');
const full = require('../../../contracts/sms/v2/fixtures/valid/bundle/full.json');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;

test('shop names publish through the four cohorts on a fully migrated Postgres', { skip: !url || !adminUrl }, async (t) => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const privatePool = new Pool({ connectionString: adminUrl });
  const actor = crypto.randomUUID();
  const id = crypto.randomUUID();
  const rival = crypto.randomUUID();
  let server;
  const priorFlag = (await pool.query("SELECT is_enabled,rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'")).rows[0];
  const tables = ['sms_v2_rule_cohorts', 'sms_v2_bundles', 'sms_v2_bundle_parts', 'sms_v2_rules'];
  t.after(async () => {
    if (server) { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); }
    await pool.query('DELETE FROM sms_v2_alias_drafts WHERE draft_id = ANY($1::uuid[])', [[id, rival]]);
    for (const table of tables) await pool.query(`DELETE FROM ${table}`);
    await pool.query('DELETE FROM admin_audit_log WHERE admin_id=$1', [actor]);
    await pool.query('DELETE FROM admin_users WHERE id=$1', [actor]);
    if (priorFlag) await pool.query("UPDATE feature_flags SET is_enabled=$1,rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'", [priorFlag.is_enabled, priorFlag.rollout_percent]);
    else await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
    await Promise.all([pool.end(), privatePool.end()]);
  });
  for (const table of tables) await pool.query(`DELETE FROM ${table}`);
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')", [actor, `${actor}@example.invalid`]);
  await pool.query("INSERT INTO feature_flags(key,is_enabled,rollout_percent) VALUES('sms_pipeline_v2_enabled',true,100) ON CONFLICT(key) DO UPDATE SET is_enabled=true,rollout_percent=100");
  const helpers = createAdminDbHelpers(privatePool);
  const now = new Date('2026-11-04T12:00:00Z');
  const kp = crypto.generateKeyPairSync('ed25519');
  const signer = createSigner({ privateKeyPem: kp.privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId: 'alias-pg' });
  const store = createPgStore({ withUserClient: (admin, fn) => helpers.withAdminClient(admin, 'learning.publish', fn) });
  await store.tx(actor, (s) => importBundle(s, full, { signer, adminId: actor, now }));
  let fresh = true;
  const app = createAdminApiApp({
    routeManifest: routeManifest.filter((row) => row.path.startsWith('/admin/sms/v2/merchant-aliases')),
    introspectAdminSession: async () => ({
      active: true, userId: actor, sessionId: 'alias-fixture', assurance: 'email+webauthn-uv',
      mfaVerifiedAt: new Date(Date.now() - (fresh ? 0 : 3600000)), expiresAt: new Date(Date.now() + 60000),
    }),
    loadPermissions: helpers.loadPermissions,
    withAdminClient: helpers.withAdminClient,
    registerRoutes: (api) => registerPrivateAliasRoutes(api, { signer, now: () => now, getGates: () => ({ m1: {} }) }),
  });
  server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const call = async (method, path, body) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/admin/sms/v2${path}`, {
      method, headers: { authorization: `Bearer ${'x'.repeat(43)}`, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  };
  const body = { alias: 'PAYU SWIGGY', merchantKey: 'SWIGGY', kind: 'learned' };

  fresh = false;
  assert.equal((await call('PUT', `/merchant-aliases/${id}/draft`, body)).status, 403, 'a draft needs fresh MFA');
  fresh = true;
  assert.equal((await call('PUT', '/merchant-aliases/not-a-uuid/draft', body)).body.error, 'alias_id_invalid');
  for (const [bad, code] of [
    [{ ...body, alias: 'SWIGGY' }, 'alias_equals_key'],
    [{ ...body, alias: 'PAYTMQR2810050501' }, 'alias_key_invalid'],
    [{ ...body, merchantKey: 'SWIGGY 20261106' }, 'alias_key_invalid'],
  ]) {
    const refused = await call('PUT', `/merchant-aliases/${id}/draft`, bad);
    assert.equal(refused.status, 422, JSON.stringify(refused.body));
    assert.equal(refused.body.error, code);
  }
  const saved = await call('PUT', `/merchant-aliases/${id}/draft`, body);
  assert.equal(saved.status, 200, JSON.stringify(saved.body));
  assert.equal(saved.body.revision, 1);
  // Direct writes with read-only authority are refused by row-level security.
  await helpers.withAdminClient(actor, 'learning.read', async (client) => {
    const updated = await client.query("UPDATE sms_v2_alias_drafts SET status='published' WHERE draft_id=$1", [id]);
    assert.equal(updated.rowCount, 0);
  });

  const result = await call('GET', `/merchant-aliases/${id}/candidate?revision=1`);
  assert.equal(result.status, 200, JSON.stringify(result.body));
  assert.equal(result.body.candidates.length, 4);
  assert.equal((await call('GET', `/merchant-aliases/${id}/candidate`)).body.error, 'alias_revision_invalid');
  const reports = Object.fromEntries(result.body.candidates.map((candidate) => [candidate.cohort, { bundleSha256: candidate.contentSha256, counts: { cases: 1, casesPassed: 1 }, metrics: {} }]));
  const stale = structuredClone(reports);
  stale.testers.bundleSha256 = '0'.repeat(64);
  assert.equal((await call('POST', `/merchant-aliases/${id}/publish`, { revision: 1, reason: 'review', goldenReports: stale })).status, 422);
  assert.equal((await store.tx(actor, (s) => s.aliasDraft(id))).status, 'draft');
  assert.equal((await call('POST', `/merchant-aliases/${id}/publish`, { revision: 1, reason: 'x', goldenReports: { testers: reports.testers } })).status, 400);

  const published = await call('POST', `/merchant-aliases/${id}/publish`, { revision: 1, reason: 'Three people renamed it', goldenReports: reports });
  assert.equal(published.status, 200, JSON.stringify(published.body));
  assert.equal(published.body.bundles.length, 4);
  for (const cohort of ['testers', 'pct5', 'pct25', 'all']) {
    const row = await store.tx(actor, (s) => s.latestBundle(cohort));
    assert.ok(row.body.merchantAliases.some((entry) => entry.alias === 'PAYU SWIGGY' && entry.merchantKey === 'SWIGGY' && entry.kind === 'learned'), cohort);
    assert.ok(verifyBundle({ ...row.body, signature: { alg: 'Ed25519', keyId: row.keyId, value: row.signature } }, signer.publicKeyPem));
    assert.deepEqual(row.goldenReport, reports[cohort]);
  }
  assert.equal((await store.tx(actor, (s) => s.aliasDraft(id))).status, 'published');

  // A second draft for the same alias with a different key is a conflict (409).
  const conflict = await call('PUT', `/merchant-aliases/${rival}/draft`, { ...body, merchantKey: 'ZOMATO' });
  assert.equal(conflict.status, 409);
  assert.equal(conflict.body.error, 'alias_conflict');

  const audits = (await pool.query("SELECT action, entity, reason FROM admin_audit_log WHERE admin_id=$1 AND action LIKE 'sms_v2_alias_%' ORDER BY id", [actor])).rows;
  assert.deepEqual(audits.map((row) => row.action), ['sms_v2_alias_draft', 'sms_v2_alias_publish']);
  assert.equal(audits[1].reason, 'Three people renamed it');
  assert.ok(audits.every((row) => row.entity === 'sms_v2_merchant_alias'));
});
