const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const {
  normalize,
  loadDirectory,
  resolveMerchant,
  ancestors,
} = require('../src/merchant_directory');

/**
 * Engine v2 (plan C3) and the merchant directory resolver (plan C5).
 *
 * The scenario files in db/fixtures/reward_v2_scenarios/ are the contract
 * the Dart engine (packages/pandapay_domain) is held to as well; this file
 * loads every one of them. The unit tests below pin the JS-side details the
 * scenarios can't reach (resolver tie-breaks, legacy cap conversion, the v1
 * delegation switch).
 */

const FIXTURES = path.join(__dirname, '..', '..', 'db', 'fixtures');

// ---------------------------------------------------------------------------
// Merchant directory (C5)
// ---------------------------------------------------------------------------

const DIR_JSON = {
  version: 1,
  merchants: [
    { slug: 'swiggy', name: 'Swiggy', parent_slug: null, aliases: ['swiggy', 'bundl technologies'], vpa_prefixes: ['swiggy'] },
    { slug: 'instamart', name: 'Swiggy Instamart', parent_slug: 'swiggy', aliases: ['swiggy instamart', 'instamart'], vpa_prefixes: [] },
    { slug: 'zomato', name: 'Zomato', parent_slug: null, aliases: ['zomato'], vpa_prefixes: ['zomato', 'zomatoorder'] },
    { slug: 'blinkit', name: 'Blinkit', parent_slug: 'zomato', aliases: ['blinkit', 'grofers'], vpa_prefixes: [] },
    { slug: 'beta_mart', name: 'Beta Mart', parent_slug: null, aliases: ['mart one'], vpa_prefixes: [] },
    { slug: 'alpha_mart', name: 'Alpha Mart', parent_slug: null, aliases: ['mart one'], vpa_prefixes: [] },
    { slug: 'retired', name: 'Retired Brand', parent_slug: null, aliases: ['retired brand'], vpa_prefixes: ['retired'], is_active: false },
  ],
  platforms: [{ slug: 'phonepe_app', name: 'PhonePe app', kind: 'payment_app', aliases: ['phonepe'] }],
};

test('normalize: lowercases, collapses non-alphanumeric runs to one space, trims', () => {
  assert.strictEqual(normalize('  BUNDL-Technologies*Pvt.  Ltd '), 'bundl technologies pvt ltd');
  assert.strictEqual(normalize('Swiggy__Instamart'), 'swiggy instamart');
  assert.strictEqual(normalize(null), '');
  assert.strictEqual(normalize(''), '');
});

test('resolveMerchant: an alias matches on word boundaries only', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.deepStrictEqual(resolveMerchant(dir, 'BUNDL TECHNOLOGIES BLR', null)?.slug, 'swiggy');
  assert.strictEqual(resolveMerchant(dir, 'Swiggywala Store', null), null);
  assert.strictEqual(resolveMerchant(dir, 'myswiggy', null), null);
  assert.strictEqual(resolveMerchant(dir, 'POS*SWIGGY*ORDER', null)?.slug, 'swiggy');
});

test('resolveMerchant: the longest matching alias wins', () => {
  const dir = loadDirectory(DIR_JSON);
  const r = resolveMerchant(dir, 'SWIGGY INSTAMART BANGALORE', null);
  assert.strictEqual(r.slug, 'instamart');
  assert.strictEqual(r.via, 'alias');
});

test('resolveMerchant: equal-length aliases tie-break to the slug that sorts first', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.strictEqual(resolveMerchant(dir, 'MART ONE STORE', null).slug, 'alpha_mart');
});

test('resolveMerchant: a VPA prefix match wins over an alias in the name', () => {
  const dir = loadDirectory(DIR_JSON);
  const r = resolveMerchant(dir, 'Swiggy', 'zomato.order@okaxis');
  assert.strictEqual(r.slug, 'zomato');
  assert.strictEqual(r.via, 'vpa');
  // "starts with": the normalized VPA user part is "zomatoorder pay".
  assert.strictEqual(resolveMerchant(dir, null, 'ZomatoOrder.pay@ybl').slug, 'zomato');
});

test('resolveMerchant: a VPA that matches nothing falls back to the alias', () => {
  const dir = loadDirectory(DIR_JSON);
  const r = resolveMerchant(dir, 'Blinkit Commerce', 'someone@okhdfc');
  assert.strictEqual(r.slug, 'blinkit');
  assert.strictEqual(r.via, 'alias');
});

test('resolveMerchant: inactive merchants are never resolved', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.strictEqual(resolveMerchant(dir, 'Retired Brand', null), null);
  assert.strictEqual(resolveMerchant(dir, null, 'retired@upi'), null);
});

test('resolveMerchant: no name and no VPA, or no directory, resolves to null', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.strictEqual(resolveMerchant(dir, null, null), null);
  assert.strictEqual(resolveMerchant(dir, '   ', ''), null);
  assert.strictEqual(resolveMerchant(null, 'Swiggy', null), null);
});

test('ancestors: follows parent_slug, excludes the slug itself', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.deepStrictEqual(ancestors(dir, 'instamart'), ['swiggy']);
  assert.deepStrictEqual(ancestors(dir, 'swiggy'), []);
  assert.deepStrictEqual(ancestors(dir, 'unknown_slug'), []);
  assert.deepStrictEqual(ancestors(null, 'instamart'), []);
});

