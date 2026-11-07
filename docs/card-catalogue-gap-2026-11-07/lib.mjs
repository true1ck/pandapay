// Helpers for hand-sourced card overlays. An overlay is a PARTIAL universal
// record (same keys as CardPipeline's universal_card_schema_fixed_v2.json)
// that build.mjs deep-merges onto the existing draft for that slug.
//
// Rules for anyone adding a card here:
//  * Only write a value that a named issuer document states. Unknown = null.
//  * "N/A" only when the field genuinely does not apply to the card.
//  * Headline "X%" claims in points are NOT cash value: say what a point is worth.
//  * Put every source URL + document date in prov(), and every open question in `unverified`.

export const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/** Deep merge: objects merge, arrays replace, except additional_data.items which append. */
export function deepMerge(base, over, path = '') {
  if (over === undefined) return base;
  if (Array.isArray(over)) {
    if (path === 'additional_data.items' && Array.isArray(base)) {
      // A newer provenance block supersedes an older one: keep the old one for history under a clear name.
      const hasNew = over.some((i) => i?.key === 'research_provenance');
      const kept = base.map((i) => (hasNew && i?.key === 'research_provenance' ? { ...i, key: 'superseded_research_provenance' } : i));
      return [...kept, ...over];
    }
    return over;
  }
  if (isObj(over) && isObj(base)) {
    const out = { ...base };
    for (const k of Object.keys(over)) out[k] = deepMerge(base[k], over[k], path ? `${path}.${k}` : k);
    return out;
  }
  return over;
}

/** Reward rule. cat = PandaPay category token; type = exclusion|accelerator|standard_accrual|fallback. */
export function R({ id, cat, pri = 20, type = 'accelerator', rail = 'any', channel = 'all', cond = {}, mult = 1, ppb = null, cb = null, cap = null, reason = null, from = null, to = null }) {
  return {
    id, category_id: cat, priority: pri, evaluation_type: type, rail, channel_type: channel,
    conditions: cond,
    action: { multiplier: mult, points_per_block: ppb === null ? 'N/A' : ppb, cashback_percent: cb === null ? 'N/A' : cb, cap_reference: cap, reason },
    effective_from: from, effective_to: to,
  };
}

/** Exclusion rule (earns nothing). */
export function X(id, cat, mccs, reason, extraCond = {}) {
  return R({ id, cat, pri: 2, type: 'exclusion', mult: 0, cond: { ...(mccs?.length ? { mcc_list: mccs } : {}), ...extraCond }, reason });
}

/** Cap rule. metric = bonus_reward_points | total_reward_points | eligible_spend_amount | txn_count. */
export function C({ id, cat, metric, period, points = null, inr = null, mccs = [], after = 'downgrade_to_base_rate', afterPpb = null, parent = null, from = null, to = null }) {
  return {
    id, category_id: cat, metric, mcc_target_list: mccs, period,
    limit_value: points === null ? 'N/A' : points, limit_value_inr: inr === null ? 'N/A' : inr,
    post_limit_behavior: { action: after, points_per_block: afterPpb === null ? 'N/A' : afterPpb },
    parent_cap_id: parent, reset_day: null, effective_from: from, effective_to: to,
  };
}

/** Lifestyle / network benefit (lounge, spa, movie, concierge, insurance_related_perk, other). */
export function B({ id, cat, program = 'N/A', sponsor, label, cond = 'N/A', calc = 'N/A', perks = [], qty = null, per = 'N/A', value = 'N/A', from = null, to = null }) {
  return {
    benefit_id: id, category_id: cat, network_program: program === 'N/A' ? null : program, sponsor, label,
    evaluation_engine: { conditions: cond, benefit_calculation: calc, perks },
    quota_count: qty, quota_period: per, value_estimate_inr: value, effective_from: from, effective_to: to,
  };
}

/** Partner offer that is NOT a reward rate (instant discount / cashback at a merchant). */
export function P({ id, cat, sponsor, platform, type, pct = 'N/A', max = 'N/A', quota = false, permanent = true, from = null, to = null }) {
  return {
    promo_id: id, category_id: cat, network_program: 'N/A', sponsor, platform, offer_type: type,
    discount_percent: pct, max_discount_inr: max, fnb_discount_inr: 'N/A', min_tickets: 'N/A',
    quota_controlled: quota, is_permanent_card_feature: permanent, valid_from: from, valid_to: to,
  };
}

/** Provenance + open questions, stored in additional_data so reviewers see where every number came from. */
export function prov({ sources, unverified = [], notes = [], extra = {} }) {
  return [{
    key: 'research_provenance',
    value: {
      research_method: 'issuer pages read in a real browser session or issuer PDFs read with pdftotext; no model summaries used as facts',
      fetched_on: '2026-11-07',
      sources,
      open_questions: unverified,
      notes,
      publication_gate: 'pending_human_review_of_official_documents',
      ...extra,
    },
  }];
}

/** Two linked networks on one credit account (importer reads key verified_network_research). */
export function dualNetwork({ sourceUrl, evidence, variants }) {
  return {
    key: 'verified_network_research',
    value: { product_status: 'active', source_url: sourceUrl, evidence, candidates: variants },
  };
}

export const GST = { fee_gst_applicable: true, gst_rate_percent: 18 };
