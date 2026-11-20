'use strict';
// isV2Card answers "v1 or v2?" with one small query once a product shape has been seen, and gives exactly the
// answer the full load gives. A rule change moves data_version, so a cached answer is never reused across it.
const test = require('node:test');
const assert = require('node:assert/strict');
const cardStateV2 = require('../src/card_state_v2');

function fakeClient(product) {
  const calls = [];
  const card = () => ({ id: 'card-1', profile_id: 'p', card_product_id: product.id, statement_day: 5, opened_on: null,
    anniversary_on: null, created_at: new Date(), data_version: product.dataVersion, point_value_inr: 1,
    base_reward_unit: 'points', base_reward_rate: 1, excluded_categories: [],
    accrual_rounding: product.accrualRounding, cashback_rounding: null, accrual_block_inr: null });
  return {
    calls,
    async query(sql) {
      calls.push(sql);
      if (/SELECT uc\.card_product_id, cp\.data_version/.test(sql)) return { rows: [card()] };
      if (/FROM user_cards uc\s+JOIN card_products cp/.test(sql)) return { rows: [card()] };
      return { rows: [] }; // rules, caps, milestones
    },
  };
}

for (const [shape, accrualRounding, expected] of [['v2', 'floor', true], ['v1', null, false]]) {
  test(`a ${shape}-shaped product is answered from one small query once seen; a new data_version loads again`, async () => {
    cardStateV2.clearDirectoryCache();
    const product = { id: `prod-${shape}`, dataVersion: 1, accrualRounding };
    const first = fakeClient(product);
    assert.equal(await cardStateV2.isV2Card(first, 'card-1'), expected);
    assert.equal(Boolean(await cardStateV2.loadV2Card(fakeClient(product), 'card-1')), expected, 'same answer as the full load');
    const second = fakeClient(product);
    assert.equal(await cardStateV2.isV2Card(second, 'card-1'), expected);
    assert.equal(second.calls.length, 1, 'one small query once the shape is known');
    product.dataVersion = 2; // a rule changed
    const third = fakeClient(product);
    assert.equal(await cardStateV2.isV2Card(third, 'card-1'), expected);
    assert.ok(third.calls.length > 1, 'a new data_version is loaded again, not taken from the cache');
  });
}

test('no card id is not a v2 card', async () => {
  assert.equal(await cardStateV2.isV2Card(fakeClient({ id: 'x', dataVersion: 1, accrualRounding: null }), null), false);
});
