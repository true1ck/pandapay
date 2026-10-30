'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { assertLocal, buildPlan } = require('../scripts/admin_access');

function config(product = 'postgres://operator@127.0.0.1/product') {
  return {
    ADMIN_PROVISION_ENV: 'local',
    ADMIN_PROVISION_PRODUCT_DATABASE_URL: product,
    ADMIN_PROVISION_AUTH_DATABASE_URL: 'postgres://operator@127.0.0.1/auth',
  };
}
test('provisioning refuses URL overrides that could change the approved database target', () => {
  assert.doesNotThrow(() => assertLocal(config()));
  for (const suffix of ['?host=other-host', '?port=5439', '?options=-c%20role=postgres', '?service=prod', '?sslmode=require&sslmode=disable', '#hidden']) {
    assert.throws(() => assertLocal(config('postgres://operator@127.0.0.1/product' + suffix)));
  }
  assert.throws(() => assertLocal(config('postgres://operator@production.example/product')), /loopback/);
});
test('hosted provisioning requires an explicit reviewed target fingerprint', () => {
  const env = { ...config('postgres://operator@product.example/product'), ADMIN_PROVISION_ENV: 'staging' };
  assert.throws(() => assertLocal(env), /Reviewed target fingerprint/);
  assert.throws(() => assertLocal({ ...env, ADMIN_PROVISION_APPROVED_TARGET_SHA256: 'unreviewed' }), /Reviewed target fingerprint/);
});
test('revocation can target an inactive identity but must name the exact UUID', async () => {
  const id = '11111111-1111-4111-8111-111111111111';
  const auth = { async query(sql, values) {
    if (sql.includes('FROM public.users')) {
      assert.equal(values[2], true);
      return { rowCount: 1, rows: [{ id, email: 'owner@example.test' }] };
    }
    return { rows: [{ n: 'auth' }] };
  } };
  const product = { async query(sql) {
    return { rows: sql.includes('FROM public.admin_users') ? [{ id, role: 'owner', is_active: false }] : [{ n: 'product' }] };
  } };
  const args = { operation: 'revoke', email: 'owner@example.test', reason: 'Explicit incident revocation', 'user-id': id };
  assert.equal((await buildPlan(args, auth, product)).userId, id);
  await assert.rejects(buildPlan({ ...args, 'user-id': undefined }, auth, product), /exact --user-id/);
});
