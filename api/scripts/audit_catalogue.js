#!/usr/bin/env node
/**
 * Prints the feature spec's R1–R9 catalogue metrics (card-rewards feature
 * spec §3.1, plan §8) for any catalogue JSON: the v1 feed (GET /catalogue),
 * the v2 feed (GET /catalogue?schema=2), or the loader's preview
 * (.staging/catalogue-v2-preview.json from --transform-only).
 *
 * Usage:
 *   node api/scripts/audit_catalogue.js <file-or-url> [--json] [--directory <merchant_directory.json>]
 *
 * Read-only: a URL is fetched with a plain GET; nothing is written.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const DEFAULT_DIRECTORY = path.resolve(__dirname, '../../db/fixtures/merchant_directory.json');
const UNIT_BLOCK = { points_per_100: 100, points_per_150: 150, points_per_200: 200, miles_per_100: 100 };
const NON_ANNUAL = new Set(['quarter', 'calendar_month', 'statement_cycle', 'half_year']);
// Words that appear in card names but aren't brands.
const NOT_BRANDS = new Set(['platinum', 'select', 'prime', 'signature', 'titanium', 'gold', 'classic', 'elite', 'world', 'business', 'metal', 'premier', 'reserve', 'privilege', 'rewards', 'cashback', 'travel', 'easy', 'first', 'select black', 'infinite', 'pro', 'max', 'one', 'central', 'lifestyle', 'spar', 'vivanta', 'gateway', 'irth', 'giva', 'skinn']);

const BANK_WORDS = /\b(sbi|hdfc|icici|axis|kotak|idfc|yes|rbl|indus|hsbc|bank|card|canara|baroda|bobcard|pnb|federal|au)\b/;

function parseArgs(argv) {
  const args = { source: null, json: false, directory: DEFAULT_DIRECTORY };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') args.json = true;
    else if (a === '--directory') args.directory = argv[++i];
    else if (a === '--help' || a === '-h') args.help = true;
    else if (!args.source) args.source = a;
    else throw new Error(`Unexpected argument: ${a}`);
  }
  return args;
}

async function loadCatalogue(source) {
  if (/^https?:\/\//.test(source)) {
    const res = await fetch(source, { headers: { accept: 'application/json' } });
    if (!res.ok) throw new Error(`GET ${source} -> ${res.status}`);
    return res.json();
  }
  return JSON.parse(fs.readFileSync(source, 'utf8'));
}

function normalize(s) {
  return String(s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function num(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

// ₹ earned per ₹ spent for a unit/rate on this card.
function valuePerRupee(unit, rate, pointValue, blockInr) {
  const r = num(rate);
  if (r === null) return null;
  if (unit === 'cashback_percent' || unit === 'discount_percent') return r / 100;
  const block = num(blockInr) || UNIT_BLOCK[unit];
  if (!block) return null;
  return (r / block) * (num(pointValue) || 0);
}

function isV2Card(card) {
  return card.accrual_rounding != null || (card.reward_rules || []).some((r) => r.rule_role != null && r.rule_role !== 'earn')
    || (card.cap_rules || []).some((c) => c.cap_kind != null);
}

function brandAliases(directory) {
  const out = [];
  for (const m of directory?.merchants || []) {
    for (const a of [m.name, ...(m.aliases || [])]) {
      const n = normalize(a);
      if (n.length >= 4 && !NOT_BRANDS.has(n) && !BANK_WORDS.test(n)) out.push(n);
    }
  }
  for (const p of directory?.platforms || []) {
    // Payment apps only (PhonePe, Paytm, Google Pay...): a merchant's own app
    // is covered by the merchant, and bank apps aren't co-brands.
    if (p.kind !== 'payment_app' || p.issuer_slug) continue;
    for (const a of [p.name, ...(p.aliases || [])]) {
      const n = normalize(a).replace(/ app$/, '');
      if (n.length >= 4 && !NOT_BRANDS.has(n) && !BANK_WORDS.test(n)) out.push(n);
    }
  }
  return [...new Set(out)];
}

function audit(catalogue, directory) {
  const cards = Array.isArray(catalogue) ? catalogue : catalogue.cards || [];
  const feed = catalogue?.schema === 2 ? (catalogue.preview ? 'v2-preview' : 'v2') : 'v1';
  const aliases = brandAliases(directory);
  const m = {
    feed,
    cards: cards.length,
    cards_v2_shaped: 0,
    model_status: {},
    rules: { total: 0, by_role: {}, v2_only: 0 },
    r1_cobrand: { cobrand_cards: 0, without_merchant_rule: 0 },
    r2_unrestricted_bonus: { rules: 0, cards: 0 },
    r3_caps: { total: 0, linked_to_nothing: 0, by_kind: {}, by_measure: {} },
    r4_post_cap_zero: { caps_post_zero: 0, bonus_caps_zeroing_base: 0, caps_post_null: 0 },
    r5_cap_units: { suspect_spend_caps: 0, missing_value: 0 },
    r6_milestones: { total: 0, anchor_card_anniversary: 0, non_annual_on_card_anniversary: 0, by_period_anchor: {} },
    r7_spend_gated_benefits: { lounge_benefits: 0, lounge_with_spend_text: 0, unlock_rules: 0, lounge_with_unlock_rules: 0 },
    r8_platform_rules: { rules_with_platform: 0, cards_with_platform_rule: 0, rules_mentioning_app_or_portal: 0 },
    r9_rounding: { points_cards: 0, with_rounding: 0 },
  };
  const inc = (obj, k) => { obj[k] = (obj[k] || 0) + 1; };

  for (const card of cards) {
    const v2 = isV2Card(card);
    if (v2) m.cards_v2_shaped += 1;
    if (card.model_status) inc(m.model_status, card.model_status);
    const rules = card.reward_rules || [];
    const caps = card.cap_rules || [];
    const pv = num(card.point_value_inr);
    const baseValue = valuePerRupee(card.base_reward_unit, card.base_reward_rate, pv, null) ?? 0;
    const ruleById = new Map(rules.map((r) => [r.id, r]));

    // Rules.
    let unrestrictedHere = 0;
    let platformHere = 0;
    let merchantRule = false;
    for (const r of rules) {
      m.rules.total += 1;
      const role = r.rule_role || 'v1';
      inc(m.rules.by_role, role);
      if (Number(r.min_engine_version) === 2 || role === 'info') m.rules.v2_only += 1;
      if (role === 'info' || role === 'exclusion') continue;
      const value = valuePerRupee(r.unit, r.rate, pv, r.block_inr);
      const hasMerchant = Boolean(r.merchant_pattern) || (r.merchant_slugs || []).length > 0;
      const hasPlatform = (r.platform_slugs || []).length > 0;
      if ((hasMerchant || hasPlatform) && (value ?? 0) > 0) merchantRule = true;
      const restricted = r.category_id || hasMerchant || hasPlatform || r.rail || num(r.min_txn_inr) !== null ||
        (r.mcc_include || []).length || (r.mcc_exclude || []).length;
      if (!restricted && value !== null && value > baseValue + 1e-9) unrestrictedHere += 1;
      if (hasPlatform) platformHere += 1;
      const condText = JSON.stringify(r.conditions || {}).toLowerCase();
      if (!hasPlatform && /(phonepe|smartbuy|paytm|reward multiplier|\bportal\b|\bapp\b|ishop|travel edge)/.test(condText)) {
        m.r8_platform_rules.rules_mentioning_app_or_portal += 1;
      }
    }
    m.r2_unrestricted_bonus.rules += unrestrictedHere;
    if (unrestrictedHere) m.r2_unrestricted_bonus.cards += 1;
    m.r8_platform_rules.rules_with_platform += platformHere;
    if (platformHere) m.r8_platform_rules.cards_with_platform_rule += 1;

    const name = ` ${normalize(card.name)} `;
    if (aliases.some((a) => name.includes(` ${a} `))) {
      m.r1_cobrand.cobrand_cards += 1;
      if (!merchantRule) m.r1_cobrand.without_merchant_rule += 1;
    }

    // Caps.
    for (const c of caps) {
      m.r3_caps.total += 1;
      inc(m.r3_caps.by_kind, c.cap_kind || 'legacy');
      inc(m.r3_caps.by_measure, c.measure || 'n/a');
      const targets = c.targets || [];
      if (!c.reward_rule_id && !c.category_id && !targets.length && c.scope !== 'card') m.r3_caps.linked_to_nothing += 1;
      const post = c.post_cap_rate === null || c.post_cap_rate === undefined ? null : Number(c.post_cap_rate);
      if (post === 0) m.r4_post_cap_zero.caps_post_zero += 1;
      if (post === null) m.r4_post_cap_zero.caps_post_null += 1;
      // A bonus-only cap must leave the base: on v1 rows a reward-value cap
      // with post-cap 0 can't be told apart, so it counts (upper bound).
      if (post === 0 && (String(c.cap_kind || '').startsWith('bonus_') || (!c.cap_kind && c.measure === 'reward_value'))) {
        m.r4_post_cap_zero.bonus_caps_zeroing_base += 1;
      }
      const amount = c.cap_kind ? num(c.cap_amount) : num(c.cap_value);
      if (amount === null || amount <= 0) m.r5_cap_units.missing_value += 1;
      const isSpend = c.cap_kind ? c.cap_kind === 'eligible_spend' : c.measure === 'spend_amount';
      if (isSpend && amount !== null && amount <= 5000) {
        const linked = [c.reward_rule_id, ...targets].filter(Boolean).map((id) => ruleById.get(id)).filter(Boolean);
        if (linked.some((r) => r.unit === 'cashback_percent' && Number(r.rate) >= 5)) m.r5_cap_units.suspect_spend_caps += 1;
      }
    }

    // Milestones.
    for (const ms of card.milestone_rules || []) {
      m.r6_milestones.total += 1;
      inc(m.r6_milestones.by_period_anchor, `${ms.period}/${ms.anchor}`);
      if (ms.anchor === 'card_anniversary') {
        m.r6_milestones.anchor_card_anniversary += 1;
        if (NON_ANNUAL.has(ms.period)) m.r6_milestones.non_annual_on_card_anniversary += 1;
      }
    }

    // Spend-gated benefits.
    const unlocks = card.unlock_rules || [];
    m.r7_spend_gated_benefits.unlock_rules += unlocks.length;
    const unlocked = new Set(unlocks.map((u) => u.card_benefit_id).filter(Boolean));
    for (const b of card.benefits || []) {
      if (!String(b.kind).startsWith('lounge')) continue;
      m.r7_spend_gated_benefits.lounge_benefits += 1;
      const text = JSON.stringify(b.conditions || {});
      if (/spen[dt][^"]*"\s*:\s*\{?[^}]*?\d{4,}|spen[dt][^"]{0,80}₹\s?[\d,]{4,}|"[^"]*spen[dt][^"]*"\s*:\s*\[?\s*\d{4,}/i.test(text)) {
        m.r7_spend_gated_benefits.lounge_with_spend_text += 1;
      }
      if (unlocked.has(b.id)) m.r7_spend_gated_benefits.lounge_with_unlock_rules += 1;
    }

    // Rounding.
    if (String(card.base_reward_unit || '').startsWith('points') || String(card.base_reward_unit || '').startsWith('miles')) {
      m.r9_rounding.points_cards += 1;
      if (card.accrual_rounding) m.r9_rounding.with_rounding += 1;
    }
  }
  return m;
}

function print(m) {
  const rows = [
    ['Feed', m.feed],
    ['Cards (v2-shaped)', `${m.cards} (${m.cards_v2_shaped})`],
    ['Model status', Object.entries(m.model_status).map(([k, v]) => `${k} ${v}`).join(', ') || 'n/a'],
    ['Rules (by role)', `${m.rules.total} (${Object.entries(m.rules.by_role).map(([k, v]) => `${k} ${v}`).join(', ')})`],
    ['Rules hidden from v1 (v2-only or info)', m.rules.v2_only],
    ['R1 co-brand cards without a merchant/platform rule', `${m.r1_cobrand.without_merchant_rule} / ${m.r1_cobrand.cobrand_cards}`],
    ['R2 unrestricted rules above the base rate', `${m.r2_unrestricted_bonus.rules} rules / ${m.r2_unrestricted_bonus.cards} cards`],
    ['R3 caps linked to nothing', `${m.r3_caps.linked_to_nothing} / ${m.r3_caps.total}`],
    ['R3 caps by kind', Object.entries(m.r3_caps.by_kind).map(([k, v]) => `${k} ${v}`).join(', ')],
    ['R4 caps with post-cap 0 / bonus caps zeroing the base', `${m.r4_post_cap_zero.caps_post_zero} / ${m.r4_post_cap_zero.bonus_caps_zeroing_base}`],
    ['R5 suspect spend caps (≤ ₹5,000 on ≥ 5% cashback) / missing values', `${m.r5_cap_units.suspect_spend_caps} / ${m.r5_cap_units.missing_value}`],
    ['R6 milestones on card anniversary / non-annual on card anniversary', `${m.r6_milestones.anchor_card_anniversary} / ${m.r6_milestones.non_annual_on_card_anniversary} (of ${m.r6_milestones.total})`],
    ['R7 lounge benefits with spend text / with structured unlocks', `${m.r7_spend_gated_benefits.lounge_with_spend_text} / ${m.r7_spend_gated_benefits.lounge_with_unlock_rules} (of ${m.r7_spend_gated_benefits.lounge_benefits}; ${m.r7_spend_gated_benefits.unlock_rules} unlock rows)`],
    ['R8 rules with a platform / cards / unmodelled app-portal mentions', `${m.r8_platform_rules.rules_with_platform} / ${m.r8_platform_rules.cards_with_platform_rule} / ${m.r8_platform_rules.rules_mentioning_app_or_portal}`],
    ['R9 points cards with a rounding mode', `${m.r9_rounding.with_rounding} / ${m.r9_rounding.points_cards}`],
  ];
  const width = Math.max(...rows.map((r) => r[0].length));
  for (const [k, v] of rows) console.log(`${k.padEnd(width)}  ${v}`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.source) {
    console.log('Usage: node audit_catalogue.js <file-or-url> [--json] [--directory <merchant_directory.json>]');
    if (!args.help) process.exitCode = 1;
    return;
  }
  const catalogue = await loadCatalogue(args.source);
  const directory = catalogue?.merchants
    ? { merchants: catalogue.merchants, platforms: catalogue.platforms || [] }
    : JSON.parse(fs.readFileSync(args.directory, 'utf8'));
  const metrics = audit(catalogue, directory);
  if (args.json) console.log(JSON.stringify(metrics, null, 2));
  else print(metrics);
}

if (require.main === module) {
  main().catch((err) => {
    console.error('Fatal error:', err.message || err);
    process.exitCode = 1;
  });
}

module.exports = { audit, valuePerRupee };
