'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { resolveDatabaseTls } = require('../src/db_tls');
const { safeErrorCode } = require('../src/safeErrorCode');

function startFixture(overrides = {}) {
  const env = { NODE_ENV: 'production', SMS_LEARNING_DATABASE_URL: 'postgresql://worker:synthetic@db.example.invalid/product?sslmode=require',
    SMS_LEARNING_HMAC_KEY: 'synthetic-hmac-key-at-least-32-bytes', ...overrides };
  const state = { logs: [], handlers: {} };
  class Pool {
    constructor(options) { state.options = options; }
    on(event, handler) { state.handlers[event] = handler; }
  }
  const context = {
    require(name) {
      if (name === 'dotenv') return { config() {} };
      if (name === 'pg') return { Pool };
      if (name === './db_tls') return { resolveDatabaseTls };
      if (name === './safeErrorCode') return { safeErrorCode };
      if (name === './sms_autonomous_worker') return {
        DEFAULT_SMS_LEARNING_WORKER_ROLE: 'sms_learning_worker',
        startAutonomousWorker() { state.started = true; return { stop() {} }; },
      };
      throw new Error('Unexpected fixture dependency');
    },
    process: { env, once() {}, exit(code) { state.exitCode = code; throw new Error('fixture_exit'); } },
    console: { error(...args) { state.logs.push(args); } },
  };
  const source = fs.readFileSync(path.join(__dirname, '../src/sms_learning_worker_runner.js'), 'utf8');
  try { vm.runInNewContext(source, context); }
  catch (error) { if (error.message !== 'fixture_exit') throw error; }
  return state;
}

test('SMS worker uses verified TLS and removes conflicting URL TLS options', () => {
  const state = startFixture();
  assert.equal(state.started, true);
  assert.equal(state.options.ssl.rejectUnauthorized, true);
  assert.ok(state.options.ssl.ca.length > 0);
  assert.equal(new URL(state.options.connectionString).searchParams.has('sslmode'), false);
  assert.equal(state.options.max, 2);
});

test('SMS worker rejects hosted plaintext configuration without printing URL or secrets', () => {
  const state = startFixture({ DB_SSL: 'false' });
  assert.equal(state.exitCode, 1);
  assert.equal(state.started, undefined);
  assert.doesNotMatch(JSON.stringify(state.logs), /synthetic|example\.invalid|postgresql:/);
});

test('SMS worker idle pool errors log only bounded classification', () => {
  const state = startFixture();
  state.handlers.error(Object.assign(new Error('private-contact@example.invalid secret-password'), { code: '08006' }));
  assert.doesNotMatch(JSON.stringify(state.logs), /private-contact|secret-password/);
  assert.equal(state.logs[0][1], '08006');
});

test('autonomous worker records and logs a classification without exception contents', async t => {
  const { startAutonomousWorker, stopAutonomousWorker } = require('../src/sms_autonomous_worker');
  const stored = [];
  const logs = [];
  t.mock.method(console, 'warn', (...args) => logs.push(args));
  let released = false;
  const client = { async query(sql, params) {
    if (sql.includes('current_user AS role')) {
      throw Object.assign(new Error('private-contact@example.invalid secret-password'), { code: 'XX000' });
    }
    if (sql.includes('INSERT INTO public.sms_learning_worker_runs')) stored.push(params);
    return { rows: [] };
  }, release() { released = true; } };
  startAutonomousWorker({ async connect() { return client; } }, { runImmediately: true, maxRetries: 1, intervalMs: 60000 });
  t.after(stopAutonomousWorker);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(released, true);
  assert.equal(stored.length, 1);
  assert.equal(JSON.parse(stored[0][2]).reason, 'XX000');
  assert.doesNotMatch(JSON.stringify({ stored, logs }), /private-contact|secret-password/);
});
