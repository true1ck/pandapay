'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { openAiWorkerStore } = require('../../src/sms_v2/ai_worker_store');

const env = { SMS_AI_WORKER_DATABASE_URL: 'postgresql://fixture@localhost/test', DB_SSL: 'false', NODE_ENV: 'test' };

test('the AI worker needs its own database URL and never falls back to a public or admin one', async () => {
  await assert.rejects(
    openAiWorkerStore({ env: { DATABASE_URL: 'postgresql://postgres@localhost/test', ADMIN_API_DATABASE_URL: 'postgresql://x@localhost/test' } }),
    /SMS_AI_WORKER_DATABASE_URL is required/,
  );
});

test('the AI worker refuses any identity other than the plain sms_ai_worker role', async () => {
  for (const identity of [
    { name: 'app_user', unsafe: false },
    { name: 'admin_api_runtime', unsafe: false },
    { name: 'sms_ai_worker', unsafe: true },
  ]) {
    let closed = false;
    class FakePool {
      async query() { return { rows: [identity] }; }
      async end() { closed = true; }
    }
    await assert.rejects(openAiWorkerStore({ env, PoolClass: FakePool }), /Unsafe AI worker database identity/);
    assert.equal(closed, true);
  }
});

test('operations run in one transaction with timeouts, and roll back on error', async () => {
  const log = [];
  class FakePool {
    async query() { return { rows: [{ name: 'sms_ai_worker', unsafe: false }] }; }
    async connect() { return { query: async (sql) => { log.push(sql); return { rows: [] }; }, release() { log.push('release'); } }; }
    async end() {}
  }
  const { transaction } = await openAiWorkerStore({ env, PoolClass: FakePool });
  assert.equal(await transaction(async () => 'ok'), 'ok');
  assert.deepEqual(log.filter((x) => /BEGIN|COMMIT|ROLLBACK/.test(x)), ['BEGIN', 'COMMIT']);
  log.length = 0;
  await assert.rejects(transaction(async () => { throw new Error('boom'); }), /boom/);
  assert.deepEqual(log.filter((x) => /BEGIN|COMMIT|ROLLBACK/.test(x)), ['BEGIN', 'ROLLBACK']);
});
