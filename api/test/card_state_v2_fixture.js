'use strict';

// Synthetic v2 card shared by the WP8 tests (pure and Postgres-backed).
// No real card, issuer data or personal data: every id is made up.
//
//   base           1 pt / ₹100 (points_per_100), ₹0.25 a point, floor rounding
//   dining 5X      earn, category dining                → bonus cap (1,000 pts / month)
//   swiggy 10X     earn, merchant_slugs [swiggy]        → eligible-spend cap (₹20,000 / month, then base)
//   wallet         exclusion, category wallet
//   parent total   2,500 pts / month, parent of the bonus and eligible-spend caps
//   card-year      total 6,000 pts per card year (card scope, card_anniversary)
//   swiggy count   2 transactions / month on the swiggy rule (post-cap: zero)
//   welcome        ₹15,000 within 90 days (window_days)
//   annual         ₹1,00,000 per calendar year, rent excluded

const CATEGORY = {
  dining: '00000000-0000-4000-8000-0000000000d1',
  rent: '00000000-0000-4000-8000-0000000000d2',
  wallet: '00000000-0000-4000-8000-0000000000d3',
  other: '00000000-0000-4000-8000-0000000000d4',
};

const RULE = {
  dining: '00000000-0000-4000-8000-0000000000a1',
  swiggy: '00000000-0000-4000-8000-0000000000a2',
  wallet: '00000000-0000-4000-8000-0000000000a3',
};

const CAP = {
  parent: '00000000-0000-4000-8000-0000000000c0',
  bonus: '00000000-0000-4000-8000-0000000000c1',
  spend: '00000000-0000-4000-8000-0000000000c2',
  cardYear: '00000000-0000-4000-8000-0000000000c3',
  count: '00000000-0000-4000-8000-0000000000c4',
};

const MILESTONE = {
  welcome: '00000000-0000-4000-8000-0000000000e1',
  annual: '00000000-0000-4000-8000-0000000000e2',
};

const CARD = {
  point_value_inr: '0.2500',
  base_reward_unit: 'points_per_100',
  base_reward_rate: '1.0000',
  excluded_categories: [],
  accrual_rounding: 'floor',
  cashback_rounding: null,
  accrual_block_inr: 100,
};

function rule(overrides) {
  return {
    category_id: null, merchant_pattern: null, rail: null, min_txn_inr: null, max_txn_inr: null,
    excluded_categories: [], effective_from: null, effective_to: null, priority: 100,
    rule_role: 'earn', merchant_slugs: [], platform_slugs: [], mcc_include: [], mcc_exclude: [],
    except_merchant_slugs: [], except_platform_slugs: [], block_inr: null,
    min_engine_version: 2, max_engine_version: null, display_note: null,
    ...overrides,
  };
}

const RULES = [
  rule({ id: RULE.dining, category_id: CATEGORY.dining, unit: 'points_per_100', rate: '5.0000', display_note: 'dining 5X' }),
  rule({ id: RULE.swiggy, merchant_slugs: ['swiggy'], unit: 'points_per_100', rate: '10.0000', display_note: 'swiggy 10X' }),
  rule({ id: RULE.wallet, rule_role: 'exclusion', category_id: CATEGORY.wallet, unit: 'points_per_100', rate: '0.0000', display_note: 'no points on wallet loads' }),
];

function cap(overrides) {
  return {
    reward_rule_id: null, category_id: null, measure: 'reward_value', post_cap_unit: null, post_cap_rate: null,
    scope: 'targets', parent_cap_id: null, post_cap_behavior: null, anchor: null, min_engine_version: 2,
    targets: [],
    ...overrides,
  };
}

// Catalogue order matters for ties (C8 D9(8)); parents first is fine.
const CAPS = [
  cap({ id: CAP.parent, label: 'wp8 parent total', period: 'calendar_month', cap_value: '625.00', cap_kind: 'total_points', cap_amount: '2500.00', post_cap_rate: '0' }),
  cap({ id: CAP.bonus, label: 'wp8 dining bonus', period: 'calendar_month', cap_value: '250.00', cap_kind: 'bonus_points', cap_amount: '1000.00', parent_cap_id: CAP.parent, targets: [RULE.dining] }),
  cap({ id: CAP.spend, label: 'wp8 swiggy spend', measure: 'spend_amount', period: 'calendar_month', cap_value: '20000.00', cap_kind: 'eligible_spend', cap_amount: '20000.00', post_cap_behavior: 'base_rate', parent_cap_id: CAP.parent, targets: [RULE.swiggy] }),
  cap({ id: CAP.cardYear, label: 'wp8 card year total', period: 'annual', anchor: 'card_anniversary', cap_value: '1500.00', cap_kind: 'total_points', cap_amount: '6000.00', scope: 'card', post_cap_rate: '0' }),
  cap({ id: CAP.count, label: 'wp8 swiggy count', measure: 'txn_count', period: 'calendar_month', cap_value: '2.00', cap_kind: 'txn_count', cap_amount: '2.00', post_cap_behavior: 'zero', targets: [RULE.swiggy] }),
];

const MILESTONES = [
  { id: MILESTONE.welcome, label: 'wp8 welcome', period: 'lifetime', anchor: 'card_anniversary', threshold_spend_inr: '15000.00', window_days: 90, excluded_category_ids: [] },
  { id: MILESTONE.annual, label: 'wp8 annual', period: 'annual', anchor: 'calendar_year', threshold_spend_inr: '100000.00', window_days: null, excluded_category_ids: [CATEGORY.rent] },
];

const DIRECTORY = {
  merchants: [
    { slug: 'swiggy', name: 'Swiggy', parent_slug: null, aliases: ['swiggy', 'bundl technologies'], vpa_prefixes: ['swiggy'], mcc: ['5814'] },
    { slug: 'instamart', name: 'Swiggy Instamart', parent_slug: 'swiggy', aliases: ['instamart'], vpa_prefixes: [], mcc: [] },
  ],
  platforms: [],
};

/** The v2 card as card_state_v2.buildV2Card expects it, with the given user-card dates. */
function userCardRow(overrides = {}) {
  return {
    id: '00000000-0000-4000-8000-0000000000b1',
    profile_id: '00000000-0000-4000-8000-0000000000f1',
    card_product_id: '00000000-0000-4000-8000-0000000000b0',
    statement_day: null,
    opened_on: '2026-10-01',
    anniversary_on: null,
    created_at: new Date('2026-10-20T06:00:00Z'),
    ...CARD,
    ...overrides,
  };
}

module.exports = { CATEGORY, RULE, CAP, MILESTONE, CARD, RULES, CAPS, MILESTONES, DIRECTORY, userCardRow };
