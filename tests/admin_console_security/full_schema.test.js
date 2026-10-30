'use strict';

// Real checked-in schema rehearsal in the disposable socket-only cluster.
// Never accepts DATABASE_URL, hosted URLs, or a pre-existing application DB.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { Client, Pool } = require('../../auth/node_modules/pg');
const { runMigrations } = require('../../auth/scripts/migrate');
const { runProductMigrations } = require('../../db/scripts/product_migrate');
const { configureAdminApiRuntime } = require('../../db/scripts/admin_permissions');
const { createAdminDbHelpers } = require('../../api/src/admin/server');
const { createAdminApiApp } = require('../../api/src/admin/app');
const { registerAdminRoutes } = require('../../api/src/admin/routes');

const socket = process.env.ADMIN_TEST_PG_SOCKET;
const enabled = typeof socket === 'string' && /^\/tmp\/pandapay-admin-pg\.[A-Za-z0-9]+$/.test(socket);
test('private admin migrations coexist with the complete clean application schemas', { skip: !enabled }, async t => {
  const connection = { host: socket, port: 55487, user: 'postgres' };
  const control = new Client({ ...connection, database: 'postgres' });
  await control.connect();
  const authName = 'private_admin_full_auth_test';
  const productName = 'private_admin_full_product_test';
  await control.query(`CREATE DATABASE ${authName}`);
  await control.query(`CREATE DATABASE ${productName}`);
  const auth = new Pool({ ...connection, database: authName, max: 1 });
  const product = new Client({ ...connection, database: productName });
  await product.connect();
  let runtime;
  t.after(async () => {
    await Promise.allSettled([runtime?.end(), auth.end(), product.end()]);
    await control.query(`DROP DATABASE ${authName} WITH (FORCE)`);
    await control.query(`DROP DATABASE ${productName} WITH (FORCE)`);
    await control.end();
  });
  const testEnv = {
    NODE_ENV: 'test', ENCRYPTION_ENABLED: 'false',
    PHONE_LOOKUP_HMAC_KEY: crypto.randomBytes(32).toString('hex'),
    ADMIN_GATEWAY_DB_PASSWORD: crypto.randomBytes(32).toString('hex'),
  };
  await runMigrations(auth, { env: testEnv });
  await runMigrations(auth, { env: testEnv });
  const setup = () => execFileSync('psql', [
    '-h', socket, '-p', '55487', '-U', 'postgres', '-d', productName,
    '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', path.resolve(__dirname, '../../db/setup_app_role.sql'),
  ], { env: { ...process.env, APP_USER_PASSWORD: crypto.randomBytes(32).toString('hex'), REWARD_WORKER_DB_PASSWORD: crypto.randomBytes(32).toString('hex') }, stdio: 'pipe' });
  await runProductMigrations(product, { runRoleSetup: setup });
  await runProductMigrations(product, { runRoleSetup: setup });
  await configureAdminApiRuntime(product, { ADMIN_API_DB_PASSWORD: crypto.randomBytes(32).toString('hex') });
  execFileSync('psql', [
    '-h', socket, '-p', '55487', '-U', 'postgres', '-d', productName,
    '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', path.resolve(__dirname, '../../db/tests/20261021143000_referral_operator_controls_test.sql'),
  ], { stdio: 'pipe' });
  const actor = crypto.randomUUID();
  let currentActor = actor;
  await product.query("INSERT INTO admin_users(id,email,role) VALUES($1,'schema-owner@example.test','owner')", [actor]);
  runtime = new Pool({ ...connection, user: 'admin_api_runtime', database: productName, max: 2 });
  const helpers = createAdminDbHelpers(runtime);
  assert.equal((await helpers.loadPermissions({ userId: actor })).role, 'owner');
  let lastError;
  const app = createAdminApiApp({
    introspectAdminSession: async () => ({ active: true, userId: currentActor, sessionId: crypto.randomUUID(), assurance: 'email+webauthn-uv', mfaVerifiedAt: new Date(), expiresAt: new Date(Date.now() + 60000) }),
    loadPermissions: helpers.loadPermissions,
    withAdminClient: async (...args) => {
      try { return await helpers.withAdminClient(...args); }
      catch (error) { lastError = error.message; throw error; }
    },
    registerRoutes: registerAdminRoutes,
  });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const failures = [];
  for (const route of app.locals.adminRouteManifest.filter(r => r.method === 'GET')) {
    lastError = null;
    const url = route.path.replace(':bundleVersion', '1').replace(/:[A-Za-z][A-Za-z0-9_]*/g, crypto.randomUUID()) + '?network=visa&rail=swipe&periodMonth=2026-10-01';
    const response = await fetch(`http://127.0.0.1:${server.address().port}${url}`, { headers: { authorization: `Bearer ${'x'.repeat(43)}` } });
    if (![200, 404].includes(response.status)) failures.push(`${route.path}: ${response.status} ${await response.text()} ${lastError || ''}`);
  }
  assert.deepEqual(failures, []);
  async function mutation(method, route, body, status) {
    lastError = null;
    const response = await fetch(`http://127.0.0.1:${server.address().port}${route}`, {
      method, headers: { authorization: `Bearer ${'x'.repeat(43)}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    const result = await response.json();
    assert.equal(response.status, status, `${route}: ${JSON.stringify(result)} ${lastError || ''}`);
    return result;
  }
  const { issuer } = await mutation('POST', '/admin/issuers', { slug: 'private-test-bank', name: 'Private Test Bank', reason: 'Synthetic private integration' }, 201);
  const { card } = await mutation('POST', '/admin/cards', { issuerId: issuer.id, slug: 'private-test-card', name: 'Private Test Card', network: 'visa', reason: 'Synthetic private integration' }, 201);
  await mutation('PUT', `/admin/forex-rules/by-card/${card.id}`, { markupPercent: 2, reason: 'Synthetic private integration' }, 200);
  await mutation('POST', `/admin/cards/${card.id}/status`, { status: 'in_review', reason: 'Synthetic private review' }, 200);
  await mutation('POST', `/admin/cards/${card.id}/status`, { status: 'published', reason: 'Synthetic private approval' }, 200);
  const reader = crypto.randomUUID();
  await product.query("INSERT INTO admin_users(id,email,role) VALUES($1,'schema-reader@example.test','readonly')", [reader]);
  currentActor = reader;
  await mutation('POST', '/admin/issuers', { slug: 'denied-bank', name: 'Denied' }, 403);
  await mutation('POST', `/admin/cards/${card.id}/status`, { status: 'archived', reason: 'Denied' }, 403);
  const operator = crypto.randomUUID(), profile = crypto.randomUUID(), ticket = crypto.randomUUID();
  await product.query("INSERT INTO admin_users(id,email,role) VALUES($1,'schema-operator@example.test','operator')", [operator]);
  await product.query("INSERT INTO profiles(id,email,display_name) VALUES($1,'customer@example.test','Synthetic customer')", [profile]);
  await product.query("INSERT INTO support_tickets(id,profile_id,kind,message) VALUES($1,$2,'general','Synthetic support request')", [ticket, profile]);
  currentActor = operator;
  await mutation('POST', `/admin/support-tickets/${ticket}/resolve`, { response: 'Synthetic resolution', reason: 'Synthetic private integration' }, 200);
  assert.equal((await product.query('SELECT state FROM support_tickets WHERE id=$1', [ticket])).rows[0].state, 'resolved');
  assert.equal((await product.query("SELECT count(*)::int AS n FROM admin_audit_log WHERE admin_id=$1 AND action='resolve_support_ticket'", [operator])).rows[0].n, 1);
  await mutation('POST', `/admin/cards/${card.id}/status`, { status: 'archived', reason: 'Denied' }, 403);
  currentActor = actor;
  await mutation('POST', '/admin/notifications/broadcast', { title: 'Synthetic notification, no provider delivery' }, 503);
  const customer = new Client({ ...connection, database: productName, user: 'app_user' });
  await customer.connect();
  try {
    await customer.query("SELECT set_config('pandapay.admin_actor',$1,false)", [actor]);
    assert.equal((await customer.query('SELECT pandapay.is_admin() AS allowed')).rows[0].allowed, false);
    assert.equal((await customer.query('SELECT * FROM admin_role_permissions')).rowCount, 0);
    await assert.rejects(customer.query('SET ROLE pandapay_admin_api'), /permission denied/);
  } finally { await customer.end(); }
});
