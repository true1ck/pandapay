'use strict';

// Plan C7.7 (+ C8 D3, D8d) — CardPipeline cap_rules -> v2 cap_rules rows,
// their cap_rule_targets, and the v1 projection columns.

const { asNumber, firstDefined, isNA, uniq } = require('./util');
const { resolveCategoryToken } = require('./category_tokens');

const PERIOD = {
  statement_cycle: { period: 'statement_cycle' },
  statement_cycle_quarter: { period: 'quarter', approximated: true },
  calendar_month: { period: 'calendar_month' },
  month: { period: 'calendar_month' },
  monthly: { period: 'calendar_month' },
  quarter: { period: 'quarter' },
  calendar_quarter: { period: 'quarter' },
  half_year: { period: 'half_year' },
  annual: { period: 'annual' },
  year: { period: 'annual' },
  calendar_year: { period: 'annual', anchor: 'calendar_year' },
  card_anniversary_year: { period: 'annual', anchor: 'card_anniversary' },
  enrollment_year: { period: 'annual', anchor: 'card_anniversary' },
  fiscal_year: { period: 'annual', anchor: 'fiscal_year' },
  lifetime: { period: 'lifetime' },
  // No daily period exists in Phase 1. A day cap is kept for display and for
  // v2 review, under the widest window we have, and flagged.
  day: { period: 'statement_cycle', unenforced: true },
  daily: { period: 'statement_cycle', unenforced: true },
};

const POST_LIMIT = {
  downgrade_to_base_rate: 'base_rate',
  earn_base_rate: 'base_rate',
  base_accrual_only: 'base_rate',
  base_rate: 'base_rate',
  zero_accrual: 'zero',
  no_points: 'zero',
  no_reward: 'zero',
  no_cashback: 'zero',
};

const USER_DEPENDENT = /(credit[_\s-]?limit|of[_\s-]?limit|limit[_\s-]?based|tier|relationship|salary)/;
// Caps that limit something other than reward earning: redemptions, point
// transfers, fee thresholds, surcharge waivers, transaction charges (D17g).
const NON_EARNING_CAP = /(redemption|redeem|statement_credit|lounge|(?:^|[-_\s])(?:transfers?|fees?|surcharges?|waivers?|thresholds?|charges?)(?:[-_\s]|$))/;
// D8d: "fuel_cap_first_6_months", "fuel_first_6m" / "fuel_post_6m".
const CARD_AGE_TIER = /((first|initial|after|post)[_-]?\d+[_-]?(m|mo|mon|months?)(?![a-z])|card[_-]?age|months?[_-]?(from|after)[_-]?(issu|open|activation))/;
const INTRO_TIER = /(first|initial)[_-]?\d+[_-]?(m|mo|mon|months?)(?![a-z])/;
const LATER_TIER = /(after|post)[_-]?\d+[_-]?(m|mo|mon|months?)(?![a-z])/;

function humanize(id) {
  return String(id || 'cap')
    .replace(/[-_]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^\w/, (c) => c.toUpperCase());
}

/**
 * @param record CardPipeline record
 * @param rules  v2 rule rows from transformRewardRules (with key, cap_refs, ...)
 * @param ctx    { card: {pointValueInr, capPeriodBasis, baseCurrency}, index, issuerSlug }
 */
