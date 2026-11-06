'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');

// Poolers such as Supabase's ignore the connection-startup `options` setting, so the gateway must also assume its
// capability role itself on every new connection; otherwise it cannot read admin_private and never becomes ready.
test('private admin gateway assumes its capability role on each new database connection', async () => {
  const created = [];
  class FakePool {
    constructor(options) { this.options = options; this.handlers = {}; created.push(this); }
    on(event, handler) { this.handlers[event] = handler; return this; }
    async query() { return { rows: [{ name: 'someone_else', unsafe: false }] }; }
    async end() {}
  }
  const realLoad = Module._load;
  Module._load = function patchedLoad(request, ...rest) {
    return request === 'pg' ? { Pool: FakePool } : realLoad.call(this, request, ...rest);
  };
  try {
    const { createAdminGatewayRuntime } = require('../src/admin/server');
    const env = {
      ADMIN_GATEWAY_ENABLED: 'true',
      ADMIN_BROWSER_ORIGIN: 'https://localhost:8443',
      ADMIN_WEBAUTHN_RP_ID: 'localhost',
      ADMIN_AUTH_DATABASE_URL: 'postgres://admin_gateway_runtime:x@localhost:5432/auth_test',
    };
    // The fake identity is wrong on purpose, so start-up stops after the pool is built.
    await assert.rejects(createAdminGatewayRuntime({ env, routeManifest: [{}] }), /Unsafe private gateway database identity/);
    assert.equal(created.length, 1);
    assert.equal(created[0].options.options, '-c role=pandapay_admin_gateway');
    assert.equal(typeof created[0].handlers.connect, 'function', 'a connect handler must be registered');

    const statements = [];
    created[0].handlers.connect({ query(sql) { statements.push(sql); return Promise.resolve(); } });
    assert.deepEqual(statements, ['SET ROLE pandapay_admin_gateway']);

    // A failing SET ROLE must not crash the process: queries then fail closed with permission errors.
    assert.doesNotThrow(() => created[0].handlers.connect({ query() { return Promise.reject(new Error('denied')); } }));
  } finally {
    Module._load = realLoad;
  }
});
