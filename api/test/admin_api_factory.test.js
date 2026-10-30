'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createAdminApiApp } = require('../src/admin/app');

const manifest = Object.freeze([
  { method: 'GET', path: '/admin/test', permission: 'test.read', freshMfa: false },
  { method: 'POST', path: '/admin/publish', permission: 'test.publish', freshMfa: true },
]);
const token = 'a'.repeat(43);

test('public product ingress denies administrative variants before any handler', async () => {
  const express=require('express');
  const {denyPublicAdmin}=require('../src/public_admin_boundary');
  const app=express();app.use(denyPublicAdmin);app.use((_req,res)=>res.json({customer:true}));
  await withServer(app,async origin=>{
    for(const path of ['/admin/me','/ADMIN/me','/%61dmin/me','//browser/login/start','/internal/admin/session/introspect']) {
      assert.equal((await fetch(origin+path)).status,404);
    }
    assert.equal((await fetch(origin+'/catalogue')).status,200);
  });
});

function makeApp(overrides = {}) {
  const state = {
    session: { active: true, userId: 'actor-1', sessionId: 'session-1', assurance: 'email+webauthn-uv', mfaVerifiedAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 60_000).toISOString() },
    permissions: ['test.read', 'test.publish'],
    calls: [],
  };
  const deps = {
    routeManifest: manifest,
    introspectAdminSession: async value => { state.calls.push(['introspect', value]); return state.session; },
    loadPermissions: async actor => ({ active: true, userId: actor.userId, role: 'owner', permissions: state.permissions, version: 4 }),
    withAdminClient: async (actorId, permission, operation) => operation({ query: async () => ({ rows: [{ actor: actorId, permission }] }) }),
    registerRoutes: api => {
      api.route('GET', '/admin/test', async (_req, res, ctx) => {
        const result = await ctx.withAdminClient(client => client.query('select 1'));
        res.json(result.rows[0]);
      });
      api.route('POST', '/admin/publish', async (_req, res) => res.json({ published: true }));
    },
    ...overrides,
  };
  return { app: createAdminApiApp(deps), state };
}

async function withServer(app, callback) {
  const server = app.listen(0);
  await new Promise(resolve => server.once('listening', resolve));
  try { return await callback(`http://127.0.0.1:${server.address().port}`); }
  finally { await new Promise(resolve => server.close(resolve)); }
}

test('factory fails closed when a required security dependency is absent or routes are unclassified', () => {
  assert.throws(() => createAdminApiApp({}), /introspectAdminSession/);
  assert.throws(() => createAdminApiApp({
    introspectAdminSession: async () => ({}), loadPermissions: async () => ({}),
    withAdminClient: async () => {}, routeManifest: manifest,
    registerRoutes(api) { api.route('GET', '/admin/unknown', () => {}); },
  }), /missing explicit admin policy/);
  assert.throws(() => createAdminApiApp({
    introspectAdminSession: async () => ({}), loadPermissions: async () => ({}),
    withAdminClient: async () => {}, routeManifest: manifest,
    registerRoutes() {},
  }), /handlers missing manifest entries/);
});

test('only gateway opaque bearer introspection creates an admin actor; permission is rechecked', async () => {
  const { app, state } = makeApp();
  await withServer(app, async origin => {
    const noToken = await fetch(`${origin}/admin/test`);
    assert.equal(noToken.status, 401);
    const customerJwt = await fetch(`${origin}/admin/test`, { headers: { authorization: 'Bearer eyJhbGciOiJIUzI1NiJ9.' + 'x'.repeat(60) } });
    assert.equal(customerJwt.status, 401);
    const allowed = await fetch(`${origin}/admin/test`, { headers: { authorization: `Bearer ${token}` } });
    assert.equal(allowed.status, 200);
    assert.deepEqual(await allowed.json(), { actor: 'actor-1', permission: 'test.read' });
    assert.equal(state.calls.filter(x => x[0] === 'introspect').length, 1);
    state.permissions = [];
    const denied = await fetch(`${origin}/admin/test`, { headers: { authorization: `Bearer ${token}` } });
    assert.equal(denied.status, 403);
  });
});

test('sensitive routes require fresh MFA and client work receives verified actor and permission', async () => {
  const { app, state } = makeApp();
  await withServer(app, async origin => {
    state.session.mfaVerifiedAt = new Date(Date.now() - 6 * 60_000).toISOString();
    const denied = await fetch(`${origin}/admin/publish`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: '{}' });
    assert.equal(denied.status, 403);
    assert.deepEqual(await denied.json(), { error: 'fresh_mfa_required' });
    state.session.mfaVerifiedAt = new Date().toISOString();
    const allowed = await fetch(`${origin}/admin/publish`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: '{}' });
    assert.equal(allowed.status, 200);
  });
});

test('introspection dependency failure denies with bounded 503 and no-store', async () => {
  const { app } = makeApp({ introspectAdminSession: async () => { throw new Error('secret must not leak'); } });
  await withServer(app, async origin => {
    const response = await fetch(`${origin}/admin/test`, { headers: { authorization: `Bearer ${token}` } });
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal((await response.text()).includes('secret'), false);
  });
});

test('private introspection transport bounds streamed replies and rejects invalid JSON', async () => {
  const { createIntrospectionClient } = require('../src/admin/server');
  const make = body => createIntrospectionClient({
    url: 'http://127.0.0.1:4321/internal/admin/session/introspect',
    serviceSecret: 's'.repeat(32),
    fetchImpl: async (_url, options) => {
      assert.equal(options.redirect, 'error');
      assert.equal(options.headers['x-admin-service-secret'], 's'.repeat(32));
      return new Response(body);
    },
  });
  assert.deepEqual(await make('{"active":false}')(token), { active: false });
  await assert.rejects(make('x'.repeat(4097))(token), /response_too_large/);
  await assert.rejects(make('not-json')(token), /invalid_admin_introspection_response/);
});
