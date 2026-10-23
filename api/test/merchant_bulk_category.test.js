const test = require('node:test');
const assert = require('node:assert/strict');

const {
  MATCH_POLICY_VERSION,
  normalizeMerchantName,
  normalizeMerchantVpa,
  isGenericMerchantName,
  merchantMatch,
  classifyCandidate,
  resolveBulkIdempotencyRow,
} = require('../src/merchant_bulk_category');

test('normalizes merchant identity without broad fuzzy matching', () => {
  assert.equal(normalizeMerchantVpa(' TESTMERCHANT@UPI '), 'testmerchant@upi');
  assert.equal(normalizeMerchantName('  Test  Merchant  '), 'test merchant');
  assert.deepEqual(
    merchantMatch({ merchant_vpa: 'TESTMERCHANT@UPI' }, { merchant_vpa: 'testmerchant@upi' }),
    { matched: true, basis: 'vpa', value: 'testmerchant@upi' },
  );
  assert.equal(merchantMatch(
    { merchant_vpa: 'merchant@ybl' },
    { merchant_vpa: 'merchant@upi' },
  ).matched, false);
  assert.equal(merchantMatch(
    { merchant_name: 'The  Shop' },
    { merchant_name: 'the shop' },
  ).matched, true);
  assert.equal(merchantMatch(
    { merchant_name: 'The Shop' },
    { merchant_name: 'The Shop Online' },
  ).matched, false);
});

test('generic merchant names cannot become a name-only grouping key', () => {
  assert.equal(isGenericMerchantName('Unknown merchant'), true);
  assert.equal(isGenericMerchantName('UPI payment 42'), true);
  assert.equal(isGenericMerchantName('919951860002'), true);
  assert.equal(isGenericMerchantName('TESTMERCHANT@upi'), false);
  assert.equal(merchantMatch(
    { merchant_name: 'UPI payment' },
    { merchant_name: 'UPI payment' },
  ).matched, false);
});

test('candidate classification selects only generic active spend rows', () => {
  const target = { categoryId: 'food', userCategoryId: null };
  assert.deepEqual(classifyCandidate({
    id: 't1', status: 'active', entry_kind: 'spend', category_id: null,
    user_category_id: null,
  }, 'source', target), {
    tier: 'default_selected', selected: true, reason: 'generic_category',
  });
  assert.equal(classifyCandidate({
    id: 't2', status: 'active', entry_kind: 'spend', category_id: 'travel',
    user_category_id: null,
  }, 'source', target).tier, 'manual_review');
  assert.equal(classifyCandidate({
    id: 't3', status: 'active', entry_kind: 'income', category_id: null,
    user_category_id: null,
  }, 'source', target).reason, 'not_spend');
  assert.equal(classifyCandidate({
    id: 't4', status: 'active', entry_kind: 'spend', category_id: null,
    user_category_id: null, has_splits: true,
  }, 'source', target).reason, 'split_transaction');
});

test('matcher policy is versioned for persisted previews', () => {
  assert.equal(MATCH_POLICY_VERSION, 'v1');
});

test('a committed null-result idempotency marker is replaceable after a failed validation', () => {
  const hash = 'request-hash';
  assert.deepEqual(resolveBulkIdempotencyRow(null, hash), { action: 'create' });
  assert.deepEqual(resolveBulkIdempotencyRow({ request_hash: 'other', result: null }, hash), {
    action: 'conflict', reason: 'key_reused',
  });
  assert.deepEqual(resolveBulkIdempotencyRow({ request_hash: hash, operation_id: 'op-1', result: null }, hash), {
    action: 'replace_pending', operationId: 'op-1',
  });
  assert.deepEqual(resolveBulkIdempotencyRow({ request_hash: hash, result: { changedCount: 2 } }, hash), {
    action: 'replay', result: { changedCount: 2 },
  });
});
