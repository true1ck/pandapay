'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const dbErrors = require('../src/http_db_errors');

const source = fs.readFileSync(require.resolve('../src/index'), 'utf8').replace(/\r\n/g, '\n');
const UUID = '40000000-0000-4000-8000-000000000001';

function fakeResponse() {
  return {
    code: 200,
    headers: {},
    status(code) { this.code = code; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    json(body) { this.body = JSON.parse(JSON.stringify(body)); return this; },
  };
}

test('classifyDbError maps the PostgreSQL codes to fixed, non-leaking responses', () => {
  const cases = [
    ['22P02', 400, 'invalid_id', false],
    ['23503', 409, 'reference_conflict', false],
    ['23514', 422, 'data_rule_violation', false],
    ['23505', 409, 'duplicate', false],
    ['57014', 503, 'transient_db_error', true],
    ['40001', 503, 'transient_db_error', true],
    ['40P01', 503, 'transient_db_error', true],
  ];
  for (const [code, status, error, retryable] of cases) {
    const mapped = dbErrors.classifyDbError(Object.assign(new Error('private customer@example.invalid'), { code, detail: 'private detail' }));
    assert.equal(mapped.status, status, code);
    assert.equal(mapped.body.error, error, code);
    assert.equal(mapped.body.retryable === true, retryable, code);
    assert.equal(JSON.stringify(mapped.body).includes('private'), false);
  }
  assert.equal(dbErrors.classifyDbError(new Error('boom')), null);
  assert.equal(dbErrors.classifyDbError(Object.assign(new Error('x'), { code: '42501' })), null);
  assert.equal(dbErrors.classifyDbError(null), null);
});

test('isTransientDbError recognises timeout, serialization failure and deadlock only', () => {
  for (const code of ['57014', '40001', '40P01']) assert.equal(dbErrors.isTransientDbError({ code }), true);
  for (const code of ['23505', '22P02', '42501', undefined]) assert.equal(dbErrors.isTransientDbError({ code }), false);
  assert.equal(dbErrors.isTransientDbError(undefined), false);
});

test('respondDbError answers mapped errors and leaves unmapped ones to the caller', () => {
  const res = fakeResponse();
  assert.equal(dbErrors.respondDbError(res, Object.assign(new Error('x'), { code: '40P01' })), true);
  assert.equal(res.code, 503);
  assert.deepEqual(res.body, { error: 'transient_db_error', retryable: true });
  assert.equal(res.headers['Retry-After'], '1');
  const untouched = fakeResponse();
  assert.equal(dbErrors.respondDbError(untouched, new Error('boom')), false);
  assert.equal(untouched.body, undefined);
});

test('uuid guard accepts UUIDs only and rejectInvalidUuid answers 400 invalid_id', () => {
  assert.equal(dbErrors.isUuid(UUID), true);
  for (const bad of ['v2:abc', 'projection:x', '', null, undefined, 7, [UUID], {}]) assert.equal(dbErrors.isUuid(bad), false);
  const res = fakeResponse();
  assert.equal(dbErrors.rejectInvalidUuid(res, 'v2:abc'), true);
  assert.equal(res.code, 400);
  assert.deepEqual(res.body, { error: 'invalid_id' });
  const ok = fakeResponse();
  assert.equal(dbErrors.rejectInvalidUuid(ok, UUID), false);
  assert.equal(ok.body, undefined);
});

// Run the real route registrations from index.js without booting it.
function routeFixture(begin, end, method, url) {
  const start = source.indexOf(begin);
  const stop = source.indexOf(end, start + begin.length);
  assert.ok(start >= 0 && stop > start, `route block ${begin}`);
  const routes = new Map();
  const calls = [];
  const context = {
    ...dbErrors,
    console: { error() {} },
    safeErrorCode: () => 'safe_code',
    requireAuth() {},
    withUserClient: async (_id, callback) => callback({ query: async (sql, args) => { calls.push({ sql, args }); return { rows: [{ id: UUID }], rowCount: 1 }; } }),
    app: Object.fromEntries(['post', 'get', 'patch', 'delete', 'put'].map((m) => [m, (path, _auth, handler) => routes.set(`${m} ${path}`, handler)])),
  };
  vm.runInNewContext(source.slice(start, stop), context);
  return {
    calls,
    async invoke(request) {
      const res = fakeResponse();
      await routes.get(`${method} ${url}`)({ userId: UUID, body: {}, query: {}, params: {}, ...request }, res);
      return res;
    },
  };
}

const VALID_RECURRING = { displayName: 'Synthetic plan', typicalAmountInr: 100, cadenceDays: 30, nextExpectedOn: '2027-01-01' };
const ROUTES = [
  { name: 'PATCH /card-overrides/:id', begin: "app.patch('/card-overrides/:id'", end: "app.delete('/card-overrides/:id'", method: 'patch', url: '/card-overrides/:id', request: (id) => ({ params: { id }, body: { isEnabled: true } }) },
  { name: 'DELETE /card-overrides/:id', begin: "app.delete('/card-overrides/:id'", end: '\napp.', method: 'delete', url: '/card-overrides/:id', request: (id) => ({ params: { id } }) },
  { name: 'DELETE /budgets/:id', begin: "app.delete('/budgets/:id'", end: '\napp.', method: 'delete', url: '/budgets/:id', request: (id) => ({ params: { id } }) },
  { name: 'PATCH /recurring/:id', begin: "app.patch('/recurring/:id'", end: "app.post('/recurring/:id/dismiss'", method: 'patch', url: '/recurring/:id', request: (id) => ({ params: { id }, body: VALID_RECURRING }) },
  { name: 'POST /recurring/:id/dismiss', begin: "app.post('/recurring/:id/dismiss'", end: '\napp.', method: 'post', url: '/recurring/:id/dismiss', request: (id) => ({ params: { id } }) },
  { name: 'POST /notifications/read', begin: "app.post('/notifications/read'", end: '\n/**', method: 'post', url: '/notifications/read', request: (id) => ({ body: { id } }) },
];

for (const route of ROUTES) {
  test(`${route.name} answers 400 invalid_id (not 500) for a non-uuid id and never queries`, async () => {
    const f = routeFixture(route.begin, route.end, route.method, route.url);
    for (const bad of ['v2:abc', 'projection:x']) {
      const res = await f.invoke(route.request(bad));
      assert.equal(res.code, 400, bad);
      assert.deepEqual(res.body, { error: 'invalid_id' });
    }
    assert.equal(f.calls.length, 0);
  });
  test(`${route.name} still reaches the database for a real uuid`, async () => {
    const f = routeFixture(route.begin, route.end, route.method, route.url);
    const res = await f.invoke(route.request(UUID));
    assert.notEqual(res.code, 400);
    assert.ok(f.calls.length >= 1);
  });
}

test('POST /notifications/read without an id still marks everything read', async () => {
  const f = routeFixture("app.post('/notifications/read'", '\n/**', 'post', '/notifications/read');
  const res = await f.invoke({ body: {} });
  assert.equal(res.code, 200);
  assert.equal(f.calls.length, 1);
});