test('ancestors: depth is limited to 5 and cycles are safe', () => {
  const chain = [];
  for (let i = 0; i < 8; i += 1) chain.push({ slug: `m${i}`, name: `M${i}`, parent_slug: i < 7 ? `m${i + 1}` : null, aliases: [] });
  const deep = loadDirectory({ merchants: chain, platforms: [] });
  assert.deepStrictEqual(ancestors(deep, 'm0'), ['m1', 'm2', 'm3', 'm4', 'm5']);

  const cyclic = loadDirectory({
    merchants: [
      { slug: 'a', name: 'A', parent_slug: 'b', aliases: [] },
      { slug: 'b', name: 'B', parent_slug: 'c', aliases: [] },
      { slug: 'c', name: 'C', parent_slug: 'a', aliases: [] },
    ],
    platforms: [],
  });
  assert.deepStrictEqual(ancestors(cyclic, 'a'), ['b', 'c']);
  const self = loadDirectory({ merchants: [{ slug: 's', name: 'S', parent_slug: 's', aliases: [] }], platforms: [] });
  assert.deepStrictEqual(ancestors(self, 's'), []);
});

test('the informational "group" key (plan C8 D6) is ignored: siblings are not ancestors', () => {
  const dir = loadDirectory({
    merchants: [
      { slug: 'flipkart', name: 'Flipkart', parent_slug: null, group: 'flipkart', aliases: ['flipkart'] },
      { slug: 'myntra', name: 'Myntra', parent_slug: null, group: 'flipkart', aliases: ['myntra'] },
    ],
    platforms: [],
  });
  assert.strictEqual(resolveMerchant(dir, 'MYNTRA DESIGNS', null).slug, 'myntra');
  assert.deepStrictEqual(ancestors(dir, 'myntra'), []);
});

test('loadDirectory: accepts an already-loaded directory and the checked-in fixture', () => {
  const dir = loadDirectory(DIR_JSON);
  assert.strictEqual(loadDirectory(dir), dir);
  const real = loadDirectory(JSON.parse(fs.readFileSync(path.join(FIXTURES, 'merchant_directory.json'), 'utf8')));
  assert.strictEqual(resolveMerchant(real, 'INSTAMART BLR', null).slug, 'instamart');
  assert.deepStrictEqual(ancestors(real, 'instamart'), ['swiggy']);
});

// ---------------------------------------------------------------------------
// Engine v2 (C3)
// ---------------------------------------------------------------------------

const v1 = require('../src/reward_math');
const {
  isV2Card,
  ruleAppliesV2,
  pickRuleV2,
  applicableCaps,
  accrue,
  computeTransactionRewardV2,
} = require('../src/reward_math_v2');

const SCENARIO_DIR = path.join(FIXTURES, 'reward_v2_scenarios');
const DEFAULT_DIRECTORY = JSON.parse(fs.readFileSync(path.join(FIXTURES, 'merchant_directory.json'), 'utf8'));

/** Half-up to 2 dp, as the contract harness rule says (C8 D12e). */
function money2(value) {
  return Math.round(value * 100 + 1e-6) / 100;
}

/** The actual, rounded to 2 dp half-up, equals the expected exactly; null stays null. */
function assertAmount(actual, expected, label) {
  if (expected === null || expected === undefined) {
    assert.strictEqual(actual, null, `${label}: expected null, got ${actual}`);
    return;
  }
  assert.ok(typeof actual === 'number' && Number.isFinite(actual), `${label}: expected ${expected}, got ${actual}`);
  assert.strictEqual(money2(actual), expected, `${label}: expected ${expected}, got ${actual}`);
}

function assertDeltas(actual, expected, label) {
  const a = Object.keys(actual || {}).sort();
  const e = Object.keys(expected || {}).sort();
  assert.deepStrictEqual(a, e, `${label}: cap ids ${JSON.stringify(actual)} vs expected ${JSON.stringify(expected)}`);
  for (const k of e) assertAmount(actual[k], expected[k], `${label}[${k}]`);
}

function runScenario(scenario, directory) {
  const card = scenario.card;
  return computeTransactionRewardV2({
    card,
    rewardRules: card.reward_rules || [],
    capRules: card.cap_rules || [],
    capConsumedBefore: scenario.cap_consumed_before || {},
    ctx: scenario.ctx,
    directory,
  });
}

const EXPECT_KEYS = ['points', 'cashback_inr', 'value_inr', 'rule_id', 'excluded', 'cap_deltas'];

const scenarioFiles = fs
  .readdirSync(SCENARIO_DIR)
  .filter((f) => f.endsWith('.json'))
  .sort();

test('scenario directory holds the contract file and the JS edge cases', () => {
  assert.ok(scenarioFiles.includes('00_contract.json'));
  assert.ok(scenarioFiles.includes('20_js.json'));
  const js = JSON.parse(fs.readFileSync(path.join(SCENARIO_DIR, '20_js.json'), 'utf8'));
  assert.ok(js.scenarios.length >= 15, `20_js.json has ${js.scenarios.length} scenarios, want >= 15`);
});

for (const file of scenarioFiles) {
  test(`reward_v2_scenarios/${file}`, async (t) => {
    const doc = JSON.parse(fs.readFileSync(path.join(SCENARIO_DIR, file), 'utf8'));
    const directory = loadDirectory(doc.directory || DEFAULT_DIRECTORY);
    assert.ok(Array.isArray(doc.scenarios) && doc.scenarios.length > 0, `${file} has no scenarios`);
    for (const scenario of doc.scenarios) {
      await t.test(scenario.name, () => {
        const r = runScenario(scenario, directory);
        const e = scenario.expect;
        // C8 D10: an optional "assert" list limits which expect keys are compared.
        const keys = Array.isArray(scenario.assert) ? scenario.assert : EXPECT_KEYS;
        for (const key of keys) assert.ok(EXPECT_KEYS.includes(key), `unknown assert key ${key}`);
        if (keys.includes('points')) assertAmount(r.points, e.points, 'points');
        if (keys.includes('cashback_inr')) assertAmount(r.cashbackInr, e.cashback_inr, 'cashback_inr');
        if (keys.includes('value_inr')) assertAmount(r.valueInr, e.value_inr, 'value_inr');
        if (keys.includes('rule_id')) assert.strictEqual(r.ruleId, e.rule_id, 'rule_id');
        if (keys.includes('excluded')) assert.strictEqual(r.excluded, e.excluded, 'excluded');
        if (keys.includes('cap_deltas')) assertDeltas(r.capDeltas, e.cap_deltas, 'cap_deltas');
      });
    }
  });
}

