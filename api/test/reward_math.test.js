const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const {
  ruleApplies,
  pickRule,
  pickCapRule,
  resolvePostCap,
  computeTransactionReward,
} = require('../src/reward_math');

/**
 * The JS half of the cross-implementation parity suite. Its Dart twin is
 * packages/pandapay_domain/test/reward_parity_test.dart, and both read the
 * SAME fixture file — see db/fixtures/reward_parity_scenarios.json for why
 * that matters (short version: the two implementations drifted, and both
 * drifts became wrong money on a user's screen).
 */
const fixturePath = path.join(__dirname, '..', '..', 'db', 'fixtures', 'reward_parity_scenarios.json');
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));

/** Rupees compare to the paise the Dart side rounds to. */
function assertMoneyClose(actual, expected, label) {
  assert.ok(
    Math.abs(actual - expected) < 0.005,
    `${label}: expected ${expected}, got ${actual}`
  );
}

test('parity fixture: every scenario computes the agreed value, points and cap consumption', async (t) => {
  for (const scenario of fixture.scenarios) {
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

      // The cap the engine would pick, so the fixture's capConsumedBefore
      // map can be keyed by cap-rule id the way cap_states is.
      const rule = pickRule(card.reward_rules || [], ctx);
      const capRule = rule ? pickCapRule(card.cap_rules || [], rule, ctx) : null;
      const consumedBefore = capRule ? (scenario.capConsumedBefore[capRule.id] ?? 0) : 0;

      const result = computeTransactionReward({
        card,
        rewardRules: card.reward_rules || [],
        capRules: card.cap_rules || [],
        capConsumedBefore: consumedBefore,
        ctx,
      });

      assertMoneyClose(result.valueInr, scenario.expected.valueInr, 'valueInr');
      assertMoneyClose(result.points, scenario.expected.points, 'points');
      assertMoneyClose(result.capConsumedDelta, scenario.expected.capConsumedDelta, 'capConsumedDelta');
      if (scenario.expected.excluded !== undefined) {
        assert.strictEqual(result.excluded, scenario.expected.excluded, 'excluded');
      }
    });
  }
});

test('ruleApplies: an unknown merchant cannot satisfy a merchant restriction', () => {
  const rule = { id: 'r', merchant_pattern: 'amazon', unit: 'cashback_percent', rate: 10 };
  assert.strictEqual(ruleApplies(rule, { amount: 100, merchantName: null }), false);
  assert.strictEqual(ruleApplies(rule, { amount: 100, merchantName: 'Amazon Pay' }), true);
});

test('ruleApplies: an unknown rail is unverified, not a mismatch', () => {
  // Every SMS/email import lands with rail unknown; failing the match there
  // would under-report the earn rate on all imported spend.
  const rule = { id: 'r', rail: 'swipe', unit: 'cashback_percent', rate: 10 };
  assert.strictEqual(ruleApplies(rule, { amount: 100, rail: 'unknown' }), true);
  assert.strictEqual(ruleApplies(rule, { amount: 100, rail: 'upi_qr' }), false);
  assert.strictEqual(ruleApplies(rule, { amount: 100, rail: 'swipe' }), true);
});

test('ruleApplies: effective_to is inclusive of its whole final day', () => {
  const rule = { id: 'r', effective_to: '2026-03-31', unit: 'cashback_percent', rate: 10 };
  assert.strictEqual(ruleApplies(rule, { amount: 100, occurred: new Date(2026, 2, 31, 23, 59) }), true);
  assert.strictEqual(ruleApplies(rule, { amount: 100, occurred: new Date(2026, 3, 1, 0, 1) }), false);
});

test('ruleApplies: omitting `occurred` ignores validity windows rather than dropping the rule', () => {
  const rule = { id: 'r', effective_to: '2020-01-01', unit: 'cashback_percent', rate: 10 };
  assert.strictEqual(ruleApplies(rule, { amount: 100 }), true);
});

test('pickRule: lowest priority number wins among applicable rules', () => {
  const rules = [
    { id: 'lo', unit: 'cashback_percent', rate: 1, priority: 100 },
    { id: 'hi', unit: 'cashback_percent', rate: 5, priority: 10 },
  ];
  assert.strictEqual(pickRule(rules, { amount: 100 }).id, 'hi');
});

test('pickCapRule: NULL on both keys is not a wildcard', () => {
  const rule = { id: 'r' };
  const orphan = { id: 'orphan', reward_rule_id: null, category_id: null };
  assert.strictEqual(pickCapRule([orphan], rule, { categoryId: 'anything' }), null);
});

test('resolvePostCap: null rate resolves to the card base rate, explicit 0 stays 0', () => {
  const card = { base_reward_unit: 'cashback_percent', base_reward_rate: 1, point_value_inr: 0 };
  const rule = { unit: 'cashback_percent', rate: 10 };

  const implicit = resolvePostCap({ post_cap_rate: null, post_cap_unit: null }, rule, card);
  assert.strictEqual(implicit.unit, 'cashback_percent');
  assert.strictEqual(implicit.rate, 1);

  const explicit = resolvePostCap({ post_cap_rate: 0, post_cap_unit: 'cashback_percent' }, rule, card);
  assert.strictEqual(explicit.rate, 0);
});

test('resolvePostCap: a rate given without a unit is read in the rule\'s own unit', () => {
  const card = { base_reward_unit: 'cashback_percent', base_reward_rate: 1, point_value_inr: 0 };
  const rule = { unit: 'points_per_100', rate: 10 };
  const resolved = resolvePostCap({ post_cap_rate: 2, post_cap_unit: null }, rule, card);
  assert.strictEqual(resolved.unit, 'points_per_100');
  assert.strictEqual(resolved.rate, 2);
});

test('a card with no base rate stated earns nothing on the fallback path', () => {
  // The engine must not invent a rate the catalogue never gave it.
  const card = { base_reward_unit: null, base_reward_rate: null, point_value_inr: 0 };
  const result = computeTransactionReward({
    card,
    rewardRules: [],
    capRules: [],
    capConsumedBefore: 0,
    ctx: { amount: 1000, categoryId: 'anything' },
  });
  assert.strictEqual(result.valueInr, 0);
});
