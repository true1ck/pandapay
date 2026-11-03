'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { openRuleAdminStore } = require('../../src/sms_v2/admin_store');

test('rule maintenance requires a dedicated private connection and rejects unsafe identities', async () => {
  await assert.rejects(openRuleAdminStore({ env: { DATABASE_URL: 'postgresql://postgres@localhost/test' } }), /ADMIN_API_DATABASE_URL is required/);
  for (const identity of [{ name: 'app_user', unsafe: false }, { name: 'admin_api_runtime', unsafe: true }]) {
    let closed = false;
    class FakePool {
      async query() { return { rows: [identity] }; }
      async end() { closed = true; }
    }
    await assert.rejects(openRuleAdminStore({
      env: { ADMIN_API_DATABASE_URL: 'postgresql://fixture@localhost/test', DB_SSL: 'false', NODE_ENV: 'test' },
      PoolClass: FakePool,
    }), /Unsafe private API database identity/);
    assert.equal(closed, true);
  }
});