// --- v1 delegation (C3.2) -----------------------------------------------------

test('v1-shaped parity cards delegate to reward_math.js and give identical answers', async (t) => {
  const parity = JSON.parse(fs.readFileSync(path.join(FIXTURES, 'reward_parity_scenarios.json'), 'utf8'));
  for (const scenario of parity.scenarios) {
    await t.test(scenario.name, () => {
      const card = scenario.card;
      const txn = scenario.transaction;
      const ctx = {
        amount: txn.amountInr,
        categoryId: txn.categoryId ?? null,
        merchantName: txn.merchantName ?? null,
        rail: txn.rail ?? 'unknown',
        occurred: txn.occurredAt ? new Date(txn.occurredAt) : null,
      };
      assert.strictEqual(isV2Card(card), false, 'parity cards carry no v2 fields');

      const rule = v1.pickRule(card.reward_rules || [], ctx);
      const capRule = rule ? v1.pickCapRule(card.cap_rules || [], rule, ctx) : null;
      const before = capRule ? (scenario.capConsumedBefore[capRule.id] ?? 0) : 0;
      const expected = v1.computeTransactionReward({
        card,
        rewardRules: card.reward_rules || [],
        capRules: card.cap_rules || [],
        capConsumedBefore: before,
        ctx,
      });

      const r = computeTransactionRewardV2({
        card,
        rewardRules: card.reward_rules || [],
        capRules: card.cap_rules || [],
        capConsumedBefore: scenario.capConsumedBefore,
        ctx,
        directory: DEFAULT_DIRECTORY,
      });

      assert.strictEqual(r.engine, 'v1');
      assert.deepStrictEqual(r.v1, expected, 'raw v1 result is passed through untouched');
      assert.strictEqual(r.valueInr, expected.valueInr);
      // v1's `points` is the native amount: points, or ₹ on a cashback card.
      assert.strictEqual(r.cashbackInr ?? r.points, expected.points);
      assert.ok(r.points === null || r.cashbackInr === null, 'one native field per v1 card');
      assert.strictEqual(r.ruleId, expected.ruleId);
      assert.strictEqual(r.excluded, expected.excluded);
      const wantDeltas = expected.capRuleId && expected.capConsumedDelta !== 0
        ? { [expected.capRuleId]: expected.capConsumedDelta }
        : {};
      assert.deepStrictEqual(r.capDeltas, wantDeltas);
    });
  }
});

test('v1 delegation accepts snake_case ctx too', () => {
  const card = {
    base_reward_unit: 'cashback_percent', base_reward_rate: 1, point_value_inr: 0,
    reward_rules: [{ id: 'r', merchant_pattern: 'amazon', unit: 'cashback_percent', rate: 5, priority: 10 }],
    cap_rules: [],
  };
  const r = computeTransactionRewardV2({
    card, capConsumedBefore: {}, ctx: { amount: 1000, merchant_name: 'AMAZON PAY', rail: 'unknown' },
  });
  assert.strictEqual(r.engine, 'v1');
  assert.strictEqual(r.ruleId, 'r');
  assert.strictEqual(r.cashbackInr, 50);
  assert.strictEqual(r.points, null);
});

// --- isV2Card -----------------------------------------------------------------

test('isV2Card (C8 D10): database defaults alone keep a card on v1', () => {
  const base = { base_reward_unit: 'points_per_100', base_reward_rate: 1 };
  // A post-migration legacy row: rule_role 'earn', empty arrays, engine 1, no cap_kind.
  const legacyRule = {
    id: 'r', rule_role: 'earn', merchant_slugs: [], platform_slugs: [], mcc_include: [], mcc_exclude: [],
    block_inr: null, min_engine_version: 1,
  };
  const legacyCap = { id: 'c', cap_kind: null, scope: 'targets', targets: [], min_engine_version: 1 };
  assert.strictEqual(isV2Card({ ...base, reward_rules: [legacyRule], cap_rules: [legacyCap] }), false);
  assert.strictEqual(isV2Card({ ...base, reward_rules: [{ id: 'r' }], cap_rules: [{ id: 'c' }] }), false);
  assert.strictEqual(isV2Card({ ...base, reward_rules: [{ id: 'r', rule_role: 'earn' }] }), false);
  assert.strictEqual(isV2Card({ ...base, reward_rules: [{ id: 'r', rule_role: null }] }), false);
  assert.strictEqual(isV2Card({ ...base, reward_rules: [{ ...legacyRule, min_engine_version: '1' }] }), false);
  assert.strictEqual(isV2Card({ ...base, accrual_rounding: null, cashback_rounding: null, reward_rules: [legacyRule] }), false);
});

