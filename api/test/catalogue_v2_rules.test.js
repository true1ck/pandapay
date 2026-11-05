// Loader v2 (plan C7): unit tests on synthetic records, one group per C7 rule.
const test = require('node:test');
const assert = require('node:assert/strict');

const { transformCardRecordV2 } = require('../scripts/catalogue_v2/transform');
const { resolveCategoryToken } = require('../scripts/catalogue_v2/category_tokens');
const { buildDirectoryIndex } = require('../scripts/catalogue_v2/directory');
const { applyOverrides, parsePath } = require('../scripts/catalogue_v2/overrides');
const { normalizeMccList } = require('../scripts/catalogue_v2/util');
const { windowFromText } = require('../scripts/catalogue_v2/unlocks');
const { parseReward } = require('../scripts/catalogue_v2/milestones');

// A small directory so these tests don't depend on the evolving fixture file.
const DIRECTORY = {
  version: 1,
  merchants: [
    { slug: 'swiggy', name: 'Swiggy', parent_slug: null, aliases: ['swiggy', 'bundl technologies'] },
    { slug: 'instamart', name: 'Swiggy Instamart', parent_slug: 'swiggy', aliases: ['instamart'] },
    { slug: 'amazon', name: 'Amazon', aliases: ['amazon'] },
    { slug: 'flipkart', name: 'Flipkart', aliases: ['flipkart'], group: 'flipkart' },
    { slug: 'myntra', name: 'Myntra', aliases: ['myntra'], group: 'flipkart' },
    { slug: 'tata_neu', name: 'Tata Neu', aliases: ['tata neu'], group: 'tata' },
    { slug: 'bigbasket', name: 'BigBasket', aliases: ['bigbasket'], group: 'tata' },
    { slug: 'croma', name: 'Croma', aliases: ['croma'], group: 'tata' },
    { slug: 'irctc', name: 'IRCTC', aliases: ['irctc'] },
  ],
  platforms: [
    { slug: 'phonepe_app', name: 'PhonePe app', kind: 'payment_app', aliases: ['phonepe', 'phonepe app'] },
    { slug: 'hdfc_smartbuy', name: 'HDFC SmartBuy', kind: 'bank_portal', issuer_slug: 'hdfc', aliases: ['smartbuy', 'hdfc smartbuy'] },
    { slug: 'amex_reward_multiplier', name: 'Reward Multiplier', kind: 'bank_portal', issuer_slug: 'amex', aliases: ['reward multiplier'] },
    { slug: 'swiggy_app', name: 'Swiggy app', kind: 'merchant_app', aliases: ['swiggy app', 'swiggy minis'] },
    { slug: 'kiwi_app', name: 'Kiwi', kind: 'payment_app', aliases: ['kiwi app'] },
  ],
};

function rule(over) {
  return {
    id: 'r1',
    category_id: 'all_retail',
    priority: 10,
    evaluation_type: 'accelerator',
    rail: 'any',
    channel_type: 'all',
    conditions: {},
    action: { multiplier: null, points_per_block: null, cashback_percent: 5, cap_reference: null, reason: 'test' },
    effective_from: null,
    effective_to: null,
    ...over,
  };
}

function card({ rules = [], caps = [], accrual = {}, cp = {}, milestones = [], benefits = [] } = {}) {
  return {
    card_product: {
      slug: 'test-card', name: 'Test Card', issuer_slug: 'hdfc', network: 'Visa',
      point_value_inr_baseline: 0.25, point_expiry_months: 24, ...cp,
    },
    accrual_engine: {
      base_block_inr: 100, rounding_mode: 'floor', base_points_per_block: null,
      base_cashback_percent: 1, capping_period_basis: 'statement_cycle', ...accrual,
    },
    reward_rules: rules,
    cap_rules: caps,
    fee_waiver_and_milestones: { spend_milestones: milestones, annual_fee_waiver: null },
    lifestyle_and_network_benefits: benefits,
    insurance_and_protection: [],
    redemption_matrix: { direct_options: [], partner_transfers: [] },
  };
}

function run(record, opts = {}) {
  return transformCardRecordV2(record, { directory: DIRECTORY, ...opts });
}

function only(result, sourceId) {
  const rows = result.rewardRules.filter((r) => r.source_local_id === sourceId);
  assert.ok(rows.length, `no rows for ${sourceId}`);
  return rows;
}

// ── C7.2 overrides ──────────────────────────────────────────────────────

test('C7.2 override paths: dotted keys, [n] index and [id=x] selector', () => {
  assert.deepEqual(parsePath('cap_rules[id=swiggy_cashback_cap].metric'), [
    { key: 'cap_rules' }, { selectKey: 'id', selectValue: 'swiggy_cashback_cap' }, { key: 'metric' },
  ]);
  assert.deepEqual(parsePath('fee_waiver_and_milestones.spend_milestones[0].period'), [
    { key: 'fee_waiver_and_milestones' }, { key: 'spend_milestones' }, { index: 0 }, { key: 'period' },
  ]);
  assert.throws(() => parsePath(''));
});

test('C7.2 overrides apply before the transform, are listed, and never mutate the source', () => {
  const record = card({
    rules: [rule({ id: 'online', rail: 'online', action: { cashback_percent: 5, cap_reference: 'cap1' } })],
    caps: [{ id: 'cap1', category_id: 'all_retail', metric: 'eligible_spend_amount', limit_value: null, limit_value_inr: 1500, period: 'statement_cycle', post_limit_behavior: { action: 'zero_accrual' }, parent_cap_id: null }],
  });
  const overrides = {
    source_slug: 'test-card',
    changes: [
      { path: 'cap_rules[id=cap1].metric', value: 'total_reward_points', reason: 'issuer caps cashback, not spend', source_url: 'https://example.test', checked_on: '2026-11-05' },
      { path: 'cap_rules[id=cap1].limit_value', value: 1500 },
      { path: 'cap_rules[id=cap1].limit_value_inr', value: null },
      { path: 'cap_rules[id=nope].metric', value: 'x' },
    ],
  };
  const before = JSON.stringify(record);
  const result = run(record, { overrides });
  assert.equal(JSON.stringify(record), before, 'source record untouched');
  const cap = result.capRules.find((c) => c.key === 'cap1');
  assert.equal(cap.cap_kind, 'total_cashback');
  assert.equal(cap.cap_amount, 1500);
  assert.equal(result.card.model_coverage.overrides_applied.length, 3);
  assert.equal(result.card.model_coverage.overrides_applied[0].reason, 'issuer caps cashback, not spend');
  assert.ok(result.card.model_coverage.flags.some((f) => f.code === 'override_not_applied'));
});

test('C7.2 override ops: set a nested key, remove an element, append', () => {
  const record = { a: { list: [{ id: 'x', v: 1 }, { id: 'y', v: 2 }] }, b: [] };
  const { record: out, applied, errors } = applyOverrides(record, {
    changes: [
      { path: 'a.list[id=y].v', value: 5 },
      { path: 'a.list[0]', op: 'remove' },
      { path: 'b', op: 'append', value: { id: 'z' } },
      { path: 'a.list[id=y].post_limit_behavior.action', value: 'zero_accrual' },
    ],
  });
  assert.deepEqual(out.a.list, [{ id: 'y', v: 5 }]);
  assert.deepEqual(out.b, [{ id: 'z' }]);
  assert.equal(applied.length, 3);
  assert.equal(errors.length, 1, 'a missing intermediate object is reported, not created');
});

// ── C7.3 category tokens ────────────────────────────────────────────────

test('C7.3.1 CATEGORY_MAP tokens become an app category', () => {
  const r = run(card({ rules: [rule({ id: 'dine', category_id: 'dining' }), rule({ id: 'groc', category_id: 'grocery' })] }));
  assert.equal(only(r, 'dine')[0].category_slug, 'dining');
  assert.equal(only(r, 'groc')[0].category_slug, 'groceries');
  assert.equal(only(r, 'dine')[0].rule_role, 'earn');
  assert.equal(only(r, 'dine')[0].min_engine_version, 1);
});

test('C7.3.2 merchant tokens become merchant_slugs; single merchant stays v1 with pattern and slugs (D9-2)', () => {
  const r = run(card({ rules: [rule({ id: 'swiggy', category_id: 'swiggy_app', channel_type: 'swiggy_app', action: { cashback_percent: 10 } })] }));
  const [row] = only(r, 'swiggy');
  assert.deepEqual(row.merchant_slugs, ['swiggy']);
  assert.equal(row.merchant_pattern, 'swiggy');
  assert.equal(row.category_slug, null);
  assert.deepEqual(row.platform_slugs, [], "the brand's own app is not a separate restriction");
  assert.equal(row.min_engine_version, 1);
});

