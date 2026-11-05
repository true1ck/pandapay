'use strict';

// Plan C7 — the pure CardPipeline -> catalogue v2 transform.
//
//   transformCardRecordV2(record, { directory, overrides, verifiedSlugs, sourceSlug })
//     -> { card, rewardRules, capRules, capTargets, milestones, feeWaivers,
//          benefits, unlockRules, redemptionOptions, coverage }
//
// No I/O. Rows reference each other by local `key` (source ids, with `#n`
// for parts); import_card_pipeline.js maps keys to database ids when it
// writes them.

const { asNumber, isNA, uniq } = require('./util');
const { buildDirectoryIndex } = require('./directory');
const { MCC_CATEGORY, NARROW_TOKEN_MCC, mapCategorySlugs, resolveCategoryToken } = require('./category_tokens');
const { transformRewardRules, valuePerRupee } = require('./rules');
const { transformCaps } = require('./caps');
const { transformMilestones } = require('./milestones');
const { transformBenefits } = require('./unlocks');
const { applyOverrides } = require('./overrides');
const { buildCoverage } = require('./coverage');
const { dedupeBenefits, dedupeCaps, dedupeMilestones } = require('./dedupe');

// Bump with any mapping change; the publish gate then requires re-review.
const TRANSFORM_VERSION_V2 = '7';

const V1_POINT_UNITS = { 100: 'points_per_100', 150: 'points_per_150', 200: 'points_per_200' };

// D7: source rounding wording -> accrual_rounding.
const ROUNDING = {
  floor: 'floor',
  round: 'round',
  half_up: 'round',
  nearest_integer: 'points_half_up',
  round_final_points: 'points_half_up',
  points_half_up: 'points_half_up',
  floor_final_points: 'points_floor',
  points_floor: 'points_floor',
  floor_to_nearest_paisa: 'none',
  floor_to_nearest_rupee: 'none',
  nearest_rupee: 'none',
  round_to_nearest_rupee: 'none',
  none: 'none',
};

// D11: whole-rupee cashback. Only set when the source (or an override) says
// so; null means paise.
const CASHBACK_ROUNDING = {
  paise: 'paise',
  floor_to_nearest_paisa: 'paise',
  rupee_floor: 'rupee_floor',
  floor_to_nearest_rupee: 'rupee_floor',
  floor_to_rupee: 'rupee_floor',
  rupee_half_up: 'rupee_half_up',
  nearest_rupee: 'rupee_half_up',
  round_to_nearest_rupee: 'rupee_half_up',
};

function cashbackRounding(record, hasCashback) {
  const explicit = record?.accrual_engine?.cashback_rounding ?? record?.card_product?.cashback_rounding;
  if (!isNA(explicit)) return CASHBACK_ROUNDING[String(explicit).toLowerCase()] ?? null;
  if (!hasCashback) return null;
  const mode = record?.accrual_engine?.rounding_mode;
  return isNA(mode) ? null : CASHBACK_ROUNDING[String(mode).toLowerCase()] ?? null;
}

const PERIOD_MAP = {
  day: 'statement_cycle', statement_cycle: 'statement_cycle', calendar_month: 'calendar_month',
  quarter: 'quarter', half_year: 'half_year', annual: 'annual', card_anniversary_year: 'annual',
  enrollment_year: 'annual', lifetime: 'lifetime',
};