test('isV2Card (C8 D10/D11): each v2 trigger on its own makes the card v2', () => {
  const base = { base_reward_unit: 'points_per_100', base_reward_rate: 1 };
  const legacyRule = { id: 'r', rule_role: 'earn', merchant_slugs: [], platform_slugs: [], mcc_include: [], mcc_exclude: [], block_inr: null, min_engine_version: 1 };
  const withRule = (over) => isV2Card({ ...base, reward_rules: [legacyRule, { ...legacyRule, id: 'r2', ...over }], cap_rules: [] });

  assert.strictEqual(isV2Card({ ...base, accrual_rounding: 'floor', reward_rules: [legacyRule] }), true, 'accrual_rounding');
  assert.strictEqual(isV2Card({ ...base, cashback_rounding: 'paise', reward_rules: [legacyRule] }), true, 'cashback_rounding');
  assert.strictEqual(isV2Card({ ...base, reward_rules: [legacyRule], cap_rules: [{ id: 'c', cap_kind: 'bonus_points' }] }), true, 'cap_kind');
  assert.strictEqual(withRule({ rule_role: 'base' }), true, 'rule_role base');
  assert.strictEqual(withRule({ rule_role: 'exclusion' }), true, 'rule_role exclusion');
  assert.strictEqual(withRule({ rule_role: 'info' }), true, 'rule_role info');
  assert.strictEqual(withRule({ merchant_slugs: ['swiggy'] }), true, 'merchant_slugs');
  assert.strictEqual(withRule({ platform_slugs: ['phonepe_app'] }), true, 'platform_slugs');
  assert.strictEqual(withRule({ mcc_include: ['5411'] }), true, 'mcc_include');
  assert.strictEqual(withRule({ mcc_exclude: ['6540'] }), true, 'mcc_exclude');
  assert.strictEqual(withRule({ block_inr: 150 }), true, 'block_inr');
  assert.strictEqual(withRule({ min_engine_version: 2 }), true, 'min_engine_version 2');
  assert.strictEqual(withRule({ min_engine_version: '2' }), true, "min_engine_version '2' (pg string)");
  // Explicit rule/cap lists override the embedded ones.
  assert.strictEqual(isV2Card({ ...base, reward_rules: [] }, [{ id: 'r', rule_role: 'base' }], []), true);
});

// --- ruleAppliesV2 (C3.3) -------------------------------------------------------

function ctxOf(over) {
  return { amount: 1000, category_id: null, mcc: null, merchant_name: null, merchant_vpa: null,
    merchant_slug: null, platform: null, rail: 'unknown', occurred: null, ...over };
}

test('ruleAppliesV2: info rules never apply, unknown roles never apply', () => {
  assert.strictEqual(ruleAppliesV2({ id: 'i', rule_role: 'info', unit: 'cashback_percent', rate: 5 }, ctxOf({})), false);
  assert.strictEqual(ruleAppliesV2({ id: 'x', rule_role: 'mystery', unit: 'cashback_percent', rate: 5 }, ctxOf({})), false);
  assert.strictEqual(ruleAppliesV2({ id: 'e', rule_role: 'earn', unit: 'cashback_percent', rate: 5 }, ctxOf({})), true);
});

test('ruleAppliesV2: unknown rail does not satisfy a rail restriction', () => {
  const rule = { id: 'r', rule_role: 'earn', rail: 'online', unit: 'cashback_percent', rate: 5 };
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ rail: 'unknown' })), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ rail: null })), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ rail: 'swipe' })), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ rail: 'online' })), true);
});

test('ruleAppliesV2: merchant slugs match the resolved merchant or an ancestor', () => {
  const dir = loadDirectory(DIR_JSON);
  const rule = { id: 'r', rule_role: 'earn', merchant_slugs: ['swiggy'], unit: 'cashback_percent', rate: 10 };
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_name: 'INSTAMART' }), dir), true);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_slug: 'instamart' }), dir), true);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_name: 'Zomato' }), dir), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_name: null }), dir), false);
  // Without a directory only an explicit slug can match.
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_slug: 'swiggy' })), true);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_name: 'Swiggy' })), false);
});

test('ruleAppliesV2: a v2 rule with only a legacy merchant_pattern still restricts (never widen)', () => {
  const rule = { id: 'r', rule_role: 'earn', merchant_slugs: [], merchant_pattern: 'amazon', unit: 'cashback_percent', rate: 5 };
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_name: 'AMAZON PAY INDIA' })), true);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_name: 'Flipkart' })), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_name: null })), false);
});

test('ruleAppliesV2: merchant_slugs take precedence over the v1 merchant_pattern projection', () => {
  const dir = loadDirectory(DIR_JSON);
  const rule = { id: 'r', rule_role: 'earn', merchant_slugs: ['swiggy'], merchant_pattern: 'swiggy', unit: 'cashback_percent', rate: 10 };
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ merchant_name: 'BUNDL TECHNOLOGIES' }), dir), true);
});

test('ruleAppliesV2: platform must be given by the caller and be in the set', () => {
  const rule = { id: 'r', rule_role: 'earn', platform_slugs: ['phonepe_app', 'hdfc_smartbuy'], unit: 'points_per_100', rate: 10 };
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ platform: 'hdfc_smartbuy' })), true);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ platform: null, merchant_name: 'PhonePe recharge' })), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ platform: 'gpay' })), false);
});

test('ruleAppliesV2: mcc_include, category stand-in for unknown MCC, mcc_exclude', () => {
  const inc = { id: 'r', rule_role: 'earn', mcc_include: ['5411', '5499'], unit: 'cashback_percent', rate: 5 };
  assert.strictEqual(ruleAppliesV2(inc, ctxOf({ mcc: '5411' })), true);
  assert.strictEqual(ruleAppliesV2(inc, ctxOf({ mcc: '5812' })), false);
  assert.strictEqual(ruleAppliesV2(inc, ctxOf({ mcc: null })), false);

  const withCat = { ...inc, category_id: 'cat-groc' };
  assert.strictEqual(ruleAppliesV2(withCat, ctxOf({ mcc: null, category_id: 'cat-groc' })), true);
  assert.strictEqual(ruleAppliesV2(withCat, ctxOf({ mcc: null, category_id: 'cat-dining' })), false);
  // A known MCC outside the set fails even when the category matches.
  assert.strictEqual(ruleAppliesV2(withCat, ctxOf({ mcc: '5812', category_id: 'cat-groc' })), false);

  const exc = { id: 'r', rule_role: 'earn', mcc_exclude: ['6540'], unit: 'cashback_percent', rate: 5 };
  assert.strictEqual(ruleAppliesV2(exc, ctxOf({ mcc: '6540' })), false);
  assert.strictEqual(ruleAppliesV2(exc, ctxOf({ mcc: null })), true);
  assert.strictEqual(ruleAppliesV2(exc, ctxOf({ mcc: '5411' })), true);
});

