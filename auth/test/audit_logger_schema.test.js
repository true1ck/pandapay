'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

// These tests must never inherit an operator's real alert destination.
process.env.SECURITY_ALERT_WEBHOOK_URL = '';
process.env.SECURITY_ALERT_MIN_LEVEL = 'HIGH_RISK';

function load(query) {
  const filename = path.resolve(__dirname, '../src/services/auditLogger.js');
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = name => name === '../db' ? { query } : Module.prototype.require.call(loaded, name);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

test('security audit logger performs DML only and retains the existing event shape', async () => {
  const calls = [];
  const logger = load(async (sql, values) => { calls.push({ sql, values }); return { rows: [{ id: 'audit-id', created_at: new Date() }] }; });
  await logger.logAuthEvent({ action: 'login', status: 'success', riskLevel: 'INFO', meta: { reason: 'synthetic' } });
  assert.equal(calls.length, 1);
  assert.match(calls[0].sql, /INSERT INTO auth_audit/);
  assert.deepEqual(calls[0].values, [null, 'login', 'success', 'INFO', null, null, null, JSON.stringify({ reason: 'synthetic' })]);
  assert.equal(calls.some(row => /\b(ALTER|CREATE|DROP|DO)\b/.test(row.sql)), false);
});

test('missing audit schema/permission remains isolated with fixed sanitized error reporting', async () => {
  const original = console.error;
  const logs = [];
  console.error = (...args) => logs.push(args);
  try {
    for (const code of ['42703', '42P01', '42501']) {
      const calls = [];
      const logger = load(async sql => { calls.push(sql); throw Object.assign(new Error('private-token@example.test'), { code }); });
      await logger.logAuthEvent({ action: 'login', status: 'success' });
      assert.equal(calls.length, 1);
      assert.match(calls[0], /INSERT INTO auth_audit/);
    }
    assert.equal(logs.length, 3);
    assert.doesNotMatch(JSON.stringify(logs), /private-token|example\.test/);
  } finally { console.error = original; }
});

test('schema adoption is additive and never drops audit rows or rewrites risk values', () => {
  const sql = fs.readFileSync(path.resolve(__dirname, '../db/migrations/0008_auth_audit_risk_level.sql'), 'utf8');
  assert.match(sql, /ADD COLUMN IF NOT EXISTS risk_level/);
  assert.match(sql, /CREATE INDEX IF NOT EXISTS/);
  assert.match(sql, /REVOKE ALL ON TABLE public\.auth_audit FROM PUBLIC/);
  assert.doesNotMatch(sql, /\b(DELETE|DROP|TRUNCATE|UPDATE)\b/);
});
