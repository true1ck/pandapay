'use strict';
// A fully migrated PostgreSQL rig for the learning loop's tests: profiles, one
// owner admin, the feature flag, a public API server (phones) and a private
// admin API server (console), with a fake App Check hook and no outside calls.
// Used by the template, merchant-suggestion, admin-control, end-to-end and
// security tests. Needs SMS_V2_TEST_DATABASE_URL and SMS_V2_TEST_ADMIN_DATABASE_URL.
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const crypto = require('node:crypto');
const express = require('express');
const { Pool } = require('pg');
const { createAdminApiApp } = require('../../../src/admin/app');
const { createAdminDbHelpers } = require('../../../src/admin/server');
const { routeManifest } = require('../../../src/admin/route_manifest');
const { registerSmsV2 } = require('../../../src/sms_v2');
const { createSigner } = require('../../../src/sms_v2/signer');
const { readPublicSettings, clearSettingsCache } = require('../../../src/sms_v2/settings');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;
const skip = !url || !adminUrl;
const V3 = 'sms-shared-learning-v3';

// Tables a test run may leave rows in. Cleared (not dropped) on close.
const LOOP_TABLES = [
  'sms_v2_learning_signals', 'sms_v2_learning_decisions', 'sms_v2_user_limits', 'sms_v2_settings',
  'sms_v2_unknown_templates', 'sms_v2_template_attempts', 'sms_v2_ai_capacity',
  'sms_v2_alias_drafts', 'sms_v2_category_drafts', 'sms_v2_merchant_suggestions',
  'sms_v2_rule_stats_profile_daily', 'sms_v2_rule_stats_daily', 'sms_v2_rule_cohorts', 'sms_v2_bundles', 'sms_v2_bundle_parts', 'sms_v2_rules',
];