test('C7.3.2 / D6 group tokens expand through `group`, never through parent_slug', () => {
  const index = buildDirectoryIndex(DIRECTORY);
  const t = resolveCategoryToken('tata_neu_partner_brands', { index });
  assert.deepEqual(t.parts[0].merchantSlugs, ['bigbasket', 'croma', 'tata_neu']);
  const r = run(card({ rules: [rule({ id: 'neu', category_id: 'tata_neu_partner_brands' })] }));
  const [row] = only(r, 'neu');
  assert.equal(row.merchant_slugs.length, 3);
  assert.equal(row.min_engine_version, 2, 'several merchants are v2-only');
  assert.equal(row.merchant_pattern, null);
});

test('C7.3.3 platform tokens become platform_slugs (v2-only)', () => {
  const r = run(card({ rules: [rule({ id: 'pp', category_id: 'phonepe', action: { points_per_block: 10 } })] }));
  const [row] = only(r, 'pp');
  assert.deepEqual(row.platform_slugs, ['phonepe_app']);
  assert.equal(row.min_engine_version, 2);
  assert.equal(row.unit, 'points_per_100');
});

test('C7.3.4 all_retail / other / other_retail are unrestricted', () => {
  for (const token of ['all_retail', 'other', 'other_retail']) {
    const r = run(card({ rules: [rule({ id: 'x', category_id: token, evaluation_type: 'standard_accrual', action: { cashback_percent: 1 } })] }));
    const [row] = only(r, 'x');
    assert.equal(row.rule_role, 'base', token);
    assert.equal(row.category_slug, null);
  }
});

test('C7.3.5 composite tokens: one rule per mapped part, same rate, cap targets cloned', () => {
  const r = run(card({
    rules: [rule({ id: 'dm', category_id: 'dining_movies', action: { cashback_percent: 5, cap_reference: 'dm-cap' } })],
    caps: [{ id: 'dm-cap', category_id: 'dining_movies', metric: 'total_reward_points', limit_value: 500, period: 'calendar_month', post_limit_behavior: { action: 'zero_accrual' } }],
  }));
  const rows = only(r, 'dm');
  // "movies" is narrower than entertainment: its part is pinned to MCC 7832 (D17a).
  assert.deepEqual(rows.map((x) => [x.category_slug, x.mcc_include.join()]), [['dining', ''], [null, '7832']]);
  assert.ok(rows.every((x) => x.rate === 5));
  assert.deepEqual(rows.map((x) => x.key).sort(), ['dm#1', 'dm#2']);
  const cap = r.capRules[0];
  assert.deepEqual(cap.target_keys.sort(), ['dm#1', 'dm#2']);
  assert.equal(cap.min_engine_version, 2, 'two targets: v1 cannot express it');
  assert.equal(cap.reward_rule_key, null);
});

test('C7.3.5 composite with an unmapped piece keeps the mapped parts (earn and exclusion), flagged', () => {
  const r = run(card({
    rules: [
      rule({ id: 'earn', category_id: 'dining_movies_international' }),
      rule({ id: 'excl', category_id: 'dining_jewellery', evaluation_type: 'exclusion', action: { cashback_percent: 0 } }),
    ],
  }));
  assert.deepEqual(only(r, 'earn').map((x) => [x.category_slug, x.mcc_include.join()]), [['dining', ''], [null, '7832']]);
  assert.ok(only(r, 'earn')[0].flags.includes('composite_partial'));
  // An exclusion that maps only partly still excludes what it can: an info
  // exclusion would exclude nothing.
  assert.deepEqual(only(r, 'excl').map((x) => [x.rule_role, x.category_slug]), [['exclusion', 'dining']]);
  assert.ok(only(r, 'excl')[0].flags.includes('composite_partial'));
});

test('C7.3.6 an unknown token becomes info (shown, never ranked, hidden from v1) — never dropped, never widened', () => {
  const r = run(card({ rules: [rule({ id: 'odd', category_id: 'accelerated_lifestyle', action: { cashback_percent: 10 } })] }));
  const [row] = only(r, 'odd');
  assert.equal(row.rule_role, 'info');
  assert.equal(row.min_engine_version, 2);
  assert.ok(row.info_reasons.includes('unmapped_category_token'));
  assert.equal(r.card.model_coverage.rules_info, 1);
});

// ── C7.4 condition keys ─────────────────────────────────────────────────

test('C7.4 mcc / mcc_list / mcc_in / mccs become mcc_include as 4-digit strings', () => {
  for (const key of ['mcc', 'mcc_list', 'mcc_in', 'mccs']) {
    const r = run(card({ rules: [rule({ id: 'm', category_id: 'dining', conditions: { [key]: [5812, '5814'] } })] }));
    const [row] = only(r, 'm');
    assert.deepEqual(row.mcc_include, ['5812', '5814'], key);
    assert.equal(row.min_engine_version, 2);
  }
  assert.deepEqual(normalizeMccList(['3000-3002', 742]).mccs, ['0742', '3000', '3001', '3002']);
});

test('C7.4 merchant text resolves strictly: "Swiggy Liquor" is not all of Swiggy', () => {
  const r = run(card({
    rules: [
      rule({ id: 'liq', category_id: 'excluded_spend', evaluation_type: 'exclusion', channel_type: 'swiggy_app', conditions: { merchant_pattern: 'Swiggy Liquor' }, action: { cashback_percent: 0 } }),
      rule({ id: 'minis', category_id: 'excluded_spend', evaluation_type: 'exclusion', conditions: { merchant_pattern: 'Swiggy Minis' }, action: { cashback_percent: 0 } }),
      rule({ id: 'amz', category_id: 'all_retail', conditions: { eligible_merchants: 'Amazon and Flipkart' } }),
    ],
  }));
  assert.equal(only(r, 'liq')[0].rule_role, 'info');
  assert.equal(only(r, 'minis')[0].rule_role, 'info', 'a merchant_app alias is a sub-product, not the brand');
  assert.deepEqual(only(r, 'amz')[0].merchant_slugs, ['amazon', 'flipkart']);
});

test('C7.4 platform / app / channel naming an app or portal become platform_slugs', () => {
  const r = run(card({
    rules: [
      rule({ id: 'app', category_id: 'all_retail', conditions: { app: 'PhonePe' } }),
      rule({ id: 'kiwi', category_id: 'all_retail', rail: 'upi_qr', conditions: { transaction_channel: 'UPI merchant Scan & Pay via Kiwi App' } }),
      rule({ id: 'notapp', category_id: 'all_retail', conditions: { app: 'not_PhonePe' } }),
    ],
  }));
  assert.deepEqual(only(r, 'app')[0].platform_slugs, ['phonepe_app']);
  assert.deepEqual(only(r, 'kiwi')[0].platform_slugs, ['kiwi_app']);
  assert.equal(only(r, 'kiwi')[0].rail, 'upi_qr');
  // D16: "not via PhonePe" is an exception list (v2-only on an earn rule).
  const [notapp] = only(r, 'notapp');
  assert.deepEqual([notapp.rule_role, notapp.except_platform_slugs.join(), notapp.min_engine_version], ['earn', 'phonepe_app', 2]);
  assert.deepEqual(notapp.platform_slugs, []);
});

test('C7.4 minimum_transaction_inr -> min_txn_inr; excluded_categories -> excluded categories', () => {
  const r = run(card({ rules: [rule({ id: 'x', category_id: 'swiggy_app', conditions: { minimum_transaction_inr: 249, excluded_categories: ['fuel', 'wallet_load'] } })] }));
  const [row] = only(r, 'x');
  assert.equal(row.min_txn_inr, 249);
  assert.deepEqual(row.excluded_category_slugs, ['fuel', 'wallet']);
});

test('C7.4 channel_type all / online_and_retail is no restriction; other restricting keys make the rule info', () => {
  const r = run(card({
    rules: [
      rule({ id: 'all', category_id: 'dining', channel_type: 'online_and_retail' }),
      ...['birthday_window', 'selected_plan', 'booking_type', 'variant', 'transaction_type'].map((k) =>
        rule({ id: k, category_id: 'dining', conditions: { [k]: 'something-specific' } })),
    ],
  }));
  assert.equal(only(r, 'all')[0].rule_role, 'earn');
  assert.equal(only(r, 'all')[0].rail, null);
  for (const k of ['birthday_window', 'selected_plan', 'booking_type', 'variant', 'transaction_type']) {
    assert.equal(only(r, k)[0].rule_role, 'info', k);
  }
});

test('C7.4 a category list on the rule splits it into one part per category (PhonePe select categories)', () => {
  const r = run(card({ rules: [rule({ id: 'pp', category_id: 'phonepe', conditions: { app: 'PhonePe', eligible_categories: ['utilities', 'insurance', 'travel'] } })] }));
  const rows = only(r, 'pp');
  assert.deepEqual(rows.map((x) => x.category_slug).sort(), ['bills', 'insurance', 'travel']);
  assert.ok(rows.every((x) => x.platform_slugs[0] === 'phonepe_app'));
});

// ── C7.5 roles ──────────────────────────────────────────────────────────

