'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createAdminAuth, CAPABILITY_SQL } = require('../src/middleware/adminAuth');
function response() {
  return { statusCode: 200, status(value) { this.statusCode = value; return this; }, json(value) { this.body = value; return this; } };
}
test('dashboard capability requires authentication before querying', async () => {
  const middleware = createAdminAuth({ query: () => assert.fail('anonymous must not query') });
  const res = response();
  await middleware({}, res, () => assert.fail('must not enter'));
  assert.equal(res.statusCode, 401);
});
test('token role labels never replace fresh capability lookup', async () => {
  for (const role of ['user', 'admin', 'moderator', 'security_admin']) {
    let calls = 0;
    const middleware = createAdminAuth({ query: async (sql, params) => {
      calls++; assert.equal(sql, CAPABILITY_SQL); assert.deepEqual(params, ['verified-user']); return { rows: [] };
    } });
    const res = response();
    await middleware({ user: { id: 'verified-user', role } }, res, () => assert.fail('must not enter'));
    assert.equal(calls, 1); assert.equal(res.statusCode, 403);
  }
  for (const predicate of ['a.revoked_at IS NULL', 'a.expires_at > now()', 'u.is_active = true', 'u.deleted = false']) assert.ok(CAPABILITY_SQL.includes(predicate));
});
test('explicit active capability authorizes independently of enum labels', async () => {
  const middleware = createAdminAuth({ query: async () => ({ rows: [{ allowed: true }] }) });
  let entered = 0;
  await middleware({ user: { id: 'verified-user', role: 'user' } }, response(), () => entered++);
  assert.equal(entered, 1);
});
test('capability database failure denies safely', async () => {
  const logs = [];
  const middleware = createAdminAuth({ query: async () => { throw Object.assign(new Error('postgres://private@example'), { code: '42P01' }); }, logger: { error: (...args) => logs.push(args) } });
  const res = response();
  await middleware({ user: { id: 'verified-user' } }, res, () => assert.fail('must not enter'));
  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, { error: 'authorization_unavailable' });
  assert.equal(JSON.stringify(logs).includes('private'), false);
});