function cardEconomics(record) {
  const cp = record?.card_product || {};
  const accrual = record?.accrual_engine || {};
  const cashback = asNumber(accrual.base_cashback_percent);
  const points = asNumber(accrual.base_points_per_block);
  const block = asNumber(accrual.base_block_inr);
  const pointValueInr = asNumber(cp.point_value_inr_baseline);
  const flags = [];

  // D8(a): whole points per block are points, never cashback_percent — as
  // long as a point has a ₹ value, otherwise v1 would value the base at ₹0.
  let usePoints = points !== null && cashback === null;
  if (points !== null && cashback !== null) {
    if (points > 0 && cashback > 0) {
      flags.push('base_points_and_cashback_both');
      usePoints = pointValueInr !== null;
    } else {
      usePoints = points > 0;
    }
  }
  let baseUnit = null;
  let baseRate = null;
  let unusualBlock = null;
  if (usePoints && points !== null) {
    if (block !== null && V1_POINT_UNITS[block]) {
      baseUnit = V1_POINT_UNITS[block];
      baseRate = points;
    } else if (block !== null && block > 0) {
      // v1 has no enum for this block; the per-₹100 equivalent keeps its value.
      baseUnit = 'points_per_100';
      baseRate = (points * 100) / block;
      unusualBlock = block;
    } else {
      baseUnit = 'points_per_100';
      baseRate = points;
      flags.push('base_block_assumed_100');
    }
  } else if (cashback !== null) {
    baseUnit = 'cashback_percent';
    baseRate = cashback;
  }
  return {
    baseUnit,
    baseRate,
    basePointsPerBlock: points,
    baseBlockInr: block !== null && block > 0 ? Math.round(block) : null,
    unusualBlock,
    pointValueInr,
    pointValueBasis: isNA(cp.point_value_baseline_basis) ? null : cp.point_value_baseline_basis,
    baseCurrency: baseUnit === null ? null : baseUnit === 'cashback_percent' ? 'cashback' : 'points',
    capPeriodBasis: isNA(accrual.capping_period_basis) ? null : accrual.capping_period_basis,
    flags,
  };
}

const UNIT_BLOCK = { points_per_100: 100, points_per_150: 150, points_per_200: 200, miles_per_100: 100 };
function baseValuePerRupee(e) {
  if (!e.baseUnit || e.baseRate === null) return null;
  if (e.baseUnit === 'cashback_percent') return e.baseRate / 100;
  const block = UNIT_BLOCK[e.baseUnit];
  return block ? (e.baseRate / block) * (e.pointValueInr || 0) : null;
}

// D19e: a v1-visible above-base earning rule whose governing cap isn't
// v1-visible would pay above the cap in v1, so it is hidden from v1 too. A
// v1 cap that now targets a v2-only rule follows D3. Repeated until stable.
function hideUncappedFromV1(rules, caps, card) {
  const byKey = new Map(rules.map((r) => [r.key, r]));
  const hidden = [];
  let changed = true;
  while (changed) {
    changed = false;
    for (const cap of caps) {
      if (cap.min_engine_version === 1) {
        if (cap.target_keys.some((k) => byKey.get(k)?.min_engine_version === 2)) {
          cap.min_engine_version = 2;
          cap.v2_reasons = uniq([...cap.v2_reasons, 'target_v2_only']);
          changed = true;
        }
        continue;
      }
      for (const k of cap.target_keys) {
        const r = byKey.get(k);
        if (!r || r.min_engine_version !== 1 || r.max_engine_version === 1 || r.rule_role !== 'earn') continue;
        const v = valuePerRupee(r.unit, r.rate, card.pointValueInr, r.block_inr);
        if (v === null || card.baseValue == null || !(v > card.baseValue + 1e-9)) continue;
        r.min_engine_version = 2;
        r.v2_reasons = uniq([...r.v2_reasons, 'cap_not_v1_visible']);
        r.flags = uniq([...r.flags, 'hidden_from_v1_uncapped']);
        hidden.push(r.key);
        changed = true;
      }
    }
  }
  return hidden;
}

