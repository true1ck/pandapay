const test = require('node:test');
const assert = require('node:assert/strict');

const { replayCurrentCapConsumption } = require('../src/card_state_reconciliation');

const card = {
  statement_day: 5,
  point_value_inr: 1,
  base_reward_unit: 'cashback_percent',
  base_reward_rate: 1,
  excluded_categories: [],
};

const rewardRules = [{
  id: 'other-reward',
  category_id: null,
  merchant_pattern: null,
  rail: null,
  unit: 'cashback_percent',
  rate: 5,
  min_txn_inr: null,
  max_txn_inr: null,
  excluded_categories: [],
  effective_from: null,
  effective_to: null,
  priority: 1,
}];

test('replays current reward-value cap consumption in transaction order', () => {
  const result = replayCurrentCapConsumption({
    card,
    rewardRules,
    capRules: [{
      id: 'other-cap',
      reward_rule_id: 'other-reward',
      category_id: null,
      period: 'calendar_month',
      cap_value: 100,
      measure: 'reward_value',
      post_cap_unit: 'cashback_percent',
      post_cap_rate: 1,
    }],
    transactions: [
      { id: 'late', amount_inr: 2000, occurred_at: '2026-10-12T12:00:00Z' },
      { id: 'early', amount_inr: 1000, occurred_at: '2026-10-01T12:00:00Z' },
      { id: 'old', amount_inr: 1000, occurred_at: '2026-09-30T12:00:00Z' },
    ],
    asOf: new Date('2026-10-15T12:00:00Z'),
  });

  assert.equal(result.consumed.get('other-cap'), 100);
  assert.deepEqual(result.periods.get('other-cap'), {
    start: '2026-10-01',
    end: '2026-10-31',
  });
});

test('does not consume a cap when no matching reward rule applies', () => {
  const result = replayCurrentCapConsumption({
    card,
    rewardRules,
    capRules: [{
      id: 'grocery-cap',
      reward_rule_id: 'different-rule',
      category_id: 'groceries',
      period: 'calendar_month',
      cap_value: 1000,
      measure: 'spend_amount',
    }],
    transactions: [{
      id: 'fuel',
      amount_inr: 500,
      category_id: 'fuel',
      occurred_at: '2026-10-12T12:00:00Z',
    }],
    asOf: new Date('2026-10-15T12:00:00Z'),
  });

  assert.equal(result.consumed.has('grocery-cap'), false);
});