test('C7.5 roles: exclusion, base, earn, and a flagged unrestricted accelerator', () => {
  const r = run(card({
    rules: [
      rule({ id: 'ex', category_id: 'fuel', evaluation_type: 'exclusion', action: { cashback_percent: 0 } }),
      rule({ id: 'base', evaluation_type: 'standard_accrual', action: { cashback_percent: 1 } }),
      rule({ id: 'fb', evaluation_type: 'fallback', action: { cashback_percent: 1 } }),
      rule({ id: 'std', evaluation_type: 'standard_accrual', rail: 'online', action: { cashback_percent: 2 } }),
      rule({ id: 'acc', category_id: 'dining' }),
      rule({ id: 'wide', category_id: 'all_retail', action: { cashback_percent: 4 } }),
    ],
  }));
  assert.equal(only(r, 'ex')[0].rule_role, 'exclusion');
  assert.equal(only(r, 'ex')[0].rate, 0);
  assert.equal(only(r, 'base')[0].rule_role, 'base');
  assert.equal(only(r, 'fb')[0].rule_role, 'base');
  assert.equal(only(r, 'std')[0].rule_role, 'earn');
  assert.equal(only(r, 'acc')[0].rule_role, 'earn');
  const [wide] = only(r, 'wide');
  assert.equal(wide.rule_role, 'earn');
  assert.ok(wide.flags.includes('unrestricted_accelerator'));
  assert.ok(r.card.model_coverage.flags.some((f) => f.code === 'unrestricted_accelerator'));
});

test('C7.5 lifecycle triggers and "up to" rates become info (D8b)', () => {
  const r = run(card({
    rules: [
      rule({ id: 'welcome_bonus', conditions: { first_transaction: true }, action: { points_per_block: 500 } }),
      rule({ id: 'smartbuy-up-to-10x', category_id: 'smartbuy', action: { points_per_block: 50, reason: 'Up to 10X on SmartBuy' } }),
    ],
  }));
  assert.ok(only(r, 'welcome_bonus')[0].info_reasons.includes('unsupported_trigger'));
  assert.ok(only(r, 'smartbuy-up-to-10x')[0].info_reasons.includes('up_to_rate'));
});

// ── C7.6 engine versions ────────────────────────────────────────────────

test('C7.6 exclusions: category stays v1 at rate 0; MCC-only is v2; category+MCC is split into both', () => {
  const r = run(card({
    rules: [
      rule({ id: 'cat', category_id: 'rent', evaluation_type: 'exclusion', action: { cashback_percent: 0 } }),
      rule({ id: 'mcc', category_id: 'excluded_spend', evaluation_type: 'exclusion', conditions: { mcc_list: [6540] }, action: { cashback_percent: 0 } }),
      rule({ id: 'both', category_id: 'fuel', evaluation_type: 'exclusion', conditions: { mcc_list: [5541, 5542] }, action: { cashback_percent: 0 } }),
      rule({ id: 'none', category_id: 'excluded_spend', evaluation_type: 'exclusion', action: { cashback_percent: 0 } }),
    ],
  }));
  assert.equal(only(r, 'cat')[0].min_engine_version, 1);
  assert.equal(only(r, 'mcc')[0].min_engine_version, 2);
  const both = only(r, 'both');
  assert.deepEqual(both.map((x) => [x.category_slug, x.mcc_include.length, x.min_engine_version]), [['fuel', 0, 1], [null, 2, 2]]);
  assert.equal(only(r, 'none')[0].rule_role, 'info', 'an exclusion with nothing to match would exclude everything');
});

test('C7.6 / D9-4 an unusual block carries block_inr (v2) and gets an explicit base rule', () => {
  const r = run(card({
    accrual: { base_block_inr: 125, base_points_per_block: 2, base_cashback_percent: null },
    rules: [rule({ id: 'dine', category_id: 'dining', action: { points_per_block: 10 } })],
  }));
  const [dine] = only(r, 'dine');
  assert.equal(dine.block_inr, 125);
  assert.equal(dine.min_engine_version, 2);
  const base = r.rewardRules.find((x) => x.key === 'base-block');
  assert.equal(base.rule_role, 'base');
  assert.equal(base.block_inr, 125);
  assert.equal(base.rate, 2);
  assert.equal(r.card.base_reward_unit, 'points_per_100');
  assert.equal(r.card.base_reward_rate, 1.6, 'v1 keeps the per-₹100 equivalent');
  assert.equal(r.card.accrual_block_inr, 125);
});

test('D8a whole points per block load as points even when a cashback % is also given', () => {
  const r = run(card({
    cp: { point_value_inr_baseline: 1 },
    accrual: { base_block_inr: 100, base_points_per_block: 1, base_cashback_percent: 1 },
    rules: [rule({ id: 'x', category_id: 'dining', action: { points_per_block: 5, cashback_percent: 5 } })],
  }));
  assert.equal(r.card.base_reward_unit, 'points_per_100');
  assert.equal(only(r, 'x')[0].unit, 'points_per_100');
  assert.equal(only(r, 'x')[0].rate, 5);
});

// ── C7.7 caps ───────────────────────────────────────────────────────────

function capCard(caps, rules) {
  return card({
    accrual: { base_points_per_block: 1, base_cashback_percent: null },
    rules: rules || [
      rule({ id: 'pts', category_id: 'dining', action: { points_per_block: 10, cap_reference: 'c' } }),
    ],
    caps,
  });
}
const capBase = { id: 'c', category_id: 'dining', mcc_target_list: [], period: 'calendar_month', limit_value: 1000, limit_value_inr: null, post_limit_behavior: { action: 'zero_accrual' }, parent_cap_id: null, reset_day: null };

test('C7.7 metric -> cap_kind by the target rule currency; native cap_amount; v1 projection', () => {
  const bonus = run(capCard([{ ...capBase, metric: 'bonus_reward_points' }])).capRules[0];
  assert.equal(bonus.cap_kind, 'bonus_points');
  assert.equal(bonus.cap_amount, 1000);
  assert.equal(bonus.measure, 'reward_value');
  assert.equal(bonus.cap_value, 250, '1000 points × ₹0.25');
  assert.equal(bonus.post_cap_rate, null, 'base continues after a bonus cap');
  assert.equal(bonus.post_cap_behavior, null);
  assert.equal(bonus.reward_rule_key, 'pts');
  assert.equal(bonus.min_engine_version, 1);

  const total = run(capCard([{ ...capBase, metric: 'total_reward_points' }])).capRules[0];
  assert.equal(total.cap_kind, 'total_points');
  assert.equal(total.post_cap_rate, 0);

  const cash = run(card({
    rules: [rule({ id: 'cb', category_id: 'dining', action: { cashback_percent: 5, cap_reference: 'c' } })],
    caps: [{ ...capBase, metric: 'bonus_reward_points', limit_value: 500 }],
  })).capRules[0];
  assert.equal(cash.cap_kind, 'bonus_cashback');
  assert.equal(cash.cap_value, 500);

  const spend = run(capCard([{ ...capBase, metric: 'eligible_spend_amount', limit_value: null, limit_value_inr: 20000, post_limit_behavior: { action: 'downgrade_to_base_rate' } }])).capRules[0];
  assert.equal(spend.cap_kind, 'eligible_spend');
  assert.equal(spend.cap_amount, 20000);
  assert.equal(spend.measure, 'spend_amount');
  assert.equal(spend.post_cap_behavior, 'base_rate');
  assert.equal(spend.post_cap_rate, null);

  const zero = run(capCard([{ ...capBase, metric: 'eligible_spend_amount', limit_value_inr: 20000 }])).capRules[0];
  assert.equal(zero.post_cap_behavior, 'zero');
  assert.equal(zero.post_cap_rate, 0);

  const count = run(capCard([{ ...capBase, metric: 'txn_count', limit_value: 2 }])).capRules[0];
  assert.equal(count.cap_kind, 'txn_count');
  assert.equal(count.measure, 'txn_count');
});

test('C7.7 waiver caps are skipped; missing values are flagged, not guessed', () => {
  const r = run(capCard([
    { ...capBase, id: 'w', metric: 'waiver_amount_inr', limit_value_inr: 250 },
    { ...capBase, id: 'm', metric: 'total_reward_points', limit_value: null, limit_value_inr: null },
  ]));
  assert.equal(r.capRules.length, 0);
  const codes = r.card.model_coverage.flags.map((f) => f.code);
  assert.ok(codes.includes('fuel_waiver_cap_skipped'));
  assert.ok(codes.includes('missing_cap_value'));
  assert.equal(r.card.model_coverage.caps_total, 2);
});