test('ruleAppliesV2: category, rule-level exclusions, min_txn and validity window', () => {
  const rule = { id: 'r', rule_role: 'earn', category_id: 'cat-a', min_txn_inr: 500, excluded_categories: ['cat-b'],
    effective_from: '2026-01-01', effective_to: '2026-03-31', unit: 'cashback_percent', rate: 5 };
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ category_id: 'cat-a', amount: 500, occurred: new Date(2026, 2, 31, 23, 0) })), true);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ category_id: 'cat-a', amount: 499.99 })), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ category_id: 'cat-x' })), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ category_id: 'cat-a', occurred: new Date(2026, 3, 1, 0, 1) })), false);
  assert.strictEqual(ruleAppliesV2(rule, ctxOf({ category_id: 'cat-a', occurred: new Date(2025, 11, 31, 12, 0) })), false);
  const anyCat = { id: 'r2', rule_role: 'earn', excluded_categories: ['cat-b'], unit: 'cashback_percent', rate: 5 };
  assert.strictEqual(ruleAppliesV2(anyCat, ctxOf({ category_id: 'cat-b' })), false);
  assert.strictEqual(ruleAppliesV2(anyCat, ctxOf({ category_id: 'cat-c' })), true);
});

// --- pickRuleV2 (C3.4) ----------------------------------------------------------

test('pickRuleV2: exclusion beats earn; card-level exclusion has no rule id', () => {
  const card = { base_reward_unit: 'cashback_percent', base_reward_rate: 1, point_value_inr: 0, excluded_categories: ['cat-rent'] };
  const rules = [
    { id: 'earn', rule_role: 'earn', priority: 1, unit: 'cashback_percent', rate: 5 },
    { id: 'excl', rule_role: 'exclusion', priority: 50, mcc_include: ['6540'], unit: 'cashback_percent', rate: 0 },
  ];
  const wallet = pickRuleV2(rules, ctxOf({ mcc: '6540' }), card);
  assert.strictEqual(wallet.excluded, true);
  assert.strictEqual(wallet.rule.id, 'excl');
  const cardLevel = pickRuleV2(rules, ctxOf({ category_id: 'cat-rent' }), card);
  assert.strictEqual(cardLevel.excluded, true);
  assert.strictEqual(cardLevel.rule, null);
  const earn = pickRuleV2(rules, ctxOf({}), card);
  assert.strictEqual(earn.excluded, false);
  assert.strictEqual(earn.rule.id, 'earn');
});

test('pickRuleV2: priority tie goes to the higher effective rupee-per-rupee rate', () => {
  const card = { base_reward_unit: 'points_per_100', base_reward_rate: 1, point_value_inr: 0.5 };
  const rules = [
    { id: 'pts', rule_role: 'earn', priority: 10, unit: 'points_per_100', rate: 8 }, // 4%
    { id: 'blk', rule_role: 'earn', priority: 10, unit: 'points_per_100', rate: 10, block_inr: 150 }, // 3.33%
    { id: 'cb', rule_role: 'earn', priority: 10, unit: 'cashback_percent', rate: 5 }, // 5%
  ];
  assert.strictEqual(pickRuleV2(rules, ctxOf({}), card).rule.id, 'cb');
  assert.strictEqual(pickRuleV2(rules.slice(0, 2), ctxOf({}), card).rule.id, 'pts');
});

test('pickRuleV2: nothing applicable gives the implicit base rule (id null)', () => {
  const card = { base_reward_unit: 'points_per_100', base_reward_rate: 1, point_value_inr: 0.5 };
  const r = pickRuleV2([{ id: 'x', rule_role: 'earn', rail: 'online', unit: 'points_per_100', rate: 5 }], ctxOf({}), card);
  assert.strictEqual(r.excluded, false);
  assert.strictEqual(r.rule.id, null);
  assert.strictEqual(r.rule.unit, 'points_per_100');
  assert.strictEqual(r.implicit, true);
});

// --- applicableCaps (C3.6) ------------------------------------------------------

test('applicableCaps: targets, card scope, legacy fallbacks and parent chain (deduplicated)', () => {
  const card = { base_reward_unit: 'points_per_100', base_reward_rate: 1, point_value_inr: 0.25 };
  const rule = { id: 'r1', rule_role: 'earn', unit: 'points_per_100', rate: 10 };
  const caps = [
    { id: 'child', cap_kind: 'bonus_points', cap_amount: 500, scope: 'targets', targets: ['r1'], parent_cap_id: 'parent' },
    { id: 'parent', cap_kind: 'bonus_points', cap_amount: 800, scope: 'targets', targets: ['r9'], parent_cap_id: 'grand' },
    { id: 'grand', cap_kind: 'total_points', cap_amount: 5000, scope: 'targets', targets: [], parent_cap_id: 'child' },
    { id: 'other', cap_kind: 'bonus_points', cap_amount: 100, scope: 'targets', targets: ['r2'] },
    { id: 'cardwide', cap_kind: 'total_points', cap_amount: 9000, scope: 'card', targets: [] },
    { id: 'legacy-rule', cap_kind: null, reward_rule_id: 'r1', category_id: null, measure: 'reward_value', cap_value: 50 },
    { id: 'legacy-cat', cap_kind: null, reward_rule_id: null, category_id: 'cat-a', measure: 'spend_amount', cap_value: 3000 },
    { id: 'orphan', cap_kind: null, reward_rule_id: null, category_id: null, measure: 'spend_amount', cap_value: 3000 },
  ];
  const got = applicableCaps({ card, capRules: caps, rule, ctx: ctxOf({ category_id: 'cat-a' }) });
  assert.deepStrictEqual(got.map((c) => c.id).sort(), ['cardwide', 'child', 'grand', 'legacy-cat', 'legacy-rule', 'parent']);
  const byId = Object.fromEntries(got.map((c) => [c.id, c]));
  assert.strictEqual(byId['legacy-rule'].kind, 'total_points');
  assert.strictEqual(byId['legacy-rule'].amount, 200); // ₹50 / ₹0.25 per point
  assert.strictEqual(byId['legacy-cat'].kind, 'eligible_spend');
  assert.strictEqual(byId['legacy-cat'].amount, 3000);
});

