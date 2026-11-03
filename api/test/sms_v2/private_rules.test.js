'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createAdminApiApp } = require('../../src/admin/app');
const { routeManifest } = require('../../src/admin/route_manifest');
const { registerPrivateRulesAdminRoutes } = require('../../src/sms_v2/rules_admin_route');
const { registerRules } = require('../../src/sms_v2/rules_route');
const { MemoryStore } = require('../../src/sms_v2/rules_store');
const express = require('express');

const policies = routeManifest.filter(row => row.path.startsWith('/admin/sms/v2/'));
const token = 'a'.repeat(43);

test('private SMS administration checks permission, fresh MFA and feature flag', async t => {
  const state = { permissions: ['learning.read', 'learning.publish'], enabled: true, mfa: new Date(), transactions: [] };
  const store = new MemoryStore();
  const app = createAdminApiApp({
    routeManifest: policies,
    introspectAdminSession: async () => ({ active: true, userId: 'actor', sessionId: 'session', assurance: 'email+webauthn-uv', mfaVerifiedAt: state.mfa, expiresAt: new Date(Date.now() + 60000) }),
    loadPermissions: async () => ({ active: true, userId: 'actor', role: 'owner', permissions: state.permissions }),
    withAdminClient: async (actor, permission, operation) => {
      state.transactions.push({ actor, permission });
      return operation({ query: async () => ({ rows: [{ key: 'sms_pipeline_v2_enabled', is_enabled: state.enabled, rollout_percent: 100 }] }) });
    },
    registerRoutes: api => registerPrivateRulesAdminRoutes(api, { store, signer: null }),
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const call = (method, path, headers = {}) => fetch(`http://127.0.0.1:${server.address().port}${path}`, {
    method, headers: { authorization: `Bearer ${token}`, ...headers },
  });
  assert.equal((await call('GET', '/admin/sms/v2/rules', { authorization: '' })).status, 401);
  assert.equal((await call('GET', '/admin/sms/v2/rules')).status, 200);
  assert.deepEqual(state.transactions[0], { actor: 'actor', permission: 'learning.read' });
  state.permissions = ['learning.read'];
  assert.equal((await call('PUT', '/admin/sms/v2/rules/R-1/draft')).status, 403);
  state.permissions.push('learning.publish');
  state.mfa = new Date(Date.now() - 6 * 60 * 1000);
  assert.equal((await call('POST', '/admin/sms/v2/rules/R-1/pause')).status, 403);
  state.enabled = false;
  assert.equal((await call('GET', '/admin/sms/v2/rules')).status, 404);
});

test('phone rule registration exposes no admin routes', async t => {
  const app = express();
  const pass = (_req, _res, next) => next();
  registerRules(app, { store: new MemoryStore(), signer: null, requireSmsV2: pass, requireMember: pass });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  assert.equal((await fetch(`http://127.0.0.1:${server.address().port}/admin/sms/v2/rules`)).status, 404);
});