test('C7.7 scope, parents, periods and the D3 version rule', () => {
  const r = run(card({
    accrual: { base_points_per_block: 1, base_cashback_percent: null },
    rules: [
      rule({ id: 'app', category_id: 'phonepe', action: { points_per_block: 10, cap_reference: 'child' } }),
      rule({ id: 'dine', category_id: 'dining', action: { points_per_block: 5, cap_reference: 'daily' } }),
    ],
    caps: [
      { ...capBase, id: 'overall', category_id: 'all_retail', metric: 'total_reward_points', limit_value: 5000 },
      { ...capBase, id: 'parent', category_id: 'phonepe', metric: 'bonus_reward_points', limit_value: 1500 },
      { ...capBase, id: 'child', category_id: 'insurance', metric: 'bonus_reward_points', limit_value: 500, parent_cap_id: 'parent' },
      { ...capBase, id: 'daily', metric: 'bonus_reward_points', period: 'day' },
      { ...capBase, id: 'yearly', category_id: 'travel', metric: 'total_reward_points', period: 'calendar_year' },
      { ...capBase, id: 'orphan', category_id: 'accelerated_categories', metric: 'bonus_reward_points' },
    ],
  }));
  const by = Object.fromEntries(r.capRules.map((c) => [c.key, c]));
  assert.equal(by.overall.scope, 'card');
  assert.equal(by.child.parent_key, 'parent');
  assert.ok(r.capRules.indexOf(by.parent) < r.capRules.indexOf(by.child), 'parents are written first');
  assert.equal(by.child.min_engine_version, 2, 'its target (a platform rule) is v2-only (D3)');
  assert.equal(by.daily.period, 'statement_cycle');
  assert.equal(by.daily.min_engine_version, 2);
  assert.ok(by.daily.flags.includes('unenforced_period'));
  assert.equal(by.daily.enforced, false);
  assert.equal(by.yearly.period, 'annual');
  assert.equal(by.yearly.anchor, 'calendar_year');
  assert.equal(by.yearly.category_slug, 'travel', 'no targets: the legacy category link');
  assert.ok(by.orphan.flags.includes('orphan_cap'));
});

test('C7.7 sanity flag suspect_cap_unit: a small spend cap on a ≥5% cashback rule', () => {
  const r = run(card({
    rules: [rule({ id: 'sw', category_id: 'swiggy_app', action: { cashback_percent: 10, cap_reference: 'c' } })],
    caps: [{ ...capBase, metric: 'eligible_spend_amount', limit_value: null, limit_value_inr: 1500 }],
  }));
  assert.ok(r.capRules[0].flags.includes('suspect_cap_unit'));
});

test('D8d caps tiered by card age keep the steady-state value and are flagged', () => {
  const r = run(capCard([
    { ...capBase, id: 'fuel_cap_first_6_months', metric: 'total_reward_points', limit_value: 250 },
    { ...capBase, id: 'fuel_cap', metric: 'total_reward_points', limit_value: 150 },
  ]));
  assert.deepEqual(r.capRules.map((c) => c.cap_amount), [150]);
  assert.ok(r.card.model_coverage.flags.some((f) => f.code === 'tier_by_card_age'));
});

// ── C7.8 milestones ─────────────────────────────────────────────────────

test('C7.8 milestone periods map to the right clock', () => {
  const m = (id, period) => ({ id, label: `₹1,000 voucher (${id})`, threshold_spend_inr: 100000, reward_value_inr: 1000, period, is_repeatable: true });
  const r = run(card({
    milestones: [
      m('a', 'card_anniversary_year'), m('b', 'calendar_year'), m('c', 'fiscal_year'), m('d', 'quarter'),
      m('e', 'calendar_quarter'), m('f', 'calendar_month'), m('g', 'statement_cycle'),
    ],
  }));
  const got = Object.fromEntries(r.milestones.map((x) => [x.key, `${x.period}/${x.anchor}`]));
  assert.deepEqual(got, {
    a: 'annual/card_anniversary', b: 'annual/calendar_year', c: 'annual/fiscal_year',
    d: 'quarter/calendar_year', e: 'quarter/calendar_year', f: 'calendar_month/calendar_year',
    g: 'statement_cycle/statement_cycle',
  });
});

test('C7.8 welcome windows become window_days; rewards are parsed; event milestones are left out', () => {
  const r = run(card({
    milestones: [
      { id: 'welcome_15k_90d', label: 'Welcome Gift - 10,000 Membership Rewards points', threshold_spend_inr: 15000, reward_value_inr: 4000, period: 'card_anniversary_year', is_repeatable: false },
      { id: 'jf', label: 'Joining fee waiver', threshold_spend_inr: 10000, reward_value_inr: 250, period: 'first_90_days' },
      { id: 'bday', label: 'Birthday bonus', threshold_spend_inr: 1, reward_value_inr: 100, period: 'annual' },
    ],
  }));
  const by = Object.fromEntries(r.milestones.map((x) => [x.key, x]));
  assert.equal(by.welcome_15k_90d.window_days, 90);
  assert.equal(by.welcome_15k_90d.reward_kind, 'points');
  assert.equal(by.welcome_15k_90d.reward_points, 10000);
  assert.equal(by.welcome_15k_90d.period, 'lifetime');
  assert.equal(by.jf.window_days, 90);
  assert.equal(by.jf.reward_kind, 'fee_waiver');
  assert.equal(by.bday, undefined);
  assert.deepEqual(parseReward('₹5,000 Tata CLiQ voucher'), { kind: 'voucher', points: null });
});

// ── C7.9 unlock rules ───────────────────────────────────────────────────

test('C7.9 spend-gated benefits become unlock rows: one per threshold, tiers labelled', () => {
  const r = run(card({
    benefits: [
      { benefit_id: 'lounge', category_id: 'lounge', label: 'Domestic lounge access', quota_count: 2, quota_period: 'quarter', evaluation_engine: { conditions: { previous_quarter_spend_inr: 50000 } } },
      { benefit_id: 'multi', category_id: 'lounge', label: 'Lounge visits', quota_count: 3, quota_period: 'annual', evaluation_engine: { conditions: { eligible_spend_milestones_inr: [50000, 100000, 150000], membership_spend_basis: 'yearly spends' } } },
      { benefit_id: 'gold', category_id: 'lounge', label: 'Gold tier international lounge access', quota_count: 6, quota_period: 'annual', evaluation_engine: { conditions: { tier: 'gold', tier_unlock_spend_inr: 750000, evaluation_period: 'card_anniversary_year' } } },
      { benefit_id: 'vague', category_id: 'lounge', label: 'Lounge on spends', evaluation_engine: { conditions: { spend_condition: 'subject to spends' } } },
    ],
  }));
  const u = r.unlockRules;
  const lounge = u.find((x) => x.benefit_key === 'lounge');
  assert.equal(lounge.spend_threshold_inr, 50000);
  assert.equal(lounge.spend_window, 'previous_calendar_quarter');
  assert.equal(lounge.unlocks_quota, 2);
  assert.equal(lounge.unlocks_period, 'quarter');
  assert.equal(lounge.kind, 'lounge_domestic');
  assert.deepEqual(u.filter((x) => x.benefit_key === 'multi').map((x) => [x.spend_threshold_inr, x.unlocks_quota]), [[50000, 1], [100000, 1], [150000, 1]]);
  const gold = u.find((x) => x.benefit_key === 'gold');
  assert.equal(gold.kind, 'tier');
  assert.equal(gold.tier_label, 'Gold');
  assert.equal(gold.spend_window, 'card_year');
  assert.ok(r.card.model_coverage.flags.some((f) => f.code === 'unparsed_unlock' && f.source_local_id === 'vague'));
  assert.equal(windowFromText('minimum_spend_previous_3_calendar_months_inr').window, 'rolling_days');
});

test('C7.9 "spend this quarter, use it next quarter" reads as the previous quarter; lookbacks read as rolling days', () => {
  const r = run(card({
    benefits: [
      { benefit_id: 'q', category_id: 'lounge', label: 'Lounge', quota_count: 2, quota_period: 'quarter', evaluation_engine: { conditions: { spend_threshold_inr: 75000, spend_period: 'calendar_quarter', unlock_period: 'following_calendar_quarter' } } },
      { benefit_id: 'l', category_id: 'lounge', label: 'Lounge', quota_count: 2, quota_period: 'quarter', evaluation_engine: { conditions: { eligible_spend_inr: 50000, lookback_period: 'last 3 months' } } },
      { benefit_id: 'none', category_id: 'lounge', label: 'Lounge', evaluation_engine: { conditions: { spend_condition: 'None' } } },
    ],
  }));
  const by = Object.fromEntries(r.unlockRules.map((u) => [u.benefit_key, u]));
  assert.equal(by.q.spend_window, 'previous_calendar_quarter');
  assert.deepEqual([by.l.spend_window, by.l.window_days], ['rolling_days', 90]);
  assert.equal(by.none, undefined);
  assert.ok(!r.card.model_coverage.flags.some((f) => f.source_local_id === 'none'), '"None" is not an unparsed gate');
});

// ── C7.10 card fields, coverage and status ──────────────────────────────