function transformCaps(record, rules, ctx) {
  const sourceCaps = Array.isArray(record?.cap_rules) ? record.cap_rules : [];
  const flagsOut = [];
  const caps = [];
  const skipped = [];
  const bySourceId = new Map();

  const ruleBySource = new Map();
  for (const r of rules) {
    if (!r.source_local_id) continue;
    if (!ruleBySource.has(r.source_local_id)) ruleBySource.set(r.source_local_id, []);
    ruleBySource.get(r.source_local_id).push(r);
  }

  // Card-age tiers (D8d): keep the steady-state cap and drop the introductory one.
  const ageTiered = new Set();
  for (const c of sourceCaps) {
    const id = String(firstDefined(c?.id, c?.cap_id) || '');
    if (c?.tier_by_card_age === true || CARD_AGE_TIER.test(id.toLowerCase())) ageTiered.add(id);
  }

  sourceCaps.forEach((c, idx) => {
    const id = firstDefined(c?.id, c?.cap_id);
    const sourceId = isNA(id) ? null : String(id);
    const flags = [];
    const skip = (reason) => {
      skipped.push({ source_local_id: sourceId, reason });
      flagsOut.push({ code: reason, source_local_id: sourceId, detail: null });
    };
    if (!sourceId) return skip('cap_missing_id');
    const categoryToken = isNA(c.category_id) ? '' : String(c.category_id).toLowerCase();
    const capText = [sourceId, categoryToken, c.label, c.description].filter((v) => typeof v === 'string').join(' ').toLowerCase();
    if (NON_EARNING_CAP.test(capText)) return skip('non_earning_cap_skipped');
    const metric = String(firstDefined(c.metric, c.cap_type) || '').toLowerCase();
    if (/^waiver_amount/.test(metric)) return skip('fuel_waiver_cap_skipped');

    // Targets: rules whose cap_reference (or a cap_* condition key) names this
    // cap, plus explicit target_rule_ids.
    let targets = rules.filter((r) => r.cap_refs.includes(sourceId));
    for (const t of Array.isArray(c.target_rule_ids) ? c.target_rule_ids : []) {
      targets.push(...(ruleBySource.get(String(t)) || []));
    }
    let inferred = false;
    // D17g: only earning metrics are linked by category token.
    const earningMetric = ['bonus_reward_points', 'accelerated_reward_points', 'total_reward_points', 'eligible_spend_amount', 'txn_count'].includes(metric);
    if (!targets.length && earningMetric && categoryToken && !['all_retail', 'other', 'other_retail'].includes(categoryToken)) {
      const sameToken = rules.filter(
        (r) => r.source_category_token && r.source_category_token.toLowerCase() === categoryToken &&
          r.evaluation_type !== 'exclusion'
      );
      if (sameToken.length) {
        targets = sameToken;
        inferred = true;
        flags.push('cap_target_inferred_by_category');
      }
    }
    // A cap scoped to one category of a multi-part rule (PhonePe's insurance
    // sub-cap) links only the parts in that category.
    const capCategory = resolveCategoryToken(categoryToken, ctx);
    if (capCategory.kind === 'category' && targets.length) {
      const slug = capCategory.parts[0].categorySlug;
      const inCategory = targets.filter((r) => r.category_slug === slug);
      if (inCategory.length && inCategory.length < targets.length) targets = inCategory;
    }
    targets = uniq(targets);
    const targetKeys = targets.map((r) => r.key);

    const currencies = uniq(targets.map((r) => r.currency).filter(Boolean));
    const currency = currencies.length === 1 ? currencies[0] : currencies.length ? 'points' : ctx.card.baseCurrency;
    if (currencies.length > 1) flags.push('mixed_target_currency');

    let capKind;
    if (metric === 'bonus_reward_points' || metric === 'accelerated_reward_points') {
      capKind = currency === 'cashback' ? 'bonus_cashback' : 'bonus_points';
    } else if (metric === 'total_reward_points') {
      capKind = currency === 'cashback' ? 'total_cashback' : 'total_points';
    } else if (metric === 'eligible_spend_amount') {
      capKind = 'eligible_spend';
    } else if (metric === 'txn_count') {
      capKind = 'txn_count';
    } else {
      return skip('unknown_cap_metric');
    }

    const capAmount = asNumber(firstDefined(c.limit_value, c.limit_value_inr, c.cap_limit));
    // D13(a): an amount that depends on the cardholder (a share of the credit
    // limit, a tier) is kept with a null amount; engines skip it.
    const userDependent = capAmount === null && (
      c.depends_on_user === true ||
      USER_DEPENDENT.test(`${sourceId} ${categoryToken} ${[c.limit_value, c.limit_value_inr, c.cap_limit].filter((v) => typeof v === 'string').join(' ')}`.toLowerCase())
    );
    if (userDependent) flags.push('cap_depends_on_user');
    else if (capAmount === null || capAmount <= 0) return skip('missing_cap_value');

    if (ageTiered.has(sourceId)) {
      // The steady-state sibling: the same family without a tier marker, or
      // the "post/after N months" tier when this one is "first N months".
      const isIntro = INTRO_TIER.test(sourceId.toLowerCase());
      const steady = sourceCaps.some((other) => {
        const oid = String(firstDefined(other?.id, other?.cap_id) || '');
        if (oid === sourceId) return false;
        const sameFamily = String(other?.category_id || '') === String(c.category_id || '') &&
          String(firstDefined(other?.metric, other?.cap_type) || '') === String(firstDefined(c.metric, c.cap_type) || '');
        if (!sameFamily) return false;
        return !ageTiered.has(oid) || (isIntro && LATER_TIER.test(oid.toLowerCase()));
      });
      flagsOut.push({
        code: 'tier_by_card_age',
        source_local_id: sourceId,
        detail: steady ? 'introductory tier skipped' : LATER_TIER.test(sourceId.toLowerCase()) ? 'steady-state tier kept' : 'only tier present',
      });
      if (steady) {
        skipped.push({ source_local_id: sourceId, reason: 'tier_by_card_age' });
        return;
      }
      flags.push('tier_by_card_age');
    }

    const periodKey = String(firstDefined(c.period, c.capping_period) || '').toLowerCase();
    let periodSpec = PERIOD[periodKey];
    if (!periodSpec) {
      const basis = String(ctx.card.capPeriodBasis || '').toLowerCase();
      periodSpec = PERIOD[basis] || PERIOD.statement_cycle;
      flags.push('cap_period_defaulted');
    }
    if (periodSpec.unenforced) flags.push('unenforced_period');
    if (periodSpec.approximated) flags.push('period_approximated');

    const isTotal = capKind.startsWith('total_');
    const isBonus = capKind.startsWith('bonus_');
    const isSpendOrCount = capKind === 'eligible_spend' || capKind === 'txn_count';
    const postAction = String(c.post_limit_behavior?.action ?? c.post_limit_behavior ?? '').toLowerCase();
    let postCapBehavior = null;
    if (isSpendOrCount) {
      if (POST_LIMIT[postAction]) postCapBehavior = POST_LIMIT[postAction];
      else if (postAction && postAction !== 'null' && postAction !== 'n/a') flags.push('unknown_post_limit');
    } else if (isTotal && POST_LIMIT[postAction] === 'base_rate') {
      // "Total points capped, then base rate" contradicts itself; kept as a
      // total cap (stricter) and flagged for review.
      flags.push('post_limit_conflict');
    } else if (isBonus && POST_LIMIT[postAction] === 'zero') {
      // "Bonus capped, then nothing": a bonus cap never stops the base; the
      // source may mean a total cap. Kept as a bonus cap, flagged for review.
      flags.push('post_limit_conflict');
    }

    let scope = 'targets';
    let categorySlug = null;
    if (!targets.length) {
      if (capCategory.kind === 'category') {
        categorySlug = capCategory.parts[0].categorySlug;
        if (capCategory.parts[0].broad) flags.push('broad_category');
      }
      else if (isTotal && (capCategory.kind === 'unrestricted' || !categoryToken)) scope = 'card';
    }
    if (!targets.length && !categorySlug && scope !== 'card') flags.push('orphan_cap');
    if (targets.length && targets.every((r) => r.rule_role === 'info')) flags.push('cap_targets_info_only');

    if (capKind === 'eligible_spend' && capAmount !== null && capAmount <= 5000 &&
        targets.some((r) => r.unit === 'cashback_percent' && Number(r.rate) >= 5)) {
      flags.push('suspect_cap_unit');
    }

    // v1 projection.
    const pointValue = ctx.card.pointValueInr;
    let measure;
    let capValue;
    let postCapRate;
    let v1Blocked = false;
    if (capAmount === null) {
      measure = isBonus || isTotal ? 'reward_value' : capKind === 'eligible_spend' ? 'spend_amount' : 'txn_count';
      capValue = 0;
      postCapRate = null;
      v1Blocked = true;
    } else if (isBonus || isTotal) {
      measure = 'reward_value';
      if (capKind.endsWith('_cashback')) capValue = capAmount;
      else if (pointValue !== null && pointValue > 0) capValue = Math.round(capAmount * pointValue * 100) / 100;
      else {
        capValue = capAmount;
        v1Blocked = true;
        flags.push('no_point_value_for_v1');
      }
      postCapRate = isTotal ? 0 : null;
    } else {
      measure = capKind === 'eligible_spend' ? 'spend_amount' : 'txn_count';
      capValue = capAmount;
      postCapRate = postCapBehavior === 'zero' ? 0 : null;
    }
    const rewardRuleKey = targetKeys.length === 1 ? targetKeys[0] : null;

    const v2Reasons = [];
    if (periodSpec.unenforced) v2Reasons.push('day_period');
    if (targetKeys.length > 1) v2Reasons.push('multi_target');
    if (targets.some((r) => r.min_engine_version === 2 || r.rule_role === 'info')) v2Reasons.push('target_v2_only');
    if (v1Blocked) v2Reasons.push(capAmount === null ? 'amount_depends_on_user' : 'no_point_value');

    const enforced = !periodSpec.unenforced && capAmount !== null &&
      (scope === 'card' || Boolean(categorySlug) || targets.some((r) => r.rule_role !== 'info'));

    const cap = {
      key: sourceId,
      source_local_id: sourceId,
      label: humanize(sourceId),
      category_slug: categorySlug,
      reward_rule_key: rewardRuleKey,
      measure,
      period: periodSpec.period,
      cap_value: capValue,
      post_cap_unit: null,
      post_cap_rate: postCapRate,
      resets_on_day: Number.isInteger(c.reset_day) && c.reset_day >= 1 && c.reset_day <= 31 ? c.reset_day : null,
      cap_kind: capKind,
      cap_amount: capAmount,
      scope,
      parent_key: isNA(c.parent_cap_id) ? null : String(c.parent_cap_id),
      post_cap_behavior: postCapBehavior,
      anchor: periodSpec.anchor || null,
      min_engine_version: v2Reasons.length ? 2 : 1,
      target_keys: targetKeys,
      enforced,
      flags: uniq(flags),
      v2_reasons: v2Reasons,
      target_inferred: inferred,
      source_index: idx,
    };
    caps.push(cap);
    bySourceId.set(sourceId, cap);
    for (const f of cap.flags) flagsOut.push({ code: f, source_local_id: sourceId, detail: null });
  });

  // Parents must exist; a cycle or a missing parent is dropped and flagged.
  for (const cap of caps) {
    if (!cap.parent_key) continue;
    const seen = new Set([cap.key]);
    let p = bySourceId.get(cap.parent_key);
    let ok = Boolean(p);
    while (p && p.parent_key) {
      if (seen.has(p.parent_key)) {
        ok = false;
        break;
      }
      seen.add(p.key);
      p = bySourceId.get(p.parent_key);
    }
    if (!ok) {
      flagsOut.push({ code: 'parent_cap_unresolved', source_local_id: cap.key, detail: cap.parent_key });
      cap.parent_key = null;
    }
  }

  // Parents first, so the writer can resolve parent ids in one pass.
  const ordered = [];
  const placed = new Set();
  const place = (cap) => {
    if (placed.has(cap.key)) return;
    if (cap.parent_key && bySourceId.has(cap.parent_key)) place(bySourceId.get(cap.parent_key));
    placed.add(cap.key);
    ordered.push(cap);
  };
  caps.forEach(place);

  const capTargets = [];
  for (const cap of ordered) for (const k of cap.target_keys) capTargets.push({ cap_key: cap.key, rule_key: k });

  return { caps: ordered, capTargets, skipped, flags: flagsOut, total: sourceCaps.length };
}

module.exports = { transformCaps, PERIOD };