async function startLoopHarness({ profileCount = 4, registerAdmin, adminPaths } = {}) {
  if (skip) throw new Error('SMS_V2_TEST_DATABASE_URL and SMS_V2_TEST_ADMIN_DATABASE_URL are required');
  const pool = new Pool({ connectionString: url });
  const privatePool = new Pool({ connectionString: adminUrl });
  const profiles = Array.from({ length: profileCount }, () => crypto.randomUUID());
  const admin = crypto.randomUUID();
  const priorFlag = (await pool.query("SELECT is_enabled,rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'")).rows[0];
  const keys = crypto.generateKeyPairSync('ed25519');
  const signer = createSigner({ privateKeyPem: keys.privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId: 'loop-harness' });
  const servers = [];
  clearSettingsCache();
  for (const table of LOOP_TABLES) await pool.query(`DELETE FROM ${table}`);
  for (const id of profiles) await pool.query('INSERT INTO profiles(id) VALUES($1)', [id]);
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')", [admin, `${admin}@example.invalid`]);
  await pool.query("INSERT INTO feature_flags(key,is_enabled,rollout_percent) VALUES('sms_pipeline_v2_enabled',true,100) ON CONFLICT(key) DO UPDATE SET is_enabled=true,rollout_percent=100");

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
  const helpers = createAdminDbHelpers(privatePool);
  const listen = async (app) => {
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    servers.push(server);
    return `http://127.0.0.1:${server.address().port}`;
  };

  // ---- phones: the public API, with the real settings reader and a fake App Check hook.
  const app = express();
  const requireMember = (req, res, next) => {
    req.userId = req.headers['x-test-user'];
    return req.userId ? next() : res.sendStatus(401);
  };
  const security = {
    verifyAttestation: async (req) => {
      req.smsV2Security = { sharedLearningEligible: req.headers['x-test-verified'] === '1', verified: req.headers['x-test-verified'] === '1' };
      return true;
    },
    checkRate: async () => true,
    storedSettings: async (req) => withUserClient(req.userId, (client) => readPublicSettings(client)),
  };
  registerSmsV2(app, {
    withUserClient, requireAuth: requireMember, requireMember,
    requireSmsV2: (_req, _res, next) => next(), signer: null, hooks: { security },
  });
  const publicUrl = await listen(app);

  // ---- console: the private admin API with the real route policy.
  let mfaFresh = true;
  const wanted = adminPaths || ((path) => path.startsWith('/admin/sms/v2/'));
  const adminApp = createAdminApiApp({
    routeManifest: routeManifest.filter((row) => wanted(row.path)),
    introspectAdminSession: async () => ({
      active: true, userId: admin, sessionId: 'loop-harness', assurance: 'email+webauthn-uv',
      mfaVerifiedAt: new Date(Date.now() - (mfaFresh ? 0 : 3600000)), expiresAt: new Date(Date.now() + 60000),
    }),
    ...helpers,
    registerRoutes: (api) => (registerAdmin || (() => {}))(api, { signer, now: () => new Date(), getGates: () => ({ m1: {} }) }),
  });
  const adminUrlBase = await listen(adminApp);

  const json = async (response) => {
    let body = null;
    try { body = await response.json(); } catch { body = null; }
    return { status: response.status, headers: response.headers, body };
  };
  const asUser = (profile, { verified = true } = {}) => {
    const headers = { 'content-type': 'application/json', 'x-test-user': profile, 'x-test-verified': verified ? '1' : '0' };
    return {
      get: (path) => fetch(`${publicUrl}${path}`, { headers }).then(json),
      post: (path, body) => fetch(`${publicUrl}${path}`, { method: 'POST', headers, body: JSON.stringify(body) }).then(json),
    };
  };
  const asAdmin = () => {
    const headers = { authorization: `Bearer ${'x'.repeat(43)}`, 'content-type': 'application/json' };
    const call = (method) => (path, body) => fetch(`${adminUrlBase}${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }).then(json);
    return { get: call('GET'), post: call('POST'), put: call('PUT'), del: call('DELETE') };
  };
  const consent = (profile, granted = true, version = V3) => pool.query(
    "INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at) VALUES($1,'sms_shared_learning',$2,$3,clock_timestamp())",
    [profile, version, granted]);

  async function close() {
    for (const server of servers) {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
    clearSettingsCache();
    await pool.query('DELETE FROM profiles WHERE id = ANY($1::uuid[])', [profiles]);
    for (const table of LOOP_TABLES) await pool.query(`DELETE FROM ${table}`);
    await pool.query('DELETE FROM admin_audit_log WHERE admin_id=$1', [admin]);
    await pool.query('DELETE FROM admin_users WHERE id=$1', [admin]);
    if (priorFlag) await pool.query("UPDATE feature_flags SET is_enabled=$1,rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'", [priorFlag.is_enabled, priorFlag.rollout_percent]);
    else await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
    await Promise.all([pool.end(), privatePool.end()]);
  }

  return {
    pool, privatePool, profiles, admin, signer, publicUrl, adminUrl: adminUrlBase,
    withUserClient, helpers, asUser, asAdmin, consent, close,
    setFreshMfa: (value) => { mfaFresh = value; },
  };
}

// Every private SMS v2 route family a learning-loop test may need.
function registerAllLoopAdminRoutes(api, deps) {
  const { registerPrivateRulesAdminRoutes } = require('../../../src/sms_v2/rules_admin_route');
  registerPrivateRulesAdminRoutes(api, deps);
  require('../../../src/sms_v2/corrections_route').registerPrivateCorrections(api);
  require('../../../src/sms_v2/ai_templates').registerPrivateTemplateRoutes(api);
  const category = require('../../../src/sms_v2/category_admin_route');
  category.registerPrivateCategoryRoutes(api, deps);
  category.registerPrivateAliasRoutes(api, deps);
  require('../../../src/sms_v2/settings_admin_route').registerPrivateSettingsRoutes(api);
  require('../../../src/sms_v2/learning_admin_route').registerPrivateLearningRoutes(api);
  for (const optional of ['merchant_suggestions', 'learning_audit_route']) {
    try {
      const mod = require(`../../../src/sms_v2/${optional}`);
      if (typeof mod.registerPrivateSuggestionRoutes === 'function') mod.registerPrivateSuggestionRoutes(api);
      if (typeof mod.registerPrivateAuditRoutes === 'function') mod.registerPrivateAuditRoutes(api);
    } catch (error) {
      if (error.code !== 'MODULE_NOT_FOUND') throw error;
    }
  }
}

module.exports = { startLoopHarness, registerAllLoopAdminRoutes, skip, V3, LOOP_TABLES };