// D21b: a carve-out at or below the base rate that v1 can't show (MCC- or
// multi-merchant-scoped, so all its rows are v2-only) would leave v1 paying
// the accelerator where the bank pays only the base. Every v1-visible
// above-base earn row that could match the carve-out's scope is hidden from
// v1 (min_engine_version 2): v1 then pays the base there. Conservative: a
// scope that can't be told apart counts as overlapping.
function hideCarvedAcceleratorsFromV1(rules, card, index) {
  const v1Visible = (r) => r.min_engine_version === 1 && r.rule_role !== 'info';
  const earnPerRupee = (r) => valuePerRupee(r.unit, r.rate, 1, r.block_inr);
  const bySource = new Map();
  for (const r of rules) {
    if (!bySource.has(r.source_local_id)) bySource.set(r.source_local_id, []);
    bySource.get(r.source_local_id).push(r);
  }
  const carveOuts = [];
  for (const rows of bySource.values()) {
    const earning = rows.filter((r) => r.flags.includes('exclusion_with_stated_rate') && ['earn', 'base'].includes(r.rule_role));
    if (!earning.length || rows.some(v1Visible)) continue; // v1 shows it (or a broader projection of it)
    const atOrBelowBase = card.baseEarnPerRupee != null && earning.every((r) => {
      const e = earnPerRupee(r);
      return r.currency === card.baseCurrency && e !== null && e <= card.baseEarnPerRupee + 1e-9;
    });
    if (atOrBelowBase) carveOuts.push(...earning.filter((r) => r.max_engine_version !== 1));
  }
  if (!carveOuts.length) return [];

  const chain = (slug) => {
    const out = [];
    const seen = new Set();
    for (let cur = slug; cur && !seen.has(cur); cur = index?.merchants?.get(cur)?.parent_slug || null) {
      seen.add(cur);
      out.push(cur);
    }
    return out;
  };
  const overlaps = (a, c) => {
    if (a.rail && c.rail && a.rail !== c.rail) return false;
    if (a.category_slug && c.category_slug && a.category_slug !== c.category_slug) return false;
    if (a.category_slug && !c.category_slug && c.mcc_include.length) {
      const cats = c.mcc_include.map((m) => MCC_CATEGORY[m]);
      if (cats.every(Boolean) && !cats.includes(a.category_slug)) return false;
    }
    const am = a.merchant_slugs || [];
    if (am.length && c.merchant_slugs.length && !c.merchant_slugs.some((cm) => chain(cm).some((x) => am.includes(x)))) return false;
    if (am.length && !c.merchant_slugs.length && c.mcc_include.length) {
      const known = am.flatMap((s) => (index?.merchants?.get(s)?.mcc || []).map((m) => String(m).padStart(4, '0')));
      if (known.length && !known.some((m) => c.mcc_include.includes(m))) return false;
    }
    return true;
  };

  const hidden = [];
  for (const a of rules) {
    if (!v1Visible(a) || a.rule_role !== 'earn' || a.flags.includes('exclusion_with_stated_rate')) continue;
    let above;
    if (a.currency && a.currency === card.baseCurrency) {
      const e = earnPerRupee(a);
      above = e !== null && card.baseEarnPerRupee != null && e > card.baseEarnPerRupee + 1e-9;
    } else {
      const v = valuePerRupee(a.unit, a.rate, card.pointValueInr, a.block_inr);
      above = v !== null && card.baseValue != null && v > card.baseValue + 1e-9;
    }
    if (!above) continue;
    const by = uniq(carveOuts.filter((c) => overlaps(a, c)).map((c) => c.source_local_id));
    if (!by.length) continue;
    a.min_engine_version = 2;
    a.v2_reasons = uniq([...(a.v2_reasons || []), 'carve_out_not_v1_visible']);
    a.flags = uniq([...a.flags, 'hidden_from_v1_carve_out']);
    hidden.push(`${a.key} (by ${by.join('+')})`);
  }
  // A v1-only row hidden from v1 is visible nowhere.
  for (let i = rules.length - 1; i >= 0; i -= 1) {
    if (rules[i].max_engine_version === 1 && rules[i].min_engine_version !== 1) rules.splice(i, 1);
  }
  return hidden;
}

function feeWaiverRow(record) {
  const waiver = record?.fee_waiver_and_milestones?.annual_fee_waiver;
  if (!waiver) return [];
  const threshold = asNumber(waiver.threshold_spend_inr);
  const waivesFee = asNumber(waiver.waives_fee_inr);
  if (threshold === null || waivesFee === null) return [];
  const excluded = Array.isArray(waiver.excluded_category_ids) ? waiver.excluded_category_ids : [];
  return [{
    threshold_spend_inr: threshold,
    period: PERIOD_MAP[waiver.period] || 'statement_cycle',
    waives_fee_inr: waivesFee,
    excluded_category_slugs: uniq(excluded.flatMap(mapCategorySlugs)),
    notes: isNA(waiver.evaluation_condition) ? null : waiver.evaluation_condition,
  }];
}

function redemptionRows(record) {
  const rows = [];
  const skipped = [];
  for (const opt of record?.redemption_matrix?.direct_options || []) {
    let value = asNumber(opt?.inr_value_per_point);
    if (value === null) {
      if (opt?.redemption_type === 'statement_credit') value = 1.0;
      else {
        skipped.push({ reason: 'no inr_value_per_point', channel: opt?.channel || null });
        continue;
      }
    }
    rows.push({
      program_name: opt?.channel || 'Direct redemption',
      method: opt?.redemption_type || 'other',
      value_per_point_inr: value,
      min_points: Number.isInteger(opt?.min_points_per_txn) ? opt.min_points_per_txn : null,
      notes: isNA(opt?.redemption_fee_inr) ? null : `Redemption fee: ₹${opt.redemption_fee_inr}`,
    });
  }
  for (const partner of record?.redemption_matrix?.partner_transfers || []) {
    skipped.push({ reason: 'partner_transfer has no direct ₹/point value', channel: partner?.program_name || partner?.partner_code || null });
  }
  return { rows, skipped };
}