test('applicableCaps: never for excluded spends', () => {
  const card = { base_reward_unit: 'points_per_100', base_reward_rate: 1, point_value_inr: 0.25 };
  const caps = [{ id: 'cardwide', cap_kind: 'total_points', cap_amount: 9000, scope: 'card', targets: [] }];
  assert.deepStrictEqual(applicableCaps({ card, capRules: caps, rule: null, ctx: ctxOf({}), excluded: true }), []);
});

test('applicableCaps: legacy conversion by the rule currency; a points value cap needs a point value', () => {
  const rule = { id: 'r1', rule_role: 'earn', unit: 'cashback_percent', rate: 5 };
  const caps = [
    { id: 'cb', cap_kind: null, reward_rule_id: 'r1', measure: 'reward_value', cap_value: 300 },
    { id: 'cnt', cap_kind: null, reward_rule_id: 'r1', measure: 'txn_count', cap_value: 4 },
  ];
  const card = { base_reward_unit: 'cashback_percent', base_reward_rate: 1, point_value_inr: 0 };
  const got = applicableCaps({ card, capRules: caps, rule, ctx: ctxOf({}) });
  assert.deepStrictEqual(got.map((c) => [c.id, c.kind, c.amount]), [['cb', 'total_cashback', 300], ['cnt', 'txn_count', 4]]);

  const ptsRule = { id: 'r1', rule_role: 'earn', unit: 'points_per_100', rate: 5 };
  const zeroPv = applicableCaps({ card: { ...card, base_reward_unit: 'points_per_100' }, capRules: caps.slice(0, 1), rule: ptsRule, ctx: ctxOf({}) });
  assert.deepStrictEqual(zeroPv, []);
});

test('applicableCaps: unknown kind / scope / behaviour and a missing amount are skipped with a reason (D12d)', () => {
  const card = { base_reward_unit: 'points_per_100', base_reward_rate: 1, point_value_inr: 0 };
  const rule = { id: 'r1', rule_role: 'earn', unit: 'points_per_100', rate: 10 };
  const caps = [
    { id: 'weird-kind', cap_kind: 'daily_points', cap_amount: 10, scope: 'card' },
    { id: 'weird-scope', cap_kind: 'total_points', cap_amount: 10, scope: 'galaxy' },
    { id: 'no-amount', cap_kind: 'bonus_points', cap_amount: null, scope: 'targets', targets: ['r1'] },
    { id: 'weird-behaviour', cap_kind: 'eligible_spend', cap_amount: 100, scope: 'targets', targets: ['r1'], post_cap_behavior: 'mystery' },
    { id: 'pv-zero', cap_kind: null, reward_rule_id: 'r1', measure: 'reward_value', cap_value: 50 },
    { id: 'not-mine', cap_kind: 'daily_points', cap_amount: 10, scope: 'targets', targets: ['r2'] },
  ];
  const skipped = [];
  assert.deepStrictEqual(applicableCaps({ card, capRules: caps, rule, ctx: ctxOf({}), skipped }), []);
  assert.deepStrictEqual(skipped.sort(), [
    'cap_skipped:no-amount:missing_cap_amount',
    'cap_skipped:pv-zero:no_point_value',
    'cap_skipped:weird-behaviour:unknown_post_cap_behavior',
    'cap_skipped:weird-kind:unknown_cap_kind',
    'cap_skipped:weird-scope:unknown_scope',
  ]);
});

test('compute: skipped caps are reported in reasons and constrain nothing', () => {
  const card = pointsCard({
    reward_rules: [{ id: 'r', rule_role: 'earn', category_id: 'cat-d', unit: 'points_per_100', rate: 10, priority: 10 }],
    cap_rules: [{ id: 'bad', cap_kind: 'bonus_points', cap_amount: null, scope: 'targets', targets: ['r'] }],
  });
  const r = computeTransactionRewardV2({ card, capConsumedBefore: {}, ctx: ctxOf({ amount: 1000, category_id: 'cat-d' }) });
  assert.strictEqual(r.points, 100);
  assert.deepStrictEqual(r.capDeltas, {});
  assert.ok(r.reasons.includes('cap_skipped:bad:missing_cap_amount'));
});

// --- accrue (C3.5 + C8 D7) ------------------------------------------------------

test('accrue: block modes round the number of blocks', () => {
  assert.strictEqual(accrue('points_per_100', 5, 199, null, 'floor'), 5);
  assert.strictEqual(accrue('points_per_200', 2, 300, null, 'round'), 4); // 1.5 blocks → 2
  assert.strictEqual(accrue('points_per_200', 2, 299.99, null, 'round'), 2); // 1.49995 → 1
  assert.strictEqual(accrue('points_per_100', 3, 250, null, 'none'), 7.5);
  assert.strictEqual(accrue('points_per_100', 5, 1000, 150, 'floor'), 30); // block_inr override
  // Unknown/null rounding on a v2 card is floor.
  assert.strictEqual(accrue('points_per_100', 1, 199.99, null, undefined), 1);
});

