// audit_catalogue.js (plan C7.11): R1–R9 metrics on v1 and v2 feed shapes.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { audit, valuePerRupee } = require('../scripts/audit_catalogue');
const { transformCardRecordV2 } = require('../scripts/catalogue_v2/transform');
const { toV2WireCard } = require('../scripts/catalogue_v2/wire');
const { loadDirectory } = require('../scripts/catalogue_v2/directory');

const directory = {
  merchants: [{ slug: 'swiggy', name: 'Swiggy', aliases: ['swiggy'] }],
  platforms: [{ slug: 'phonepe_app', name: 'PhonePe app', kind: 'payment_app', aliases: ['phonepe'] }],
};

test('valuePerRupee: cashback, points per block, block_inr', () => {
  assert.equal(valuePerRupee('cashback_percent', 5, null), 0.05);
  assert.equal(valuePerRupee('points_per_100', 10, 0.25), 0.025);
  assert.equal(valuePerRupee('points_per_100', 3, 0.4, 50), 0.024);
});

test('v1 feed: unlinked caps, post-cap zero, anniversary milestones, missing co-brand rule, widened bonus', () => {
  const v1 = {
    cards: [{
      id: 'c1', name: 'Swiggy Test Credit Card', base_reward_unit: 'cashback_percent', base_reward_rate: 1, point_value_inr: null,
      reward_rules: [
        { id: 'r1', category_id: null, merchant_pattern: null, rail: null, unit: 'cashback_percent', rate: 5, min_txn_inr: null, conditions: { source_conditions: { app: 'PhonePe' } } },
      ],
      cap_rules: [
        { id: 'k1', reward_rule_id: null, category_id: null, measure: 'reward_value', cap_value: 500, post_cap_rate: 0 },
        { id: 'k2', reward_rule_id: 'r1', category_id: null, measure: 'spend_amount', cap_value: 1500, post_cap_rate: null },
      ],
      milestone_rules: [
        { period: 'quarter', anchor: 'card_anniversary' },
        { period: 'annual', anchor: 'card_anniversary' },
      ],
      benefits: [{ id: 'b1', kind: 'lounge_domestic', conditions: { evaluation_engine: { conditions: { previous_quarter_spend_inr: 50000 } } } }],
    }],
  };
  const m = audit(v1, directory);
  assert.equal(m.feed, 'v1');
  assert.deepEqual(m.r1_cobrand, { cobrand_cards: 1, without_merchant_rule: 1 });
  assert.deepEqual(m.r2_unrestricted_bonus, { rules: 1, cards: 1 });
  assert.equal(m.r3_caps.linked_to_nothing, 1);
  assert.equal(m.r4_post_cap_zero.caps_post_zero, 1);
  assert.equal(m.r4_post_cap_zero.bonus_caps_zeroing_base, 1);
  assert.equal(m.r5_cap_units.suspect_spend_caps, 1);
  assert.deepEqual([m.r6_milestones.anchor_card_anniversary, m.r6_milestones.non_annual_on_card_anniversary], [2, 1]);
  assert.equal(m.r7_spend_gated_benefits.lounge_with_spend_text, 1);
  assert.equal(m.r8_platform_rules.rules_mentioning_app_or_portal, 1);
  assert.deepEqual(m.r9_rounding, { points_cards: 0, with_rounding: 0 });
});

test('the loader preview of real records reads as a v2 feed with structured rules', () => {
  const fixtures = path.join(__dirname, 'fixtures', 'cardpipeline');
  const dir = loadDirectory();
  const cards = fs.readdirSync(fixtures).filter((f) => f.endsWith('.json')).map((f) => {
    const { final } = JSON.parse(fs.readFileSync(path.join(fixtures, f), 'utf8'));
    return toV2WireCard(transformCardRecordV2(final, { directory: dir }));
  });
  const m = audit({ schema: 2, preview: true, cards, merchants: dir.merchants, platforms: dir.platforms }, dir);
  assert.equal(m.feed, 'v2-preview');
  assert.equal(m.cards_v2_shaped, cards.length);
  assert.equal(m.r6_milestones.non_annual_on_card_anniversary, 0);
  assert.equal(m.r4_post_cap_zero.bonus_caps_zeroing_base, 0);
  assert.ok(m.r8_platform_rules.rules_with_platform > 0);
  assert.equal(m.r9_rounding.with_rounding, m.r9_rounding.points_cards);
  assert.ok(m.r7_spend_gated_benefits.unlock_rules > 0);
});