// Base/all-retail exclusions are card-level: a rule-level exclusion on the
// catch-all rule would just fall through to the same base rate.
// D19b: the card-level list holds only exact-category exclusions (v2 can't
// ignore it). A narrow token there ("gaming" -> entertainment, "railways" ->
// travel) becomes exclusion rules instead, D18b-style: a v1-only broad row
// plus a v2 row on the token's MCCs. A narrow token with no MCC table stays
// in the card-level list (excluding more is the safe side).
function cardExcludedCategories(record) {
  const out = new Set();
  const narrow = new Map(); // token -> { slug, mccs, source }
  for (const rule of record?.reward_rules || []) {
    if (rule?.category_id !== 'all_retail' && rule?.category_id !== 'excluded_spend') continue;
    const list = rule?.conditions?.excluded_categories;
    for (const item of Array.isArray(list) ? list : []) {
      if (typeof item !== 'string') continue;
      const key = item.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');
      const t = resolveCategoryToken(key, {});
      const parts = ['category', 'composite'].includes(t.kind) ? t.parts.filter((p) => p.categorySlug) : [];
      if (!parts.length) continue;
      for (const p of parts) {
        const tokens = p.narrowTokens?.length ? p.narrowTokens : [p.token].filter(Boolean);
        const mccs = p.broad
          ? NARROW_TOKEN_MCC[key] || (tokens.length && tokens.every((tk) => NARROW_TOKEN_MCC[tk]) ? uniq(tokens.flatMap((tk) => NARROW_TOKEN_MCC[tk])).sort() : null)
          : null;
        if (p.broad && mccs) narrow.set(`${key}:${p.categorySlug}`, { token: key, slug: p.categorySlug, mccs, source: rule.id ?? null });
        else out.add(p.categorySlug);
      }
    }
  }
  // A narrow token whose broad category is also excluded outright needs no rows.
  const narrowRows = [...narrow.values()].filter((n) => !out.has(n.slug));
  return { slugs: [...out].sort(), narrow: narrowRows };
}

function cardLevelNarrowExclusionRows(narrow, baseUnit) {
  const unit = baseUnit && baseUnit.startsWith('points') ? baseUnit : 'cashback_percent';
  const rows = [];
  for (const n of narrow) {
    const common = {
      source_local_id: n.source === null ? null : String(n.source),
      source_category_token: n.token,
      evaluation_type: 'exclusion',
      merchant_pattern: null,
      rail: null,
      unit,
      rate: 0,
      min_txn_inr: null,
      max_txn_inr: null,
      priority: 0,
      effective_from: null,
      effective_to: null,
      excluded_category_slugs: [],
      rule_role: 'exclusion',
      merchant_slugs: [],
      platform_slugs: [],
      mcc_exclude: [],
      except_merchant_slugs: [],
      except_platform_slugs: [],
      block_inr: null,
      display_note: `No rewards on ${n.token.replace(/_/g, ' ')}`,
      currency: null,
      cap_refs: [],
      info_reasons: [],
      narrow_on_merchant: null,
    };
    rows.push({
      ...common,
      key: `card-excluded:${n.token}`,
      part: 'v1',
      category_slug: n.slug,
      mcc_include: [],
      min_engine_version: 1,
      max_engine_version: 1,
      flags: ['card_level_narrow_exclusion', 'broad_exclusion_v1_only'],
      v2_reasons: [],
    });
    rows.push({
      ...common,
      key: `card-excluded:${n.token}#mcc`,
      part: 'mcc',
      category_slug: null,
      mcc_include: n.mccs,
      min_engine_version: 2,
      max_engine_version: null,
      flags: ['card_level_narrow_exclusion'],
      v2_reasons: ['mcc'],
    });
  }
  return rows;
}

/**
 * @param {object} rawRecord CardPipeline record (the `final` payload)
 * @param {object} opts
 * @param {object} opts.directory merchant_directory.json contents
 * @param {object|null} opts.overrides override file contents for this card (C7.2)
 * @param {Set<string>} [opts.verifiedSlugs] slugs WP7 marked verified
 * @param {string} [opts.sourceSlug] checklist source_slug (defaults to card_product.slug)
 */
