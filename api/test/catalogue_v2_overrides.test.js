'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { applyOverrides } = require('../scripts/catalogue_v2/overrides');

// A record older than the override that talks about it: it has the rules the
// old pipeline run produced, not the one the override names.
function oldRecord() {
  return {
    reward_rules: [
      { id: 'base_cashback_1pct', category_id: 'all' },
      { id: 'airtel_telecom_25pct', category_id: 'telecom' },
    ],
    cap_rules: [{ id: 'monthly_cap' }],
    accrual_engine: { cashback_rounding: 'none' },
  };
}

function change(path, extra = {}) {
  return { path, value: 'info', reason: 'test', source_url: 'https://example.test', checked_on: '2026-11-13', ...extra };
}

test('a change for a rule the record does not have is reported as a missing selector, and the rest still apply', () => {
  const { errors, applied, record } = applyOverrides(oldRecord(), {
    changes: [
      change('reward_rules[id=preferred_partner_value_back_10pct].rule_role'),
      change('reward_rules[id=airtel_telecom_25pct].rule_role'),
    ],
  });
  assert.equal(errors.length, 1);
  assert.equal(errors[0].index, 0);
  assert.equal(errors[0].error, 'path not found at segment 2');
  assert.equal(errors[0].missing_selector, 'id=preferred_partner_value_back_10pct');
  assert.equal(applied.length, 1);
  assert.equal(record.reward_rules[1].rule_role, 'info');
});

test('a selector missing on the LAST segment (remove of a rule that is not there) is a missing selector too', () => {
  const { errors } = applyOverrides(oldRecord(), {
    changes: [change('reward_rules[id=gone]', { op: 'remove', value: undefined })],
  });
  assert.equal(errors.length, 1);
  assert.equal(errors[0].error, 'final segment not found');
  assert.equal(errors[0].missing_selector, 'id=gone');
});

test('a wrong path is NOT a missing selector: misspelt parent key, missing parent object, selector on a non-array', () => {
  const run = (path) => applyOverrides(oldRecord(), { changes: [change(path)] }).errors;
  for (const path of [
    'reward_rule[id=airtel_telecom_25pct].rule_role', // misspelt array name
    'caps.monthly.limit', // parent object does not exist
    'accrual_engine[id=x].cashback_rounding', // selector over an object, not an array
  ]) {
    const errors = run(path);
    assert.equal(errors.length, 1, path);
    assert.equal(errors[0].missing_selector, undefined, path);
  }
});

test('a change that works carries no error and no marker', () => {
  const { errors, applied } = applyOverrides(oldRecord(), {
    changes: [change('reward_rules[id=airtel_telecom_25pct].rule_role'), change('accrual_engine.cashback_rounding', { value: 'rupee_floor' })],
  });
  assert.deepEqual(errors, []);
  assert.equal(applied.length, 2);
});

test('a rule added by an earlier append can be targeted by a later change (order is respected)', () => {
  const { errors, record } = applyOverrides(oldRecord(), {
    changes: [
      change('reward_rules', { op: 'append', value: { id: 'added_rule', category_id: 'x' } }),
      change('reward_rules[id=added_rule].rule_role'),
    ],
  });
  assert.deepEqual(errors, []);
  assert.equal(record.reward_rules.at(-1).rule_role, 'info');
});

test('the same change applied BEFORE the append that creates the rule is a missing selector', () => {
  const { errors } = applyOverrides(oldRecord(), {
    changes: [
      change('reward_rules[id=added_rule].rule_role'),
      change('reward_rules', { op: 'append', value: { id: 'added_rule', category_id: 'x' } }),
    ],
  });
  assert.equal(errors.length, 1);
  assert.equal(errors[0].missing_selector, 'id=added_rule');
});
