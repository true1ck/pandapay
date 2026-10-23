'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  MerchantRuleError,
  assertSourceTransaction,
  decodeCursor,
  encodeCursor,
  loadCategoryTarget,
  requestHash,
  responseForRule,
  ruleMatchFromTransaction,
} = require('../src/user_merchant_category_rules');

test('future-rule identity is exact VPA, with strict-name fallback only for specific names', () => {
  assert.deepEqual(ruleMatchFromTransaction({ merchant_vpa: ' TESTMERCHANT@UPI ', merchant_name: 'Anything' }), {
    basis: 'vpa', value: 'testmerchant@upi',
  });
  assert.deepEqual(ruleMatchFromTransaction({ merchant_vpa: null, merchant_name: '  Test  Merchant ' }), {
    basis: 'strict_name', value: 'test merchant',
  });
  assert.throws(
    () => ruleMatchFromTransaction({ merchant_vpa: null, merchant_name: 'UPI payment 42' }),
    (error) => error instanceof MerchantRuleError && error.code === 'merchant_identity_unsafe',
  );
  assert.throws(
    () => ruleMatchFromTransaction({ merchant_vpa: '919951860002', merchant_name: 'A shop' }),
    (error) => error instanceof MerchantRuleError && error.code === 'merchant_identity_unsafe',
  );
  assert.throws(
    () => ruleMatchFromTransaction({ merchant_vpa: null, merchant_name: 'Razorpay' }),
    (error) => error instanceof MerchantRuleError && error.code === 'merchant_identity_unsafe',
  );
  assert.deepEqual(ruleMatchFromTransaction({ merchant_vpa: 'shop@ybl', merchant_name: 'The Shop' }), {
    basis: 'vpa', value: 'shop@ybl',
  });
});

test('source transaction eligibility excludes non-spend and split rows', () => {
  assert.throws(() => assertSourceTransaction(null), /source_transaction_not_found/);
  assert.throws(
    () => assertSourceTransaction({ status: 'active', entry_kind: 'income' }),
    (error) => error.code === 'source_transaction_ineligible',
  );
  assert.throws(
    () => assertSourceTransaction({ status: 'active', entry_kind: 'spend', has_splits: true }),
    (error) => error.code === 'source_transaction_ineligible',
  );
  assert.equal(assertSourceTransaction({ status: 'active', entry_kind: 'spend' }).status, 'active');
});

test('custom child category must resolve to the selected built-in parent', async () => {
  const queries = [];
  const client = {
    async query(sql, values) {
      queries.push({ sql, values });
      if (sql.includes('FROM spend_categories')) return { rows: [{ id: '11111111-1111-4111-8111-111111111111', name: 'Food', slug: 'food' }] };
      if (sql.includes('FROM user_categories')) return { rows: [{
        id: '22222222-2222-4222-8222-222222222222', name: 'Coffee',
        parent_category_id: '11111111-1111-4111-8111-111111111111', parent_user_category_id: null,
      }] };
      throw new Error(`unexpected query: ${sql}`);
    },
  };
  const target = await loadCategoryTarget(
    client,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222',
  );
  assert.equal(target.userCategoryName, 'Coffee');
  assert.equal(queries.length, 2);
});

test('rule responses state future-only scope and do not expose SMS or account data', () => {
  const result = responseForRule({
    id: '33333333-3333-4333-8333-333333333333', match_basis: 'vpa', match_value: 'merchant@upi',
    merchant_name: ' Merchant  Name ', category_id: '11111111-1111-4111-8111-111111111111',
    category_name: 'Food', category_slug: 'food', user_category_id: null, is_active: true,
    version: '2', source_transaction_id: '44444444-4444-4444-8444-444444444444',
  });
  assert.equal(result.historicTransactionsUnchanged, true);
  assert.equal(result.version, 2);
  assert.equal(Object.prototype.hasOwnProperty.call(result, 'rawSms'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(result, 'accountNumber'), false);
});

test('idempotency hash is stable for equivalent request objects', () => {
  assert.equal(requestHash({ sourceId: 'a', categoryId: 'b' }), requestHash({ sourceId: 'a', categoryId: 'b' }));
  assert.notEqual(requestHash({ sourceId: 'a', categoryId: 'b' }), requestHash({ sourceId: 'a', categoryId: 'c' }));
});

test('rule listing cursor is opaque, bounded, and validates its owner-visible shape', () => {
  const encoded = encodeCursor({ id: '33333333-3333-4333-8333-333333333333', updated_at: '2026-10-23T10:00:00.000Z' });
  assert.deepEqual(decodeCursor(encoded), { id: '33333333-3333-4333-8333-333333333333', updatedAt: '2026-10-23T10:00:00.000Z' });
  assert.throws(() => decodeCursor('bad'), (error) => error.code === 'cursor_invalid');
});
