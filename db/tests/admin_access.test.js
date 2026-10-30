'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { assertLocal, buildPlan, parseArgs, planHash, operationId } = require('../scripts/admin_access');

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
test('review hashes survive JSONB key ordering and CLI rejects ambiguous duplicate input', () => {
  const a=planHash({role:'owner',snapshot:{state:'pending',version:'4'}});
  const b=planHash({snapshot:{version:'4',state:'pending'},role:'owner'});
  assert.equal(a,b);
  assert.match(operationId(a),/^[0-9a-f-]{36}$/);
  assert.equal(parseArgs(['resume','--operation-id',operationId(a),'--plan-hash',a])['plan-hash'],a);
  assert.throws(()=>parseArgs(['apply','--role','owner','--role','readonly']),/duplicate/);
  assert.throws(()=>parseArgs(['apply','resume']),/one command/);
});
test('revocation can target an inactive identity but must name the exact UUID', async () => {
  const id = '11111111-1111-4111-8111-111111111111';
  const auth = { async query(sql, values) {
    if (sql.includes('FROM public.users')) {
      assert.equal(values[0], id);
      return { rowCount: 1, rows: [{ id, email: 'owner@example.test', is_active: false, deleted: false, is_email_verified: false }] };
    }
    if (sql.includes('FROM admin_private.principals')) return { rows: [{ state: 'revoked', version: '2' }] };
    if (sql.includes('FROM admin_private.credentials')) return { rows: [] };
    return { rows: [{ name: 'auth' }] };
  } };
  const product = { async query(sql) {
    return { rows: sql.includes('FROM public.admin_users') ? [{ id, email: 'owner@example.test', role: 'owner', is_active: false }] : [{ name: 'product' }] };
  } };
  const args = { operation: 'revoke', email: 'owner@example.test', reason: 'Explicit incident revocation', 'user-id': id };
  const target = { environment: 'local', targetKey: 'a'.repeat(64) };
  assert.equal((await buildPlan(args, auth, product, target)).userId, id);
  await assert.rejects(buildPlan({ ...args, 'user-id': undefined }, auth, product, target), /exact_user_id_required/);
  await assert.rejects(buildPlan({ ...args, operation: 'grant' }, auth, product, target), /active_verified_identity_required/);
});