test('C7.10 / D7 / D10 / D11 rounding: mapped from source, assumed when silent, cashback rounding only from source', () => {
  const mode = (m, accrual = {}) => run(card({ accrual: { rounding_mode: m, ...accrual } })).card;
  assert.equal(mode('floor').accrual_rounding, 'floor');
  assert.equal(mode('nearest_integer').accrual_rounding, 'points_half_up');
  assert.equal(mode('floor_to_nearest_paisa').accrual_rounding, 'none');
  assert.equal(mode('points_floor').accrual_rounding, 'points_floor');
  const silentCash = run(card({ accrual: { rounding_mode: 'N/A' } }));
  assert.equal(silentCash.card.accrual_rounding, 'none');
  assert.ok(silentCash.card.model_coverage.flags.some((f) => f.code === 'rounding_assumed'));
  assert.equal(silentCash.card.cashback_rounding, null, 'D11: silent source stays null');
  const silentPoints = run(card({ accrual: { rounding_mode: 'N/A', base_points_per_block: 2, base_cashback_percent: null } }));
  assert.equal(silentPoints.card.accrual_rounding, 'floor');
  assert.equal(mode('N/A', { cashback_rounding: 'rupee_floor' }).cashback_rounding, 'rupee_floor');
  assert.equal(mode('floor').points_expiry_months, 24);
  assert.equal(mode('floor').accrual_block_inr, 100);
});

test('C7.10 model_coverage shape and model_status', () => {
  const basic = run(card({ rules: [rule({ id: 'b', evaluation_type: 'standard_accrual', action: { cashback_percent: 1 } })] }));
  assert.equal(basic.card.model_status, 'basic');
  assert.deepEqual(Object.keys(basic.card.model_coverage).sort(),
    ['caps_enforced', 'caps_total', 'flags', 'overrides_applied', 'rules_info', 'rules_modelled', 'rules_total']);

  const partial = run(card({ rules: [rule({ id: 'e', category_id: 'dining' })] }));
  assert.equal(partial.card.model_status, 'partial', 'bonus rules stay partial until verified');
  const infoOnly = run(card({ rules: [rule({ id: 'i', category_id: 'mystery_token' })] }));
  assert.equal(infoOnly.card.model_status, 'partial', 'an unmodelled bonus is not "basic"');

  const verified = run(card({ rules: [rule({ id: 'e', category_id: 'dining' })] }), { verifiedSlugs: new Set(['test-card']) });
  assert.equal(verified.card.model_status, 'verified');
});

// ── C8 D14: transaction attributes; override safety checks ──────────────

test('D14b international / birthday rules are info with depends_on_txn_attribute, never unrestricted', () => {
  const r = run(card({
    rules: [
      rule({ id: 'intl', category_id: 'international_spend', action: { points_per_block: 4 } }),
      rule({ id: 'scope', category_id: 'all_retail', conditions: { transaction_scope: 'international_transactions' } }),
      rule({ id: 'bday', category_id: 'all_retail', conditions: { birthday_window: 'birthday ±1 day' } }),
      rule({ id: 'dmi', category_id: 'dining_movies_international' }),
    ],
  }));
  for (const id of ['intl', 'scope', 'bday']) {
    const [row] = only(r, id);
    assert.equal(row.rule_role, 'info', id);
    assert.ok(row.flags.includes('depends_on_txn_attribute'), id);
  }
  // The international part of a composite is left out (and flagged); the rest is modelled.
  assert.deepEqual(only(r, 'dmi').map((x) => [x.category_slug, x.mcc_include.join()]), [['dining', ''], [null, '7832']]);
  assert.ok(only(r, 'dmi')[0].flags.includes('depends_on_txn_attribute'));
});

test('D14c a whole-array override that drops an exclusion, and dangling cap references, are reported', () => {
  const record = card({
    rules: [
      rule({ id: 'earn', category_id: 'dining', action: { cashback_percent: 5, cap_reference: 'c' } }),
      rule({ id: 'no-fuel', category_id: 'fuel', evaluation_type: 'exclusion', action: { cashback_percent: 0 } }),
    ],
    caps: [{ ...capBase, metric: 'total_reward_points' }],
  });
  const r = run(record, {
    overrides: {
      changes: [
        { path: 'reward_rules', value: [rule({ id: 'earn', category_id: 'dining', action: { cashback_percent: 5, cap_reference: 'gone' } })] },
      ],
    },
  });
  const flags = r.card.model_coverage.flags;
  assert.ok(flags.some((f) => f.code === 'override_removed_exclusion' && f.source_local_id === 'no-fuel'));
  assert.ok(flags.some((f) => f.code === 'dangling_cap_reference' && f.detail === 'gone'));
  const untouched = run(record);
  assert.ok(!untouched.card.model_coverage.flags.some((f) => f.code === 'override_removed_exclusion'));
});

// ── C8 D16: exceptions and minimum amounts ──────────────────────────────

test('D16a "except at X" / "not via X" become except lists; exclusions keep v1, earn rules go v2', () => {
  const dir = {
    ...DIRECTORY,
    merchants: [...DIRECTORY.merchants, { slug: 'hpcl', name: 'HPCL', aliases: ['hpcl', 'hindustan petroleum'] }],
    platforms: [...DIRECTORY.platforms, { slug: 'google_pay', name: 'Google Pay', kind: 'payment_app', aliases: ['google pay', 'gpay'] }],
  };
  const r = transformCardRecordV2(card({
    rules: [
      rule({ id: 'fuel-ex', category_id: 'fuel', evaluation_type: 'exclusion', channel_type: 'non-HPCL fuel', action: { cashback_percent: 0 } }),
      rule({ id: 'util-ex', category_id: 'utility', evaluation_type: 'exclusion', conditions: { platform: 'not via Google Pay' }, action: { cashback_percent: 0 } }),
      rule({ id: 'upi-ex', category_id: 'all_retail', evaluation_type: 'exclusion', rail: 'upi_qr', conditions: { app: 'not_PhonePe' }, action: { cashback_percent: 0 } }),
    ],
  }), { directory: dir });
  const [fuel] = only(r, 'fuel-ex');
  assert.deepEqual([fuel.rule_role, fuel.category_slug, fuel.except_merchant_slugs.join(), fuel.min_engine_version], ['exclusion', 'fuel', 'hpcl', 1]);
  const [util] = only(r, 'util-ex');
  assert.deepEqual([util.rule_role, util.category_slug, util.except_platform_slugs.join(), util.min_engine_version], ['exclusion', 'bills', 'google_pay', 1]);
  const [upi] = only(r, 'upi-ex');
  assert.deepEqual([upi.rule_role, upi.rail, upi.except_platform_slugs.join()], ['exclusion', 'upi_qr', 'phonepe_app']);
  assert.equal(upi.min_engine_version, 2, 'rail-only exclusion');
});

test('D16b a minimum on an exclusion becomes max_txn_inr (v2); a card-wide floor gets its own exclusion', () => {
  const r = run(card({
    rules: [
      rule({ id: 'small', category_id: 'excluded_spend', evaluation_type: 'exclusion', conditions: { minimum_transaction_inr: 100 }, action: { cashback_percent: 0 } }),
    ],
  }));
  const [small] = only(r, 'small');
  assert.deepEqual([small.rule_role, small.max_txn_inr, small.min_txn_inr, small.min_engine_version], ['exclusion', 100, null, 2]);

  const floor = run(card({
    rules: [
      rule({ id: 'sw', category_id: 'swiggy_app', conditions: { minimum_transaction_inr: 249 }, action: { cashback_percent: 10 } }),
      rule({ id: 'other', category_id: 'all_retail', evaluation_type: 'standard_accrual', conditions: { minimum_transaction_inr: 100 }, action: { cashback_percent: 1 } }),
    ],
  }));
  const ex = floor.rewardRules.find((x) => x.key === 'other#min-amount');
  assert.deepEqual([ex.rule_role, ex.max_txn_inr, ex.category_slug, ex.min_engine_version], ['exclusion', 100, null, 2]);

  const notWide = run(card({
    rules: [
      rule({ id: 'dine', category_id: 'dining', action: { cashback_percent: 5 } }),
      rule({ id: 'other', category_id: 'all_retail', evaluation_type: 'standard_accrual', conditions: { minimum_transaction_inr: 100 }, action: { cashback_percent: 1 } }),
    ],
  }));
  assert.equal(notWide.rewardRules.find((x) => x.key === 'other#min-amount'), undefined, 'dining has no floor, so the floor is not card-wide');
});

// ── C8 D17: never widen (WP2 review) ────────────────────────────────────

const D17_DIRECTORY = {
  ...DIRECTORY,
  merchants: [...DIRECTORY.merchants, { slug: 'indianoil', name: 'IndianOil', aliases: ['indianoil', 'indian oil', 'iocl'] }],
  platforms: [...DIRECTORY.platforms,
    { slug: 'payzapp', name: 'PayZapp', kind: 'payment_app', issuer_slug: 'hdfc', aliases: ['payzapp'] },
    { slug: 'axis_travel_edge', name: 'Axis Travel EDGE', kind: 'bank_portal', issuer_slug: 'axis', aliases: ['travel edge'] }],
};
function runD17(record) {
  return transformCardRecordV2(record, { directory: D17_DIRECTORY });
}