function transformCardRecordV2(rawRecord, opts = {}) {
  const index = opts.index || buildDirectoryIndex(opts.directory || { merchants: [], platforms: [] });
  const { record, applied, errors } = applyOverrides(rawRecord, opts.overrides || null);
  const cp = record?.card_product || {};
  const sourceSlug = opts.sourceSlug || cp.slug || null;
  const issuerSlug = String(cp.issuer_slug || '').toLowerCase();
  const economics = cardEconomics(record);

  const ctx = {
    index,
    issuerSlug: issuerSlug.replace(/-bank$/, '').replace(/^american-express.*$/, 'amex') || issuerSlug,
    cardNetwork: typeof cp.network === 'string' ? cp.network : null,
    card: {
      baseValue: baseValuePerRupee(economics),
      baseEarnPerRupee: baseValuePerRupee({ ...economics, pointValueInr: 1 }),
      baseUnit: economics.baseUnit,
      baseBlockInr: economics.baseBlockInr,
      pointValueInr: economics.pointValueInr,
      baseCurrency: economics.baseCurrency,
      capPeriodBasis: economics.capPeriodBasis,
    },
  };

  const { rows: rewardRules, perSource } = transformRewardRules(record, ctx);
  const extraFlags = [];

  // D14(c): a whole-array override that drops a source exclusion, and rule
  // cap references that point at no cap (in the source or after overrides).
  // D17h: any override (whole-array set, remove, null, role or
  // evaluation-type change) that leaves a source exclusion no longer an
  // exclusion is reported.
  if (applied.length) {
    const stillExcluding = new Set((record?.reward_rules || [])
      .filter((r) => r && String(r.evaluation_type) === 'exclusion' && (r.rule_role === undefined || r.rule_role === null || r.rule_role === 'exclusion'))
      .map((r) => String(r.id)));
    for (const r of rawRecord?.reward_rules || []) {
      if (String(r?.evaluation_type) === 'exclusion' && !stillExcluding.has(String(r?.id))) {
        extraFlags.push({ code: 'override_removed_exclusion', source_local_id: isNA(r?.id) ? null : String(r.id), detail: r?.category_id || null });
      }
    }
  }
  const capIds = new Set((record?.cap_rules || []).map((c) => String(c?.id ?? c?.cap_id)));
  for (const r of record?.reward_rules || []) {
    const ref = r?.action?.cap_reference;
    if (!isNA(ref) && !capIds.has(String(ref))) {
      extraFlags.push({ code: 'dangling_cap_reference', source_local_id: isNA(r?.id) ? null : String(r.id), detail: String(ref) });
    }
  }

  // D9(4): when the card's block isn't its unit's block (₹125, ₹50, ₹500),
  // the engines need an explicit base rule that carries block_inr.
  if (economics.unusualBlock && !rewardRules.some((r) => r.rule_role === 'base' && r.block_inr === economics.unusualBlock)) {
    rewardRules.push({
      key: 'base-block',
      source_local_id: null,
      part: null,
      source_category_token: null,
      evaluation_type: 'standard_accrual',
      category_slug: null,
      merchant_pattern: null,
      rail: null,
      unit: 'points_per_100',
      rate: economics.basePointsPerBlock,
      min_txn_inr: null,
      max_txn_inr: null,
      priority: 1000,
      effective_from: null,
      effective_to: null,
      excluded_category_slugs: [],
      rule_role: 'base',
      merchant_slugs: [],
      platform_slugs: [],
      mcc_include: [],
      mcc_exclude: [],
      except_merchant_slugs: [],
      except_platform_slugs: [],
      block_inr: economics.unusualBlock,
      min_engine_version: 2,
      max_engine_version: null,
      display_note: `${economics.basePointsPerBlock} pts per ₹${economics.unusualBlock}`,
      currency: 'points',
      cap_refs: [],
      info_reasons: [],
      flags: ['synthesized_base_rule'],
      v2_reasons: ['block_inr'],
    });
    extraFlags.push({ code: 'synthesized_base_rule', source_local_id: null, detail: `block ₹${economics.unusualBlock}` });
  }

  const cardExclusions = cardExcludedCategories(record);
  rewardRules.push(...cardLevelNarrowExclusionRows(cardExclusions.narrow, economics.baseUnit));
  if (cardExclusions.narrow.length) {
    extraFlags.push({ code: 'card_level_narrow_exclusion', source_local_id: null, detail: cardExclusions.narrow.map((n) => n.token).join(', ') });
  }

  const hiddenByCarveOut = hideCarvedAcceleratorsFromV1(rewardRules, ctx.card, ctx.index);
  if (hiddenByCarveOut.length) {
    extraFlags.push({ code: 'hidden_from_v1_carve_out', source_local_id: null, detail: hiddenByCarveOut.join(', ') });
  }
  const capResult = transformCaps(record, rewardRules, ctx);
  // Rows the database's identity indexes would reject (see dedupe.js).
  const capDedupe = dedupeCaps(capResult.caps, capResult.capTargets);
  capResult.caps = capDedupe.caps;
  capResult.capTargets = capDedupe.capTargets;
  extraFlags.push(...capDedupe.flags);
  const hiddenUncapped = hideUncappedFromV1(rewardRules, capResult.caps, ctx.card);
  if (hiddenUncapped.length) {
    extraFlags.push({ code: 'hidden_from_v1_uncapped', source_local_id: null, detail: hiddenUncapped.join(', ') });
  }
  const milestoneResult = transformMilestones(record);
  const milestoneDedupe = dedupeMilestones(milestoneResult.milestones);
  milestoneResult.milestones = milestoneDedupe.milestones;
  extraFlags.push(...milestoneDedupe.flags);
  const benefitResult = transformBenefits(record);
  const benefitDedupe = dedupeBenefits(benefitResult.benefits, benefitResult.unlockRules);
  benefitResult.benefits = benefitDedupe.benefits;
  extraFlags.push(...benefitDedupe.flags);
  const redemption = redemptionRows(record);

  // D7 + D10: accrual_rounding is always set on a loaded card.
  const roundingRaw = record?.accrual_engine?.rounding_mode;
  let accrualRounding = isNA(roundingRaw) ? null : ROUNDING[String(roundingRaw).toLowerCase()] ?? null;
  if (!isNA(roundingRaw) && accrualRounding === null) {
    extraFlags.push({ code: 'unknown_rounding_mode', source_local_id: null, detail: String(roundingRaw) });
  }
  const isPointsCard = economics.baseCurrency === 'points' || rewardRules.some((r) => r.currency === 'points');
  if (accrualRounding === null) {
    accrualRounding = isPointsCard ? 'floor' : 'none';
    extraFlags.push({ code: 'rounding_assumed', source_local_id: null, detail: accrualRounding });
  }
  for (const f of economics.flags) extraFlags.push({ code: f, source_local_id: null, detail: null });

  const verified = opts.verifiedSlugs instanceof Set && sourceSlug ? opts.verifiedSlugs.has(sourceSlug) : false;
  const coverage = buildCoverage({
    rewardRules,
    perSource,
    capResult,
    milestoneResult,
    benefitResult,
    extraFlags,
    overridesApplied: applied,
    overrideErrors: errors,
    verified,
  });

  const card = {
    slug: cp.slug || null,
    source_slug: sourceSlug,
    name: cp.name || null,
    base_reward_unit: economics.baseUnit,
    base_reward_rate: economics.baseRate,
    point_value_inr: economics.pointValueInr,
    point_value_basis: economics.pointValueBasis,
    excluded_category_slugs: cardExclusions.slugs,
    accrual_block_inr: economics.baseBlockInr,
    accrual_rounding: accrualRounding,
    cashback_rounding: cashbackRounding(
      record,
      economics.baseCurrency === 'cashback' || rewardRules.some((r) => r.currency === 'cashback')
    ),
    points_expiry_months: Number.isInteger(cp.point_expiry_months) ? cp.point_expiry_months : null,
    model_status: coverage.model_status,
    model_coverage: coverage.model_coverage,
  };

  return {
    card,
    rewardRules,
    capRules: capResult.caps,
    capTargets: capResult.capTargets,
    milestones: milestoneResult.milestones,
    feeWaivers: feeWaiverRow(record),
    benefits: benefitResult.benefits,
    unlockRules: benefitResult.unlockRules,
    redemptionOptions: redemption.rows,
    coverage: { ...coverage.details, skippedRedemptionOptions: redemption.skipped },
    record,
  };
}

module.exports = {
  TRANSFORM_VERSION_V2,
  cardEconomics,
  transformCardRecordV2,
};
