'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  checkAuthReadiness,
  createReadinessHandler,
  requiresPostgresAbuseStorage,
} = require('../src/services/authReadiness');

const fullAccess = {
  schema_usage: true,
  can_select: true,
  can_insert: true,
  can_update: true,
  can_delete: true,
};

test('hosted readiness checks database and runtime abuse storage without writes', async () => {
  const statements = [];
  const status = await checkAuthReadiness(async sql => {
    statements.push(sql);
    if (sql.includes('has_schema_privilege')) return { rows: [fullAccess] };
    return { rows: [] };
  }, { env: { NODE_ENV: 'production' } });
  assert.deepEqual(status, { ok: true, database: 'ready' });
  assert.equal(statements[0], 'SELECT 1');
  assert.equal(statements.some(sql => sql.includes('LIMIT 0')), true);
  assert.equal(statements.every(sql => !/^\s*(INSERT|UPDATE|DELETE)\b/i.test(sql)), true);
  assert.equal(requiresPostgresAbuseStorage({ NODE_ENV: 'staging' }), true);
  assert.equal(requiresPostgresAbuseStorage({ NODE_ENV: 'test', AUTH_ABUSE_STORE: 'postgres' }), true);
  assert.equal(requiresPostgresAbuseStorage({ NODE_ENV: 'development' }), false);
});

test('local memory mode checks ordinary database connectivity only', async () => {
  const statements = [];
  await checkAuthReadiness(async sql => { statements.push(sql); return { rows: [] }; }, {
    env: { NODE_ENV: 'development', AUTH_ABUSE_STORE: 'memory' },
  });
  assert.deepEqual(statements, ['SELECT 1']);
});

test('hosted readiness returns safe 503 when bucket privileges or table query fail', async () => {
  for (const query of [
    async sql => sql === 'SELECT 1' ? { rows: [] } : { rows: [{ ...fullAccess, can_update: false }] },
    async sql => {
      if (sql.includes('has_schema_privilege')) return { rows: [fullAccess] };
      throw Object.assign(new Error('sensitive SQL and connection detail'), { code: '42P01' });
    },
  ]) {
    let statusCode;
    let body;
    const logs = [];
    const handler = createReadinessHandler({
      query,
      env: { NODE_ENV: 'staging' },
      logger: { error: (...args) => logs.push(args) },
    });
    await handler({}, {
      json(value) { body = value; return value; },
      status(value) { statusCode = value; return this; },
    });
    assert.equal(statusCode, 503);
    assert.deepEqual(body, { ok: false, database: 'unavailable' });
    assert.equal(JSON.stringify(logs).includes('sensitive SQL'), false);
  }
});