test('D17c "identified by MID/TID" text that names a brand restricts the rule to that brand', () => {
  const r = runD17(card({
    accrual: { base_points_per_block: 1, base_cashback_percent: null },
    rules: [
      rule({ id: 'indianoil_accelerated_fuel', category_id: 'fuel', priority: 1, action: { points_per_block: 10 },
        conditions: { merchant_pattern: 'select IndianOil fuel stations identified by IOCL-provided MID/TID', transaction_amount_block_inr: 100 } }),
      rule({ id: 'mid_only', category_id: 'dining', conditions: { merchant_identification: 'identified by MID/TID' } }),
    ],
  }));
  const [fuel] = only(r, 'indianoil_accelerated_fuel');
  assert.deepEqual(fuel.merchant_slugs, ['indianoil'], 'never all fuel');
  assert.equal(fuel.category_slug, 'fuel');
  assert.equal(only(r, 'mid_only')[0].rule_role, 'earn', 'no brand named: the text is just how merchants are identified');
});

test('D17a narrow tokens on earning rules get the token MCCs (v2-only) or become info; exclusions keep the category', () => {
  const r = run(card({
    rules: [
      rule({ id: 'pharm', category_id: 'pharmacy', action: { cashback_percent: 10 } }),
      rule({ id: 'hotel', category_id: 'travel_hotels', action: { cashback_percent: 10 } }),
      rule({ id: 'food', category_id: 'food_delivery', action: { cashback_percent: 10 } }),
      rule({ id: 'ex-movie', category_id: 'movie', evaluation_type: 'exclusion', action: { cashback_percent: 0 } }),
    ],
  }));
  const [pharm] = only(r, 'pharm');
  assert.deepEqual([pharm.category_slug, pharm.mcc_include.join(), pharm.min_engine_version], [null, '5912', 2]);
  const [hotel] = only(r, 'hotel');
  assert.ok(hotel.mcc_include.includes('7011') && hotel.mcc_include.includes('3501') && hotel.mcc_include.includes('3999'));
  assert.equal(only(r, 'food')[0].rule_role, 'info', 'no MCC table entry: info, never all of dining');
  const [exMovie] = only(r, 'ex-movie');
  assert.deepEqual([exMovie.rule_role, exMovie.category_slug, exMovie.min_engine_version], ['exclusion', 'entertainment', 1]);
});

test('D17b an exclusion with a narrow token and MCCs keeps its v1 category row as well as the v2 MCC row', () => {
  const r = run(card({
    rules: [rule({ id: 'exclude_railways', category_id: 'railways', evaluation_type: 'exclusion', conditions: { category: 'railways', mcc_list: [4011, 4112] }, action: { cashback_percent: 0 } })],
  }));
  assert.deepEqual(only(r, 'exclude_railways').map((x) => [x.category_slug, x.mcc_include.join(), x.min_engine_version]),
    [['travel', '', 1], [null, '4011,4112', 2]]);
});

test('D17d excluded categories on an exclusion are its own scope (extra rows), never exceptions', () => {
  const r = runD17(card({
    rules: [rule({ id: 'payzapp_accelerator_exclusions', category_id: 'business_spend', evaluation_type: 'exclusion', rail: 'online', channel_type: 'PayZapp',
      conditions: { excluded_categories: ['clubs', 'rent', 'hospital', 'education', 'wallet_load'] }, action: { cashback_percent: 0 } })],
  }));
  const rows = only(r, 'payzapp_accelerator_exclusions');
  assert.ok(rows.every((x) => x.rule_role === 'exclusion' && x.platform_slugs.join() === 'payzapp'));
  assert.deepEqual(rows.map((x) => x.category_slug).sort(), ['education', 'health', 'rent', 'wallet']);
  assert.ok(rows.every((x) => !x.except_merchant_slugs.length && !x.except_platform_slugs.length && !x.excluded_category_slugs.length));
});

test('D17e a platform named inside a longer clause does not stand in for the clause', () => {
  const r = runD17(card({
    rules: [
      rule({ id: 'travel_edge_above_200k', category_id: 'travel', action: { points_per_block: 35 },
        conditions: { monthly_travel_edge_spend: 'Above ₹2,00,000 cumulative Travel EDGE transactions' } }),
      rule({ id: 'uno', category_id: 'all_retail', action: { cashback_percent: 1 }, conditions: { platform: 'PhonePe app / RuPay credit card on UPI where applicable' } }),
      rule({ id: 'clean', category_id: 'travel', action: { points_per_block: 5 }, conditions: { portal: 'Axis Travel EDGE portal' } }),
    ],
  }));
  assert.equal(only(r, 'travel_edge_above_200k')[0].rule_role, 'info');
  assert.equal(only(r, 'uno')[0].rule_role, 'info');
  assert.deepEqual(only(r, 'clean')[0].platform_slugs, ['axis_travel_edge']);
});

test('D17f an unknown or narrower sub-category on a category rule is never silently dropped', () => {
  const r = run(card({
    rules: [
      rule({ id: 'travel-hotel-bonus', category_id: 'travel', action: { points_per_block: 52 }, conditions: { category: 'hotels' } }),
      rule({ id: 'travel-flight-bonus', category_id: 'travel', action: { points_per_block: 32 }, conditions: { category: 'flights' } }),
      rule({ id: 'odd', category_id: 'travel', conditions: { category: 'luxury_stays' } }),
      rule({ id: 'ex', category_id: 'education', evaluation_type: 'exclusion', conditions: { category: 'school_and_educational_services' }, action: { cashback_percent: 0 } }),
    ],
  }));
  const hotel = only(r, 'travel-hotel-bonus')[0];
  const flight = only(r, 'travel-flight-bonus')[0];
  assert.ok(hotel.mcc_include.includes('7011') && !hotel.mcc_include.includes('4511'));
  assert.ok(flight.mcc_include.includes('4511') && !flight.mcc_include.includes('7011'));
  assert.equal(only(r, 'odd')[0].rule_role, 'info');
  assert.equal(only(r, 'ex')[0].rule_role, 'exclusion', 'an exclusion may ignore it (excludes more)');
});

test('D17g caps for transfers, fees, surcharges, waivers, thresholds and charges are not earning caps; no inference for them', () => {
  const r = run(capCard([
    { ...capBase, id: 'miles_transfer_annual', category_id: 'travel', metric: 'total_reward_points', limit_value: 50000 },
    { ...capBase, id: 'utility-fee-threshold', category_id: 'utility', metric: 'eligible_spend_amount', limit_value_inr: 25000 },
    { ...capBase, id: 'fuel_surcharge_waiver_spend_cap', category_id: 'fuel', metric: 'eligible_spend_amount', limit_value_inr: 4000 },
    { ...capBase, id: 'transaction-charge-waiver-monthly', category_id: 'travel_rail', metric: 'eligible_spend_amount', limit_value_inr: 1000 },
    { ...capBase, id: 'dining_monthly', category_id: 'dining', metric: 'bonus_reward_points', limit_value: 1000 },
  ], [
    rule({ id: 'dine', category_id: 'dining', action: { points_per_block: 10 } }),
    rule({ id: 'travel', category_id: 'travel', action: { points_per_block: 10 } }),
  ]));
  assert.deepEqual(r.capRules.map((c) => c.key), ['dining_monthly']);
  assert.deepEqual(r.capRules[0].target_keys, ['dine'], 'an earning cap is still linked by token');
  assert.equal(r.coverage.capsSkipped.filter((x) => x.reason === 'non_earning_cap_skipped').length, 4);
});

test('D8d "first 6m" / "post 6m" cap tiers keep the steady state; post_limit_conflict flags bonus caps that stop', () => {
  const r = run(capCard([
    { ...capBase, id: 'fuel_first_6m', metric: 'total_reward_points', limit_value: 250 },
    { ...capBase, id: 'fuel_post_6m', metric: 'total_reward_points', limit_value: 150 },
    { ...capBase, id: 'b', category_id: 'travel', metric: 'bonus_reward_points', limit_value: 100, post_limit_behavior: { action: 'zero_accrual' } },
  ]));
  assert.deepEqual(r.capRules.filter((c) => c.key.startsWith('fuel')).map((c) => [c.key, c.cap_amount]), [['fuel_post_6m', 150]]);
  assert.ok(r.capRules.find((c) => c.key === 'fuel_post_6m').flags.includes('tier_by_card_age'));
  assert.ok(r.capRules.find((c) => c.key === 'b').flags.includes('post_limit_conflict'));
});

test('D17i the override fingerprint covers values; D17h any override that unmakes an exclusion is reported', () => {
  const record = card({
    rules: [
      rule({ id: 'earn', category_id: 'dining' }),
      rule({ id: 'no-fuel', category_id: 'fuel', evaluation_type: 'exclusion', action: { cashback_percent: 0 } }),
      rule({ id: 'no-rent', category_id: 'rent', evaluation_type: 'exclusion', action: { cashback_percent: 0 } }),
    ],
  });
  const a = run(record, { overrides: { changes: [{ path: 'reward_rules[id=earn].action.cashback_percent', value: 6 }] } });
  const b = run(record, { overrides: { changes: [{ path: 'reward_rules[id=earn].action.cashback_percent', value: 7 }] } });
  assert.notEqual(a.card.model_coverage.overrides_applied[0].value_sha256, b.card.model_coverage.overrides_applied[0].value_sha256);
  const removed = run(record, {
    overrides: {
      changes: [
        { path: 'reward_rules[id=no-fuel]', op: 'remove' },
        { path: 'reward_rules[id=no-rent].rule_role', value: 'info' },
      ],
    },
  });
  const flagged = removed.card.model_coverage.flags.filter((f) => f.code === 'override_removed_exclusion').map((f) => f.source_local_id);
  assert.deepEqual(flagged.sort(), ['no-fuel', 'no-rent']);
});