test('accrue: points_half_up / points_floor round the whole product exactly (D7)', () => {
  assert.strictEqual(accrue('points_per_100', 1.5, 7500, null, 'points_half_up'), 113); // 112.5
  assert.strictEqual(accrue('points_per_100', 1.5, 7499, null, 'points_half_up'), 112); // 112.485
  assert.strictEqual(accrue('points_per_100', 1.5, 199, null, 'points_floor'), 2); // 2.985
  // In doubles 3000 × 1.15 / 100 is 34.49999999999999; exactly it is 34.5.
  assert.ok(3000 * 1.15 / 100 < 34.5);
  assert.strictEqual(accrue('points_per_100', 1.15, 3000, null, 'points_half_up'), 35);
  assert.strictEqual(accrue('points_per_100', 4.35, 7000, null, 'points_half_up'), 305); // 304.5
  assert.strictEqual(accrue('points_per_100', 0.3, 50, null, 'points_half_up'), 0); // 0.15
  assert.strictEqual(accrue('points_per_100', 1.1, 4500, null, 'points_half_up'), 50); // 49.5 exactly
  assert.strictEqual(accrue('points_per_150', 2, 112.5, null, 'points_half_up'), 2); // 1.5
  assert.strictEqual(accrue('points_per_100', 1.5, 7500.5, null, 'points_floor'), 112);
});

test('accrue: cashback to paise, flat once, unusable inputs earn nothing', () => {
  assert.strictEqual(accrue('cashback_percent', 5, 333, null, 'floor'), 16.65);
  assert.strictEqual(accrue('flat_points', 500, 1, null, 'floor'), 500);
  assert.strictEqual(accrue('flat_points', 500, 0, null, 'floor'), 0);
  assert.strictEqual(accrue(null, 5, 100, null, 'floor'), 0);
  assert.strictEqual(accrue('points_per_100', null, 100, null, 'floor'), 0);
  assert.strictEqual(accrue('mystery_unit', 5, 100, null, 'floor'), 0);
});

test('accrue: cashback_rounding pays paise or whole rupees per piece (D11)', () => {
  assert.strictEqual(accrue('cashback_percent', 5, 2999, null, 'floor', null), 149.95);
  assert.strictEqual(accrue('cashback_percent', 5, 2999, null, 'floor', 'paise'), 149.95);
  assert.strictEqual(accrue('cashback_percent', 5, 2999, null, 'floor', 'rupee_floor'), 149);
  assert.strictEqual(accrue('cashback_percent', 5, 2999, null, 'floor', 'rupee_half_up'), 150);
  assert.strictEqual(accrue('cashback_percent', 5, 2990, null, 'floor', 'rupee_half_up'), 150); // 149.5
  assert.strictEqual(accrue('cashback_percent', 5, 2989.9, null, 'floor', 'rupee_half_up'), 149); // 149.495
  assert.strictEqual(accrue('cashback_percent', 1.5, 67, null, 'floor', null), 1.01); // 1.005 → paise half-up
  // Points rounding is untouched by cashback_rounding.
  assert.strictEqual(accrue('points_per_100', 1.5, 7500, null, 'points_half_up', 'rupee_floor'), 113);
});

test('compute: a rule paying less than the base earns its own rate (D12a)', () => {
  const card = pointsCard({
    base_reward_rate: 2,
    reward_rules: [{ id: 'low', rule_role: 'earn', category_id: 'cat-bills', unit: 'points_per_100', rate: 1, priority: 10 }],
    cap_rules: [{ id: 'bonus', cap_kind: 'bonus_points', cap_amount: 1000, scope: 'card' }],
  });
  const r = computeTransactionRewardV2({ card, capConsumedBefore: {}, ctx: ctxOf({ amount: 1000, category_id: 'cat-bills' }) });
  assert.strictEqual(r.points, 10);
  assert.deepStrictEqual(r.capDeltas, {});
});

test('compute: custom_rate overflow without post_cap_unit uses the rule unit and its block_inr (D12b)', () => {
  const card = pointsCard({
    point_value_inr: 0.5,
    reward_rules: [{ id: 'p', rule_role: 'earn', category_id: 'cat-t', unit: 'points_per_100', rate: 5, block_inr: 150, priority: 10 }],
    cap_rules: [{ id: 'cap', cap_kind: 'eligible_spend', cap_amount: 3000, scope: 'targets', targets: ['p'],
      post_cap_behavior: 'custom_rate', post_cap_unit: null, post_cap_rate: 2 }],
  });
  // ₹600 headroom: 4 blocks of ₹150 x 5 = 20 (base 6 + bonus 14); ₹900 overflow: 6 blocks x 2 = 12.
  const r = computeTransactionRewardV2({ card, capConsumedBefore: { cap: 2400 }, ctx: ctxOf({ amount: 1500, category_id: 'cat-t' }) });
  assert.strictEqual(r.points, 32);
  assert.deepStrictEqual(r.capDeltas, { cap: 600 });
  // With an explicit post_cap_unit the overflow uses that unit's own block.
  card.cap_rules[0].post_cap_unit = 'points_per_100';
  const r2 = computeTransactionRewardV2({ card, capConsumedBefore: { cap: 2400 }, ctx: ctxOf({ amount: 1500, category_id: 'cat-t' }) });
  assert.strictEqual(r2.points, 38); // 20 + floor(900/100) x 2
});

test('pickRuleV2: ties compare this transaction\'s pre-cap value, then rule id (D12c)', () => {
  const card = { base_reward_unit: 'points_per_100', base_reward_rate: 1, point_value_inr: 0.25, accrual_rounding: 'floor' };
  const flat = { id: 'z-flat', rule_role: 'earn', priority: 10, unit: 'flat_points', rate: 100 }; // ₹25
  const rate = { id: 'a-rate', rule_role: 'earn', priority: 10, unit: 'points_per_100', rate: 2 }; // 40 pts = ₹10 on ₹2,000
  assert.strictEqual(pickRuleV2([rate, flat], ctxOf({ amount: 2000 }), card).rule.id, 'z-flat');
  assert.strictEqual(pickRuleV2([rate, flat], ctxOf({ amount: 6000 }), card).rule.id, 'a-rate'); // 120 pts = ₹30
  const twin = { ...rate, id: 'b-rate' };
  assert.strictEqual(pickRuleV2([twin, rate], ctxOf({ amount: 1000 }), card).rule.id, 'a-rate');
});

