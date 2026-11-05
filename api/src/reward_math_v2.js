const v1 = require('./reward_math');
const { loadDirectory, resolveMerchant, ancestors } = require('./merchant_directory');

/**
 * Reward engine v2 — Card Rewards Phase 1, plan C3 ("Trust the rules").
 *
 * The server-side twin of the Dart engine's v2 path in
 * packages/pandapay_domain. Both are held to the same scenario files in
 * db/fixtures/reward_v2_scenarios/ (see api/test/reward_math_v2.test.js), so
 * a semantic change lands in both or fails both suites.
 *
 * What v2 adds over reward_math.js (v1):
 *   - rule roles (base / earn / exclusion / info — info never applies);
 *   - merchant slugs resolved through the merchant directory (C5), with
 *     sub-brands matching their parent's rules; platform slugs (never
 *     inferred); MCC include/exclude;
 *   - unknown rail no longer satisfies a rail restriction;
 *   - points accrue per block with the card's rounding (₹199 → 1 block);
 *   - caps in native units (points, ₹ cashback, ₹ spend, a count), several
 *     per transaction (targets, card-wide, and every parent), bonus-only vs
 *     total, and an explicit post-cap behaviour.
 *
 * v1-shaped cards (C3.2: no rule_role, no cap_kind, no accrual_rounding) are
 * handed to reward_math.js untouched, so their answers stay byte-identical.
 *
 * Money is plain JavaScript numbers in RUPEES (pg `numeric` may arrive as a
 * string; every read goes through `num`). Cashback is kept to paise; points
 * are block-rounded per the card. Outputs are rounded half-up to 2 decimals.
 */

const POINTS_UNITS = new Set(['points_per_100', 'points_per_150', 'points_per_200', 'miles_per_100', 'flat_points']);
const CASHBACK_UNITS = new Set(['cashback_percent', 'discount_percent']);
const UNIT_BLOCK = { points_per_100: 100, points_per_150: 150, points_per_200: 200, miles_per_100: 100 };
const ROLES = new Set(['base', 'earn', 'exclusion', 'info']);
const CAP_KINDS = new Set(['bonus_points', 'total_points', 'bonus_cashback', 'total_cashback', 'eligible_spend', 'txn_count']);
const POST_CAP = new Set(['base_rate', 'zero', 'custom_rate']);
const ROUNDING = new Set(['floor', 'round', 'none', 'points_half_up', 'points_floor']);

// Guards paise rounding against binary float error (1.5% of ₹67 is
// 1.0049999… in doubles but ₹1.005 → ₹1.01 on paper). Far below a paisa.
const PAISE_EPS = 1e-6;

const RESOLVED = Symbol('pandapay.rewardContextV2');