test('D17j a listed card is verified only when nothing but D13/D14 deferrals remains', () => {
  const verifiedSlugs = new Set(['test-card']);
  const clean = run(card({ rules: [rule({ id: 'e', category_id: 'dining' })] }), { verifiedSlugs });
  assert.equal(clean.card.model_status, 'verified');
  const deferred = run(card({ rules: [rule({ id: 'e', category_id: 'dining' }), rule({ id: 'intl', category_id: 'international_spend' })] }), { verifiedSlugs });
  assert.equal(deferred.card.model_status, 'verified', 'an international-only rule is a D14 deferral');
  const unresolved = run(card({ rules: [rule({ id: 'e', category_id: 'dining' }), rule({ id: 'odd', category_id: 'mystery_token' })] }), { verifiedSlugs });
  assert.equal(unresolved.card.model_status, 'partial');
  assert.ok(unresolved.coverage.verifiedBlockedBy.includes('info_rule'));
});

test('unmapped excluded categories on earning rules map through the token map (e_wallet_loading -> wallet)', () => {
  const r = run(card({ rules: [rule({ id: 'base', evaluation_type: 'standard_accrual', conditions: { excluded_categories: ['e_wallet_loading', 'rental_payments', 'education_government', 'cash_advance'] }, action: { cashback_percent: 1 } })] }));
  assert.deepEqual(only(r, 'base')[0].excluded_category_slugs, ['education', 'government', 'rent', 'wallet']);
  assert.ok(only(r, 'base')[0].flags.includes('unmapped_excluded_category'), 'non-purchase items stay flagged');
});

// ── C8 D18: v1-only rows and the WP2 re-review rulings ──────────────────

const pointsCard = (rules, extra = {}) => card({ accrual: { base_points_per_block: 2, base_cashback_percent: null }, rules, ...extra });

test('D18b a narrow-token exclusion: broad row is v1-only, v2 uses the precise MCC row (source MCCs or the token table)', () => {
  const r = run(pointsCard([
    rule({ id: 'ex-fast-food', category_id: 'fast_food', evaluation_type: 'exclusion', conditions: { mcc_list: [5814] }, action: { points_per_block: 0 } }),
    rule({ id: 'ex-tolls', category_id: 'transportation_tolls', evaluation_type: 'exclusion', conditions: { spend_category: 'Transportation & Tolls' }, action: { points_per_block: 0 } }),
    rule({ id: 'dining-10x', category_id: 'dining', action: { points_per_block: 20 } }),
  ]));
  assert.deepEqual(only(r, 'ex-fast-food').map((x) => [x.category_slug, x.mcc_include.join(), x.min_engine_version, x.max_engine_version]),
    [['dining', '', 1, 1], [null, '5814', 2, null]]);
  const tolls = only(r, 'ex-tolls');
  assert.deepEqual(tolls.map((x) => [x.category_slug, x.max_engine_version]), [['travel', 1], [null, null]]);
  assert.deepEqual(tolls[1].mcc_include, ['4111', '4121', '4131', '4784']);
  // In a v2 view (rows with max_engine_version 1 ignored) no category-only
  // exclusion covers dining, so the dining bonus isn't zeroed.
  const v2Exclusions = r.rewardRules.filter((x) => x.rule_role === 'exclusion' && x.max_engine_version !== 1);
  assert.ok(!v2Exclusions.some((x) => x.category_slug === 'dining'));
});

test('D18c reduced-rate rules keep a v1 row: narrowed ones get a v1-only broad row, unmappable ones stay broad', () => {
  const r = run(pointsCard([
    rule({ id: 'reduced_rate_railway', category_id: 'railways', evaluation_type: 'standard_accrual', action: { points_per_block: 1 } }),
    rule({ id: 'reduced_food', category_id: 'food_delivery', evaluation_type: 'standard_accrual', action: { points_per_block: 1 } }),
    rule({ id: 'reduced_utility_mcc', category_id: 'utility', evaluation_type: 'standard_accrual', conditions: { mcc: [4900] }, action: { points_per_block: 1 } }),
  ]));
  assert.deepEqual(only(r, 'reduced_rate_railway').map((x) => [x.category_slug, x.mcc_include.join(), x.min_engine_version, x.max_engine_version, x.rate]),
    [[null, '4112', 2, null, 1], ['travel', '', 1, 1, 1]]);
  assert.deepEqual(only(r, 'reduced_food').map((x) => [x.rule_role, x.category_slug, x.min_engine_version, x.max_engine_version]),
    [['earn', 'dining', 1, null]], 'no MCC table: broad in both feeds');
  const util = only(r, 'reduced_utility_mcc');
  assert.ok(util.some((x) => x.min_engine_version === 1 && x.max_engine_version === 1 && x.category_slug === 'bills' && !x.mcc_include.length));
  assert.ok(util.some((x) => x.min_engine_version === 2 && x.mcc_include.join() === '4900'));
});

test('a categorised exclusion that is v2-only (e.g. education via third-party apps) keeps a v1-only category row', () => {
  const r = run(card({
    rules: [rule({ id: 'education_third_party_exclusion', category_id: 'education', evaluation_type: 'exclusion', conditions: { app: 'PhonePe' }, action: { cashback_percent: 0 } })],
  }));
  assert.deepEqual(only(r, 'education_third_party_exclusion').map((x) => [x.category_slug, x.platform_slugs.join(), x.min_engine_version, x.max_engine_version]),
    [['education', 'phonepe_app', 2, null], ['education', '', 1, 1]]);
});

test('D18d a composite or synonym restatement of the rule\'s own category is not "unknown"', () => {
  const r = run(pointsCard([
    rule({ id: 'utility-reduced', category_id: 'utility', evaluation_type: 'standard_accrual', conditions: { category: 'utility_bill_payments' }, action: { points_per_block: 1 } }),
    rule({ id: 'rent-reduced', category_id: 'rent', evaluation_type: 'standard_accrual', conditions: { category: 'real_estate_rental_payments' }, action: { points_per_block: 1 } }),
    rule({ id: 'gov-reduced', category_id: 'government', evaluation_type: 'standard_accrual', conditions: { category: 'government_services_charges_payments' }, action: { points_per_block: 1 } }),
    rule({ id: 'tel-reduced', category_id: 'utility', evaluation_type: 'standard_accrual', conditions: { category: 'telecom_and_utilities' }, action: { points_per_block: 1 } }),
  ]));
  for (const [id, cat] of [['utility-reduced', 'bills'], ['rent-reduced', 'rent'], ['gov-reduced', 'government'], ['tel-reduced', 'bills']]) {
    assert.deepEqual(only(r, id).map((x) => [x.rule_role, x.category_slug, x.min_engine_version]), [['earn', cat, 1]], id);
  }
});

test('D18e "other than X" on an exclusion is an exception; bonus-only exclusions are info', () => {
  const dir = { ...DIRECTORY, merchants: [...DIRECTORY.merchants, { slug: 'lic_india', name: 'LIC of India', aliases: ['lic of india', 'lic'] }, { slug: 'bpcl', name: 'BPCL', aliases: ['bpcl', 'bharat petroleum'] }] };
  const r = transformCardRecordV2(card({
    rules: [
      rule({ id: 'non-lic-insurance-exclusion', category_id: 'insurance_non_lic', evaluation_type: 'exclusion', conditions: { mcc_list: [5960, 6300], excluded_merchants: ['LIC of India'] }, action: { cashback_percent: 0, reason: 'No points on non-LIC insurance payments.' } }),
      rule({ id: 'non_bpcl_fuel_exclusion', category_id: 'fuel', evaluation_type: 'exclusion', conditions: { merchant_scope: 'Petrol pumps/service stations other than eligible BPCL transactions' }, action: { cashback_percent: 0 } }),
      rule({ id: 'five-pct-exclusions', category_id: 'excluded_spend', evaluation_type: 'exclusion', conditions: { excluded_categories: ['fuel', 'rent'] }, action: { cashback_percent: 0, reason: 'Transactions in excluded categories do not qualify for accelerated 5% CashBack.' } }),
      rule({ id: 'exclude_rent_from_ticket_milestone', category_id: 'rent', evaluation_type: 'exclusion', conditions: { mcc_list: [6513] }, action: { cashback_percent: 0, reason: 'Rent payments are excluded from ticket milestone calculations.' } }),
    ],
  }), { directory: dir });
  assert.ok(only(r, 'non-lic-insurance-exclusion').every((x) => x.rule_role === 'exclusion' && x.except_merchant_slugs.join() === 'lic_india' && !x.merchant_slugs.length));
  assert.deepEqual(only(r, 'non_bpcl_fuel_exclusion').map((x) => [x.rule_role, x.category_slug, x.except_merchant_slugs.join()]), [['exclusion', 'fuel', 'bpcl']]);
  for (const id of ['five-pct-exclusions', 'exclude_rent_from_ticket_milestone']) {
    assert.ok(only(r, id).every((x) => x.rule_role === 'info' && x.flags.includes('bonus_only_exclusion')), id);
  }
});