// --- computeTransactionRewardV2: details outside the shared scenarios ----------

function pointsCard(over = {}) {
  return {
    id: 'p', point_value_inr: 0.25, base_reward_unit: 'points_per_100', base_reward_rate: 1,
    accrual_rounding: 'floor', excluded_categories: [], reward_rules: [], cap_rules: [], ...over,
  };
}

test('compute: non-positive or non-finite amounts earn nothing and consume nothing', () => {
  for (const amount of [0, -100, Number.NaN]) {
    const r = computeTransactionRewardV2({ card: pointsCard(), capConsumedBefore: {}, ctx: ctxOf({ amount }) });
    assert.strictEqual(r.points, 0);
    assert.strictEqual(r.cashbackInr, null);
    assert.strictEqual(r.valueInr, 0);
    assert.deepStrictEqual(r.capDeltas, {});
    assert.strictEqual(r.excluded, false);
  }
});

test('compute: a card with no base rate earns nothing on the implicit base path', () => {
  const card = pointsCard({ base_reward_unit: null, base_reward_rate: null });
  const r = computeTransactionRewardV2({ card, capConsumedBefore: {}, ctx: ctxOf({ amount: 1000 }) });
  assert.strictEqual(r.valueInr, 0);
  assert.strictEqual(r.ruleId, null);
});

test('compute: records how the merchant was resolved in assumptions', () => {
  const card = pointsCard({
    reward_rules: [{ id: 'sw', rule_role: 'earn', merchant_slugs: ['swiggy'], unit: 'points_per_100', rate: 5, priority: 10 }],
  });
  const viaAlias = computeTransactionRewardV2({ card, capConsumedBefore: {}, ctx: ctxOf({ merchant_name: 'Instamart' }), directory: DIR_JSON });
  assert.strictEqual(viaAlias.ruleId, 'sw');
  assert.ok(viaAlias.assumptions.includes('merchant_resolved_by_alias'));
  const viaVpa = computeTransactionRewardV2({ card, capConsumedBefore: {}, ctx: ctxOf({ merchant_vpa: 'swiggy.pay@icici' }), directory: DIR_JSON });
  assert.ok(viaVpa.assumptions.includes('merchant_resolved_by_vpa'));
});

test('compute: exclusion reason comes from display_note', () => {
  const card = pointsCard({
    reward_rules: [{ id: 'x', rule_role: 'exclusion', category_id: 'cat-fuel', unit: 'points_per_100', rate: 0, display_note: 'No points on fuel' }],
  });
  const r = computeTransactionRewardV2({ card, capConsumedBefore: {}, ctx: ctxOf({ category_id: 'cat-fuel' }) });
  assert.strictEqual(r.excluded, true);
  assert.deepStrictEqual(r.reasons, ['No points on fuel']);
});

test('compute: cashback rounds half-up to paise without float drift', () => {
  const card = { id: 'c', point_value_inr: 0, base_reward_unit: 'cashback_percent', base_reward_rate: 1.5,
    accrual_rounding: null, excluded_categories: [], reward_rules: [{ id: 'b', rule_role: 'base', unit: 'cashback_percent', rate: 1.5 }], cap_rules: [] };
  // 1.5% of ₹67 = ₹1.005 → ₹1.01 (half-up), not ₹1.00 from binary float error.
  const r = computeTransactionRewardV2({ card, capConsumedBefore: {}, ctx: ctxOf({ amount: 67 }) });
  assert.strictEqual(r.cashbackInr, 1.01);
  assert.strictEqual(r.valueInr, 1.01);
});

test('compute: with no post_cap_behavior, a legacy post_cap_rate of 0 means zero past an eligible-spend cap', () => {
  const card = { id: 'c', point_value_inr: 0, base_reward_unit: 'cashback_percent', base_reward_rate: 1,
    excluded_categories: [], cap_rules: [
      { id: 'cap', cap_kind: 'eligible_spend', cap_amount: 1000, scope: 'targets', targets: ['g'], post_cap_behavior: null, post_cap_rate: 0 },
    ],
    reward_rules: [{ id: 'g', rule_role: 'earn', category_id: 'cat-g', unit: 'cashback_percent', rate: 5, priority: 10 }] };
  const r = computeTransactionRewardV2({ card, capConsumedBefore: { cap: 500 }, ctx: ctxOf({ amount: 1000, category_id: 'cat-g' }) });
  assert.strictEqual(r.cashbackInr, 25);
  assert.deepStrictEqual(r.capDeltas, { cap: 500 });
});

test('compute: a base-role rule earns at its own rate with no bonus', () => {
  const card = pointsCard({
    base_reward_rate: 1,
    reward_rules: [{ id: 'b', rule_role: 'base', unit: 'points_per_100', rate: 2, priority: 30 }],
    cap_rules: [{ id: 'bonus', cap_kind: 'bonus_points', cap_amount: 1000, scope: 'card', targets: [] }],
  });
  const r = computeTransactionRewardV2({ card, capConsumedBefore: {}, ctx: ctxOf({ amount: 1000 }) });
  assert.strictEqual(r.points, 20);
  assert.deepStrictEqual(r.capDeltas, {});
});

test('compute: consumed values may arrive as numeric strings from pg', () => {
  const card = pointsCard({
    reward_rules: [{ id: 'r', rule_role: 'earn', platform_slugs: ['phonepe_app'], unit: 'points_per_100', rate: 10, priority: 10 }],
    cap_rules: [{ id: 'cap', cap_kind: 'bonus_points', cap_amount: '1500.00', scope: 'targets', targets: ['r'] }],
  });
  const r = computeTransactionRewardV2({ card, capConsumedBefore: { cap: '1450.00' }, ctx: ctxOf({ amount: 2000, platform: 'phonepe_app' }) });
  assert.strictEqual(r.points, 70);
  assert.deepStrictEqual(r.capDeltas, { cap: 50 });
});