function num(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function arr(value) {
  return Array.isArray(value) ? value : [];
}

/** Half-up to 2 decimals. Inputs here are never negative. */
function round2(value) {
  if (!Number.isFinite(value)) return 0;
  const r = Math.round(value * 100 + PAISE_EPS) / 100;
  return r === 0 ? 0 : r; // no -0
}

/** 'points' | 'cashback' | null for a reward unit. */
function currencyOf(unit) {
  if (POINTS_UNITS.has(unit)) return 'points';
  if (CASHBACK_UNITS.has(unit)) return 'cashback';
  return null;
}

function roleOf(rule) {
  return rule.rule_role == null ? 'earn' : rule.rule_role;
}

/** Midnight local-time on the day `value` names (same as reward_math.js). */
function startOfDay(value) {
  const d = new Date(value);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

// ---------------------------------------------------------------------------
// C3.2 — v1/v2 switch
// ---------------------------------------------------------------------------

/**
 * A card is v2-shaped if any rule carries `rule_role`, any cap a non-null
 * `cap_kind`, or the card an `accrual_rounding`. `rewardRules` / `capRules`
 * default to the lists embedded in the wire card.
 */
function isV2Card(card, rewardRules, capRules) {
  const rules = rewardRules || (card && card.reward_rules) || [];
  const caps = capRules || (card && card.cap_rules) || [];
  if (card && card.accrual_rounding != null) return true;
  if (arr(rules).some((r) => r && r.rule_role != null)) return true;
  if (arr(caps).some((c) => c && c.cap_kind != null)) return true;
  return false;
}

// ---------------------------------------------------------------------------
// C3.1 — context
// ---------------------------------------------------------------------------

function firstPresent(ctx, keys) {
  for (const k of keys) {
    if (ctx[k] !== undefined && ctx[k] !== null) return ctx[k];
  }
  return null;
}

/**
 * Accepts the C3.1 snake_case context (scenario files, catalogue wire) or the
 * camelCase one reward_math.js callers already build.
 */
function normalizeContext(ctx) {
  const c = ctx || {};
  const mcc = firstPresent(c, ['mcc']);
  const mccText = mcc == null ? null : String(mcc).trim();
  const rail = firstPresent(c, ['rail']);
  return {
    amount: Number(firstPresent(c, ['amount', 'amountInr'])),
    occurred: firstPresent(c, ['occurred', 'occurredAt']),
    category_id: firstPresent(c, ['category_id', 'categoryId']),
    category_slug: firstPresent(c, ['category_slug', 'categorySlug']),
    mcc: mccText === '' ? null : mccText,
    merchant_name: firstPresent(c, ['merchant_name', 'merchantName']),
    merchant_vpa: firstPresent(c, ['merchant_vpa', 'merchantVpa']),
    merchant_slug: firstPresent(c, ['merchant_slug', 'merchantSlug']),
    platform: firstPresent(c, ['platform']),
    rail: rail == null || rail === '' ? 'unknown' : String(rail),
  };
}

/**
 * Normalized context plus the merchant chain (resolved slug + ancestors).
 * A caller-supplied `merchant_slug` wins; otherwise the directory resolves
 * the name/VPA (C5). Without a directory only an explicit slug can match.
 */
function resolveContext(ctx, directory) {
  if (ctx && ctx[RESOLVED]) return ctx;
  const c = normalizeContext(ctx);
  const dir = directory ? loadDirectory(directory) : null;
  let slug = c.merchant_slug;
  let via = slug != null ? 'given' : null;
  if (slug == null && dir) {
    const hit = resolveMerchant(dir, c.merchant_name, c.merchant_vpa);
    if (hit) {
      slug = hit.slug;
      via = hit.via;
    }
  }
  c.resolvedMerchantSlug = slug;
  c.merchantResolvedVia = via;
  c.merchantChain = slug != null ? [slug, ...ancestors(dir, slug)] : [];
  c[RESOLVED] = true;
  return c;
}

// ---------------------------------------------------------------------------
// C3.3 — rule applicability
// ---------------------------------------------------------------------------

/**
 * Whether `rule` applies to this transaction (all restrictions AND-ed).
 * Roles: base/earn/exclusion can apply; `info` and unknown roles never do.
 * Deciding what an applicable exclusion *means* is pickRuleV2's job.
 *
 * Judgement call beyond C3.3 (never widen, plan H2): a rule with no
 * `merchant_slugs` but a legacy `merchant_pattern` keeps v1's substring
 * restriction rather than becoming unrestricted. When `merchant_slugs` is
 * set, `merchant_pattern` is only its v1 projection and is ignored.
 */
function ruleAppliesV2(rule, ctx, directory) {
  if (!rule) return false;
  const role = roleOf(rule);
  if (!ROLES.has(role) || role === 'info') return false;
  const c = resolveContext(ctx, directory);

  // 1. Effective dates, as v1: DATE bounds, the end day inclusive.
  if (c.occurred) {
    const when = new Date(c.occurred);
    if (rule.effective_from && when < startOfDay(rule.effective_from)) return false;
    if (rule.effective_to) {
      const end = startOfDay(rule.effective_to);
      end.setDate(end.getDate() + 1);
      if (when >= end) return false;
    }
  }

  // 3. Category.
  if (rule.category_id != null && rule.category_id !== c.category_id) return false;

  // 4. Rule-level excluded categories.
  if (c.category_id != null && arr(rule.excluded_categories).includes(c.category_id)) return false;

  // 5. Merchant: resolved slug or any ancestor; unknown merchant never matches.
  const slugs = arr(rule.merchant_slugs);
  if (slugs.length > 0) {
    if (!c.merchantChain.some((s) => slugs.includes(s))) return false;
  } else if (rule.merchant_pattern != null && String(rule.merchant_pattern).trim() !== '') {
    if (!c.merchant_name) return false;
    if (!v1.normalizeMerchant(c.merchant_name).includes(v1.normalizeMerchant(rule.merchant_pattern))) return false;
  }

  // 6. Platform: caller-supplied only; unknown never matches.
  const platforms = arr(rule.platform_slugs);
  if (platforms.length > 0 && (c.platform == null || !platforms.includes(c.platform))) return false;

  // 7. MCC include; an unknown MCC is stood in for by a matching category
  //    (step 3 already enforced it), otherwise it fails.
  const include = arr(rule.mcc_include).map(String);
  if (include.length > 0) {
    if (c.mcc != null) {
      if (!include.includes(c.mcc)) return false;
    } else if (rule.category_id == null) {
      return false;
    }
  }

  // 8. MCC exclude.
  if (c.mcc != null && arr(rule.mcc_exclude).map(String).includes(c.mcc)) return false;

  // 9. Rail: unknown never matches on a v2 card.
  if (rule.rail != null && (c.rail === 'unknown' || rule.rail !== c.rail)) return false;

  // 10. Minimum transaction.
  const min = num(rule.min_txn_inr);
  if (min != null && c.amount < min) return false;

  return true;
}

// ---------------------------------------------------------------------------
// C3.4 — rule selection
// ---------------------------------------------------------------------------

/** Effective ₹ value per ₹ spent, for priority tie-breaks. */
function effectiveRate(rule, pointValue) {
  const rate = num(rule.rate);
  if (rate == null) return 0;
  if (CASHBACK_UNITS.has(rule.unit)) return rate / 100;
  if (rule.unit === 'flat_points') return 0;
  const block = num(rule.block_inr) || UNIT_BLOCK[rule.unit];
  if (!block) return 0;
  return (rate * pointValue) / block;
}

function byPriority(rules, pointValue) {
  return rules
    .map((rule, index) => ({ rule, index, priority: num(rule.priority) ?? 100, eff: effectiveRate(rule, pointValue) }))
    .sort((a, b) => a.priority - b.priority || b.eff - a.eff || a.index - b.index)
    .map((x) => x.rule);
}

function implicitBaseRule(card) {
  return {
    id: null,
    rule_role: 'base',
    unit: (card && card.base_reward_unit) || null,
    rate: card ? num(card.base_reward_rate) : null,
    block_inr: null,
    max_txn_inr: null,
    display_note: null,
  };
}

/**
 * Returns `{ excluded, rule, implicit }`:
 *   - an applicable exclusion rule (lowest priority) → excluded, that rule;
 *   - the card's excluded_categories holds the category → excluded, rule null;
 *   - else the lowest-priority applicable base/earn rule (tie → higher
 *     effective rate, then list order);
 *   - else the card's base unit/rate as an implicit base rule (id null).
 */
function pickRuleV2(rules, ctx, card, directory) {
  const c = resolveContext(ctx, directory);
  const pointValue = num(card && card.point_value_inr) || 0;
  const applicable = arr(rules).filter((r) => ruleAppliesV2(r, c));

  const exclusions = applicable.filter((r) => roleOf(r) === 'exclusion');
  if (exclusions.length > 0) return { excluded: true, rule: byPriority(exclusions, pointValue)[0], implicit: false };

  if (c.category_id != null && arr(card && card.excluded_categories).includes(c.category_id)) {
    return { excluded: true, rule: null, implicit: false };
  }

  const earners = applicable.filter((r) => {
    const role = roleOf(r);
    return role === 'base' || role === 'earn';
  });
  if (earners.length === 0) return { excluded: false, rule: implicitBaseRule(card), implicit: true };
  return { excluded: false, rule: byPriority(earners, pointValue)[0], implicit: false };
}

// ---------------------------------------------------------------------------
// C3.6 — which caps apply, in native units
// ---------------------------------------------------------------------------

function postCapBehavior(cap) {
  if (cap.post_cap_behavior != null) return POST_CAP.has(cap.post_cap_behavior) ? cap.post_cap_behavior : 'base_rate';
  // No explicit behaviour: read v1's post_cap_rate the way v1 does (null =
  // base rate continues, explicit 0 = nothing, anything else = that rate).
  const rate = num(cap.post_cap_rate);
  if (rate == null) return 'base_rate';
  return rate === 0 ? 'zero' : 'custom_rate';
}

/**
 * One cap row in native units: `{ id, kind, amount, behavior, postUnit,
 * postRate, legacy }`, or null when it can't be enforced as written (unknown
 * kind, no amount, a points value cap on a card with no point value).
 */
function normalizeCap(cap, rule, card) {
  let kind = cap.cap_kind;
  let amount;
  let legacy = false;
  if (kind == null) {
    legacy = true;
    const value = num(cap.cap_value);
    if (value == null) return null;
    if (cap.measure === 'spend_amount') {
      kind = 'eligible_spend';
      amount = value;
    } else if (cap.measure === 'txn_count') {
      kind = 'txn_count';
      amount = value;
    } else if (cap.measure === 'reward_value') {
      const cur = currencyOf(rule && rule.unit);
      if (cur === 'cashback') {
        kind = 'total_cashback';
        amount = value;
      } else if (cur === 'points') {
        const pointValue = num(card && card.point_value_inr) || 0;
        if (!(pointValue > 0)) return null;
        kind = 'total_points';
        amount = value / pointValue;
      } else {
        return null;
      }
    } else {
      return null;
    }
  } else {
    if (!CAP_KINDS.has(kind)) return null;
    amount = num(cap.cap_amount);
    if (amount == null) return null;
  }
  return {
    id: cap.id,
    kind,
    amount,
    behavior: postCapBehavior(cap),
    postUnit: cap.post_cap_unit || null,
    postRate: num(cap.post_cap_rate),
    legacy,
  };
}

/**
 * The caps this transaction counts against (C3.6): `targets` caps naming the
 * rule; legacy fallbacks when `targets` is empty (`reward_rule_id` = rule id,
 * or no rule id and `category_id` = the context category); every
 * `scope = 'card'` cap; plus every ancestor via `parent_cap_id`,
 * deduplicated, in catalogue order. None for an excluded spend.
 */
function applicableCaps({ card, capRules, rule, ctx, excluded = false }) {
  if (excluded) return [];
  const c = ctx && ctx[RESOLVED] ? ctx : normalizeContext(ctx);
  const caps = arr(capRules).filter((cap) => cap && cap.id != null);
  const byId = new Map(caps.map((cap) => [cap.id, cap]));
  const ruleId = rule && rule.id != null ? rule.id : null;

  const chosen = new Set();
  for (const cap of caps) {
    const scope = cap.scope == null ? 'targets' : cap.scope;
    if (scope === 'card') {
      chosen.add(cap.id);
    } else if (scope === 'targets') {
      const targets = arr(cap.targets);
      if (targets.length > 0) {
        if (ruleId != null && targets.includes(ruleId)) chosen.add(cap.id);
      } else if (cap.reward_rule_id != null) {
        if (ruleId != null && cap.reward_rule_id === ruleId) chosen.add(cap.id);
      } else if (cap.category_id != null && cap.category_id === c.category_id) {
        chosen.add(cap.id);
      }
    }
  }

  for (const id of [...chosen]) {
    let parent = byId.get(id).parent_cap_id;
    while (parent != null && byId.has(parent) && !chosen.has(parent)) {
      chosen.add(parent);
      parent = byId.get(parent).parent_cap_id;
    }
  }

  return caps
    .filter((cap) => chosen.has(cap.id))
    .map((cap) => normalizeCap(cap, rule, card))
    .filter(Boolean);
}

// ---------------------------------------------------------------------------
// C3.5 — accrual
// ---------------------------------------------------------------------------

/** `value` as an exact fraction `[numerator, denominator]` of BigInts (≤ 8 dp). */
function exactDecimal(value) {
  for (let dp = 0; dp <= 8; dp += 1) {
    const scale = 10 ** dp;
    const scaled = value * scale;
    const whole = Math.round(scaled);
    if (Math.abs(scaled - whole) <= 1e-9 * Math.max(1, Math.abs(scaled))) return [BigInt(whole), BigInt(scale)];
  }
  return [BigInt(Math.round(value * 1e8)), 100000000n];
}

/** num / den rounded half-up (both positive BigInts). */
function divHalfUp(n, d) {
  return (2n * n + d) / (2n * d);
}

/**
 * What `spend` earns at `unit`/`rate`, in that unit's currency: cashback in ₹
 * (to paise), points per block with the card's rounding, flat points once.
 *
 * Rounding modes (C3.5 + C8 D7): `floor` / `round` (half-up) / `none` apply
 * to the number of blocks; `points_floor` / `points_half_up` apply to the
 * whole-transaction product spend × rate / block. Every mode but `none` is
 * computed in integer paise with BigInt, so ₹7,500 × 1.5 / 100 is exactly
 * 112.5 (→ 113 half-up), never 112.4999….
 */
function accrue(unit, rate, spend, blockOverride, rounding) {
  const r = num(rate);
  if (!unit || r == null || r <= 0 || !(spend > 0)) return 0;
  if (CASHBACK_UNITS.has(unit)) return round2((spend * r) / 100);
  if (unit === 'flat_points') return r;
  const override = num(blockOverride);
  const block = override != null && override > 0 ? override : UNIT_BLOCK[unit];
  if (!block) return 0;
  if (rounding === 'none') return (spend / block) * r;

  const spendPaise = BigInt(Math.round(spend * 100));
  const blockPaise = BigInt(Math.round(block * 100));
  if (rounding === 'points_floor' || rounding === 'points_half_up') {
    const [rateNum, rateDen] = exactDecimal(r);
    const n = spendPaise * rateNum;
    const d = blockPaise * rateDen;
    return Number(rounding === 'points_floor' ? n / d : divHalfUp(n, d));
  }
  const blocks = rounding === 'round' ? divHalfUp(spendPaise, blockPaise) : spendPaise / blockPaise;
  return Number(blocks) * r;
}

// ---------------------------------------------------------------------------
// v1 delegation
// ---------------------------------------------------------------------------

function computeViaV1({ card, rules, caps, capConsumedBefore, ctx }) {
  const c = normalizeContext(ctx);
  const v1ctx = { amount: c.amount, categoryId: c.category_id, merchantName: c.merchant_name, rail: c.rail, occurred: c.occurred };
  const rule = v1.pickRule(rules, v1ctx);
  const capRule = rule ? v1.pickCapRule(caps, rule, v1ctx) : null;
  let before = 0;
  if (typeof capConsumedBefore === 'number') before = capConsumedBefore;
  else if (capRule && capConsumedBefore) before = num(capConsumedBefore[capRule.id]) ?? 0;

  const r = v1.computeTransactionReward({ card, rewardRules: rules, capRules: caps, capConsumedBefore: before, ctx: v1ctx });
  const cur = currencyOf(card && card.base_reward_unit) || currencyOf(rule && rule.unit) || 'points';
  return {
    points: cur === 'points' ? r.points : null,
    cashbackInr: cur === 'cashback' ? r.points : null,
    valueInr: r.valueInr,
    ruleId: r.ruleId,
    capDeltas: r.capRuleId != null && r.capConsumedDelta !== 0 ? { [r.capRuleId]: r.capConsumedDelta } : {},
    excluded: r.excluded,
    reasons: r.excluded ? ['excluded_category'] : [],
    assumptions: [],
    engine: 'v1',
    v1: r,
  };
}

// ---------------------------------------------------------------------------
// C3.5 + C3.6 — the transaction
// ---------------------------------------------------------------------------

/**
 * What one transaction earns on a card, and what it consumes.
 *
 * `capConsumedBefore` is `{ capId: consumed }` in native units as it stood
 * BEFORE this transaction. Returns
 * `{ points, cashbackInr, valueInr, ruleId, capDeltas, excluded, reasons,
 *    assumptions, engine }` — `points` is null unless points are involved
 * (a points card, or a points rule/overflow), `cashbackInr` likewise.
 * `capDeltas` lists only non-zero consumption, keyed by cap id.
 * v1-shaped cards return v1's numbers (unrounded) with `engine: 'v1'` and
 * the raw v1 result under `v1`; their deltas are in v1's cap measure.
 */
function computeTransactionRewardV2({ card, rewardRules, capRules, capConsumedBefore, ctx, directory } = {}) {
  const rules = arr(rewardRules || (card && card.reward_rules));
  const caps = arr(capRules || (card && card.cap_rules));
  if (!isV2Card(card, rules, caps)) return computeViaV1({ card, rules, caps, capConsumedBefore, ctx });

  const c = resolveContext(ctx, directory);
  const consumed = capConsumedBefore && typeof capConsumedBefore === 'object' ? capConsumedBefore : {};
  const pointValue = num(card.point_value_inr) || 0;
  const rounding = ROUNDING.has(card.accrual_rounding) ? card.accrual_rounding : 'floor';
  const baseUnit = card.base_reward_unit || null;
  const baseRate = num(card.base_reward_rate);
  const cardCur = currencyOf(baseUnit);

  const assumptions = [];
  if (c.merchantResolvedVia === 'alias') assumptions.push('merchant_resolved_by_alias');
  else if (c.merchantResolvedVia === 'vpa') assumptions.push('merchant_resolved_by_vpa');
  else if (c.resolvedMerchantSlug == null && (c.merchant_name || c.merchant_vpa)) assumptions.push('merchant_unresolved');
  const earning = rules.filter((r) => r && (roleOf(r) === 'earn' || roleOf(r) === 'base'));
  if (c.rail === 'unknown' && earning.some((r) => r.rail != null)) assumptions.push('rail_unknown');
  if (c.platform == null && earning.some((r) => arr(r.platform_slugs).length > 0)) assumptions.push('platform_unknown');

  const shape = (cur, extra) => ({
    points: cur === 'points' ? 0 : null,
    cashbackInr: cur === 'cashback' ? 0 : null,
    valueInr: 0,
    ruleId: null,
    capDeltas: {},
    excluded: false,
    reasons: [],
    assumptions,
    engine: 'v2',
    ...extra,
  });

  // Rewards are never negative; refunds are state, not negative purchases.
  if (!(Number.isFinite(c.amount) && c.amount > 0)) return shape(cardCur, { reasons: ['non_positive_amount'] });

  const pick = pickRuleV2(rules, c, card);
  if (pick.excluded) {
    const note = pick.rule && pick.rule.display_note;
    return shape(cardCur || currencyOf(pick.rule && pick.rule.unit), {
      ruleId: pick.rule ? pick.rule.id : null,
      excluded: true,
      reasons: [note || (pick.rule ? 'excluded_by_rule' : 'excluded_category')],
    });
  }

  const rule = pick.rule;
  const reasons = [];
  if (rule.display_note) reasons.push(rule.display_note);
  if (pick.implicit) assumptions.push('implicit_base_rule');
  if (arr(rule.mcc_include).length > 0 && c.mcc == null) assumptions.push('mcc_unknown_category_stand_in');

  const isBase = pick.implicit || roleOf(rule) === 'base';
  const ruleUnit = rule.unit || null;
  const ruleCur = currencyOf(ruleUnit);

  // C3.5: spend above max_txn_inr earns the card's base rate.
  const maxTxn = num(rule.max_txn_inr);
  const eligible = maxTxn != null && c.amount > maxTxn ? Math.max(0, maxTxn) : c.amount;
  const overMax = c.amount - eligible;
  if (overMax > 0) reasons.push('above_max_txn');

  const capsApplied = applicableCaps({ card, capRules: caps, rule, ctx: c });
  if (capsApplied.some((cap) => cap.legacy)) assumptions.push('legacy_cap_converted');
  const remaining = (cap) => Math.max(0, cap.amount - (num(consumed[cap.id]) ?? 0));
  const spendCaps = capsApplied.filter((cap) => cap.kind === 'eligible_spend');
  const countCaps = capsApplied.filter((cap) => cap.kind === 'txn_count');
  const bonusKind = ruleCur === 'points' ? 'bonus_points' : ruleCur === 'cashback' ? 'bonus_cashback' : null;
  const bonusCaps = capsApplied.filter((cap) => cap.kind === bonusKind);
  const totalCaps = {
    points: capsApplied.filter((cap) => cap.kind === 'total_points'),
    cashback: capsApplied.filter((cap) => cap.kind === 'total_cashback'),
  };

  // 1. Eligible-spend caps: the tightest one binds (first in catalogue order on a tie).
  let ruleSpend = eligible;
  let binding = null;
  let bindingRemaining = Infinity;
  for (const cap of spendCaps) {
    const rem = remaining(cap);
    if (rem < bindingRemaining) {
      bindingRemaining = rem;
      binding = cap;
    }
  }
  if (binding) ruleSpend = Math.min(eligible, bindingRemaining);
  if (ruleSpend < eligible) reasons.push('spend_cap_reached');

  // 2. Transaction-count caps: one exhausted cap pushes the whole eligible
  //    spend to overflow; otherwise each consumes 1.
  const forcing = countCaps.find((cap) => remaining(cap) < 1) || null;
  if (forcing) {
    ruleSpend = 0;
    binding = forcing;
    reasons.push('txn_count_cap_reached');
  }
  const overflow = eligible - ruleSpend;

  // 3. Accrue on the rule's spend; base vs bonus.
  const ruleAccrual = accrue(ruleUnit, rule.rate, ruleSpend, rule.block_inr, rounding);
  let baseAccrual;
  let bonus;
  if (isBase) {
    baseAccrual = ruleAccrual;
    bonus = 0;
  } else if (ruleCur != null && ruleCur === cardCur) {
    baseAccrual = accrue(baseUnit, baseRate, ruleSpend, null, rounding);
    bonus = Math.max(0, ruleAccrual - baseAccrual);
  } else {
    baseAccrual = 0;
    bonus = ruleAccrual;
  }

  // Overflow (post-cap) and over-max spend, each in its own unit's currency.
  const pieces = [];
  if (overflow > 0) {
    const behavior = binding ? binding.behavior : 'base_rate';
    if (behavior === 'base_rate') {
      pieces.push({ cur: cardCur, amount: accrue(baseUnit, baseRate, overflow, null, rounding) });
    } else if (behavior === 'custom_rate') {
      const unit = binding.postUnit || ruleUnit;
      pieces.push({ cur: currencyOf(unit), amount: accrue(unit, binding.postRate, overflow, null, rounding) });
    }
  }
  if (overMax > 0) pieces.push({ cur: cardCur, amount: accrue(baseUnit, baseRate, overMax, null, rounding) });

  // 4. Bonus caps (same currency as the rule's accrual).
  let allowedBonus = bonus;
  for (const cap of bonusCaps) allowedBonus = Math.min(allowedBonus, remaining(cap));
  if (allowedBonus < bonus) reasons.push('bonus_cap_reached');

  // 5. Earned, per currency.
  const earned = { points: 0, cashback: 0 };
  if (ruleCur) earned[ruleCur] += baseAccrual + allowedBonus;
  for (const p of pieces) if (p.cur) earned[p.cur] += p.amount;

  // 6. Total caps; the cut comes off the bonus first.
  const cut = { points: 0, cashback: 0 };
  const allowedTotal = { points: null, cashback: null };
  for (const cur of ['points', 'cashback']) {
    if (totalCaps[cur].length === 0) continue;
    let allowed = earned[cur];
    for (const cap of totalCaps[cur]) allowed = Math.min(allowed, remaining(cap));
    cut[cur] = earned[cur] - allowed;
    earned[cur] = allowed;
    allowedTotal[cur] = allowed;
    if (cut[cur] > 0) reasons.push('total_cap_reached');
  }

  // 7. Consumption deltas (non-zero only).
  const capDeltas = {};
  const record = (id, value) => {
    const v = round2(value);
    if (v !== 0) capDeltas[id] = v;
  };
  const bonusDelta = Math.max(0, allowedBonus - (ruleCur ? cut[ruleCur] : 0));
  for (const cap of bonusCaps) record(cap.id, bonusDelta);
  for (const cur of ['points', 'cashback']) for (const cap of totalCaps[cur]) record(cap.id, allowedTotal[cur]);
  for (const cap of spendCaps) record(cap.id, ruleSpend);
  for (const cap of countCaps) record(cap.id, forcing ? 0 : 1);

  // 8. Result.
  const involved = new Set([cardCur, ruleCur]);
  for (const p of pieces) if (p.amount > 0) involved.add(p.cur);
  if (involved.has('points') && earned.points > 0 && !(pointValue > 0)) assumptions.push('point_value_unknown');

  return {
    points: involved.has('points') ? round2(earned.points) : null,
    cashbackInr: involved.has('cashback') ? round2(earned.cashback) : null,
    valueInr: round2(earned.points * pointValue + earned.cashback),
    ruleId: rule.id,
    capDeltas,
    excluded: false,
    reasons,
    assumptions,
    engine: 'v2',
  };
}

module.exports = {
  isV2Card,
  normalizeContext,
  resolveContext,
  ruleAppliesV2,
  pickRuleV2,
  applicableCaps,
  accrue,
  currencyOf,
  computeTransactionRewardV2,
  resolveMerchant,
};