test('D18f narrow items inside combined restrictions keep their MCC pinning', () => {
  const r = run(pointsCard([
    rule({ id: 'pp-movies', category_id: 'phonepe', conditions: { categories: ['movies', 'dining'] }, action: { points_per_block: 10 } }),
  ]));
  const rows = only(r, 'pp-movies');
  assert.deepEqual(rows.map((x) => [x.category_slug, x.mcc_include.join(), x.platform_slugs.join()]).sort(),
    [['dining', '', 'phonepe_app'], [null, '7832', 'phonepe_app']].sort());
});

test('D18g caps: id and label only; MID/TID with no directory brand is skipped', () => {
  const r = run(capCard([{ ...capBase, metric: 'bonus_reward_points', description: 'Fee waiver does not apply to this cap' }]));
  assert.equal(r.capRules.length, 1, 'a description mentioning a fee is not a non-earning cap');
  const m = run(card({ rules: [rule({ id: 'x', category_id: 'dining', conditions: { merchant_identification: 'Eligible ZYX Restaurants identified by MID/TID' } })] }));
  assert.equal(only(m, 'x')[0].rule_role, 'earn');
});

test('D18h a rule whose platform is also in its own except list is info', () => {
  const r = run(card({ rules: [rule({ id: 'other_paytm', category_id: 'phonepe', conditions: { app: 'not_PhonePe' } })] }));
  const [row] = only(r, 'other_paytm');
  assert.equal(row.rule_role, 'info');
  assert.ok(row.flags.includes('self_contradictory_rule'));
});

test('D18i a narrow token on a merchant rule adds no MCCs; booking-type rate splits on an aggregator are info', () => {
  const dir = { ...DIRECTORY, merchants: [...DIRECTORY.merchants,
    { slug: 'makemytrip', name: 'MakeMyTrip', aliases: ['makemytrip'] },
    { slug: 'indigo', name: 'IndiGo', aliases: ['indigo'] }] };
  const r = transformCardRecordV2(card({ rules: [
    rule({ id: 'mmt-flight', category_id: 'travel_flights', conditions: { merchant: 'MakeMyTrip' }, action: { cashback_percent: 3 } }),
    rule({ id: 'mmt-hotel', category_id: 'travel_hotels', conditions: { merchant: 'MakeMyTrip' }, action: { cashback_percent: 6 } }),
    rule({ id: 'indigo-flights', category_id: 'travel_flights', conditions: { merchant: 'IndiGo' }, action: { cashback_percent: 5 } }),
  ] }), { directory: dir });
  for (const id of ['mmt-flight', 'mmt-hotel']) {
    const [row] = only(r, id);
    assert.equal(row.rule_role, 'info', id);
    assert.ok(row.flags.includes('depends_on_txn_attribute'));
  }
  const [indigo] = only(r, 'indigo-flights');
  assert.deepEqual([indigo.rule_role, indigo.merchant_slugs.join(), indigo.mcc_include.length, indigo.category_slug], ['earn', 'indigo', 0, null]);
});

test('D18j verified is blocked only by the listed flags', () => {
  const verifiedSlugs = new Set(['test-card']);
  const informational = run(pointsCard([
    rule({ id: 'e', category_id: 'dining', action: { points_per_block: 10 } }),
    rule({ id: 'tier', category_id: 'travel_hotels', action: { points_per_block: 10 } }), // narrow_token_to_mcc: informational
  ], { accrual: { rounding_mode: 'N/A', base_points_per_block: 2, base_cashback_percent: null } }), { verifiedSlugs });
  assert.equal(informational.card.model_status, 'verified');
  const blocked = run(pointsCard([
    rule({ id: 'e', category_id: 'dining', action: { points_per_block: 10, cap_reference: 'nope' } }),
  ]), { verifiedSlugs });
  assert.equal(blocked.card.model_status, 'partial', 'dangling_cap_reference blocks');
});

// ── C8 D19 (WP2 round-2 re-review) ──────────────────────────────────────

test('D19a full-exclusion phrasings are never bonus_only', () => {
  const { classifyExclusionText } = require('../scripts/catalogue_v2/rules');
  const full = [
    'Insurance transactions are excluded from core and accelerated Reward Points.',
    'Fuel transactions are excluded from Reward Points and milestone benefits.',
    'These spends do not qualify for core or accelerated EDGE Reward Points.',
    'Loan-on-Card transactions are not eligible for Reward Points and do not count toward the 10X milestone.',
    'Rent payments are excluded from Reward Points.',
    'Wallet loads are not eligible for reward points.',
    'Government spends earn 0 Reward Points.',
    'B2B spends are excluded from rewards/milestone calculations.',
    'Offline UPI transactions under INR 2,000 at small merchants are not eligible for reward points, voucher benefits, milestone benefits or other product benefits unless stated otherwise.',
  ];
  for (const text of full) assert.equal(classifyExclusionText(text), 'full', text);
  const bonus = [
    'Transactions in excluded categories do not qualify for accelerated 5% CashBack.',
    'Rent payments are excluded from PVR INOX ticket milestone calculations.',
    'EMI transactions do not qualify for the applicable milestone and fee-waiver spend calculations.',
    'Education transactions are excluded from White Pass milestone spend effective 1 April 2026.',
    'UPI transactions through FIRST Digital do not form part of the 10X rewards programme or its threshold.',
  ];
  for (const text of bonus) assert.equal(classifyExclusionText(text), 'bonus_only', text);
  const r = run(card({ rules: [
    rule({ id: 'insurance_excl', category_id: 'insurance', evaluation_type: 'exclusion', action: { cashback_percent: 0, reason: full[0] } }),
    rule({ id: 'acc_excl', category_id: 'rent', evaluation_type: 'exclusion', action: { cashback_percent: 0, reason: bonus[0] } }),
  ] }));
  assert.equal(only(r, 'insurance_excl')[0].rule_role, 'exclusion');
  assert.ok(!only(r, 'insurance_excl')[0].flags.includes('bonus_only_exclusion'));
  assert.equal(only(r, 'acc_excl')[0].rule_role, 'info');
});

// ── C8 D13: terms that depend on the cardholder; override conventions ───

test('D13a a cap sized by the credit limit keeps its kind with a null amount and is flagged', () => {
  const r = run(capCard([{ ...capBase, id: 'intl_2x_credit_limit', metric: 'eligible_spend_amount', limit_value: null, limit_value_inr: null }]));
  const [cap] = r.capRules;
  assert.equal(cap.cap_kind, 'eligible_spend');
  assert.equal(cap.cap_amount, null);
  assert.equal(cap.min_engine_version, 2);
  assert.equal(cap.enforced, false);
  assert.ok(cap.flags.includes('cap_depends_on_user'));
});

test('D13b a rule gated on a paid membership becomes info with depends_on_user_attribute', () => {
  const r = run(card({ rules: [rule({ id: 'neon', rail: 'upi_qr', conditions: { kiwi_neon_membership: true } })] }));
  const [row] = only(r, 'neon');
  assert.equal(row.rule_role, 'info');
  assert.ok(row.flags.includes('depends_on_user_attribute'));
});

test('D13d overrides may replace whole arrays, set nulls and set rule_role; statement_cycle_quarter maps to quarter', () => {
  const record = card({
    rules: [
      rule({ id: 'a', category_id: 'dining', action: { cashback_percent: 5, cap_reference: 'old' } }),
      rule({ id: 'b', category_id: 'dining' }),
    ],
    caps: [{ ...capBase, id: 'old', metric: 'bonus_reward_points' }],
  });
  const r = run(record, {
    overrides: {
      changes: [
        { path: 'reward_rules[id=b].rule_role', value: 'info' },
        { path: 'reward_rules[id=a].action.cap_reference', value: 'q' },
        { path: 'cap_rules', value: [{ ...capBase, id: 'q', metric: 'total_reward_points', period: 'statement_cycle_quarter', limit_value: 4000 }] },
        { path: 'accrual_engine.cashback_rounding', value: 'rupee_floor' },
        { path: 'card_product.point_expiry_months', value: null },
      ],
    },
  });
  assert.equal(only(r, 'b')[0].rule_role, 'info');
  assert.deepEqual(r.capRules.map((c) => [c.key, c.period, c.target_keys.join()]), [['q', 'quarter', 'a']]);
  assert.ok(r.capRules[0].flags.includes('period_approximated'));
  assert.equal(r.card.cashback_rounding, 'rupee_floor');
  assert.equal(r.card.points_expiry_months, null);
  assert.equal(r.card.model_coverage.overrides_applied.length, 5);
});
